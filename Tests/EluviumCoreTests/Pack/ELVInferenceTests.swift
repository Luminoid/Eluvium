import Foundation
import Testing
@testable import EluviumCore

@Suite("Kind inference")
struct ELVInferenceTests {
    private func load(_ json: String, modes: Set<String> = ["http", "json"]) throws -> ELVLoadedPack {
        try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: modes, binaryVersion: "0.1"))
    }

    /// A kind-less source carrying the given tables, ready to assemble
    /// against arbitrary evidence.
    private func inferringSource(
        jsonldType: [String: String] = [:],
        categoryKeyword: [String: String] = [:],
        poiCategory: [String: String] = [:],
        hostBrand: [String: String] = [:],
        fields: [ELVFieldSpec] = []
    ) -> ELVSource {
        ELVSource(
            id: "infer.example",
            kind: "",
            fields: fields,
            inference: ELVInferenceSpec(jsonldType: jsonldType, categoryKeyword: categoryKeyword, poiCategory: poiCategory, hostBrand: hostBrand)
        )
    }

    // MARK: - Decode

    @Test
    func `The inference block decodes; unknown keys and malformed tables degrade with diagnostics, never a dead source`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [{
          "id": "infer.decode", "match": {"host": ["example.com"]}, "fetch": {"mode": "json"},
          "inference": {
            "jsonldType": {"Restaurant": "food", "Hotel": "lodging"},
            "categoryKeyword": {"trailhead": "hike"},
            "poiCategory": "not-a-map",
            "hostBrand": {"opentable": "food"},
            "futureAxis": {"anything": "goes"}
          }
        }]}
        """
        let loaded = try load(json, modes: ["json"])
        let source = try #require(loaded.source(withId: "infer.decode"))
        let inference = try #require(source.inference)
        // Keys normalize to lowercase; matching is case-insensitive by construction.
        #expect(inference.jsonldType == ["restaurant": "food", "hotel": "lodging"])
        #expect(inference.categoryKeyword == ["trailhead": "hike"])
        #expect(inference.poiCategory.isEmpty)
        #expect(inference.hostBrand == ["opentable": "food"])
        let messages = loaded.diagnostics.map(\.description)
        #expect(messages.contains { $0.contains("futureAxis") && $0.contains("ignored") })
        #expect(messages.contains { $0.contains("poiCategory") && $0.contains("dropped") })
    }

    @Test
    func `A pack without inference loads and assembles exactly as before`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [{
          "id": "plain.example", "kind": "thing", "match": {"host": ["example.com"], "path": "/x/:id"}, "fetch": {"mode": "json"},
          "fields": [{"name": "title", "candidates": [{"from": {"json": "$.name"}}]}]
        }]}
        """
        let loaded = try load(json, modes: ["json"])
        let source = try #require(loaded.source(withId: "plain.example"))
        #expect(source.inference == nil)
        #expect(loaded.diagnostics.isEmpty)
        let body = try #require(ELVRawJSON.parse(Data(#"{"name": "Thing"}"#.utf8)))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(document: ELVDocument(json: body)))
        #expect(record.kind == "thing")
        #expect(record.fields["title"] == .text("Thing"))
        // A kind-less source without inference still yields an absent kind.
        let bare = ELVSource(id: "bare.example", kind: "")
        #expect(ELVAssembler.assemble(source: bare, context: ELVExtractionContext()).kind.isEmpty)
    }

    @Test
    func `Hostile tables clamp deterministically in init`() {
        var oversized: [String: String] = [:]
        for index in 0 ..< 200 {
            oversized[String(format: "key%03d", index)] = "kind"
        }
        oversized[String(repeating: "k", count: 200)] = "kind"
        oversized["blank"] = String(repeating: "v", count: 100)
        let spec = ELVInferenceSpec(categoryKeyword: oversized)
        #expect(spec.categoryKeyword.count == ELVInferenceSpec.maxEntriesPerTable)
        // Truncation keeps the sorted-first keys, so a re-decode of the same
        // table always keeps the same entries.
        #expect(spec.categoryKeyword["key000"] == "kind")
        #expect(spec.categoryKeyword["key127"] == "kind")
        #expect(spec.categoryKeyword["key128"] == nil)
        #expect(spec.categoryKeyword[String(repeating: "k", count: 200)] == nil)
        #expect(spec.decodeIssues.contains { $0.contains("capped") })
        #expect(spec.decodeIssues.contains { $0.contains("dropped 2 entries") })
    }

    // MARK: - Axes

    @Test
    func `A JSON-LD @type maps through the table case-insensitively, string or array form`() throws {
        let source = inferringSource(jsonldType: ["restaurant": "food", "hotel": "lodging"])
        let single = try [#require(ELVRawJSON.parse(Data(#"{"@type": "Restaurant", "name": "Dornan's"}"#.utf8)))]
        #expect(ELVAssembler.assemble(source: source, context: ELVExtractionContext(document: ELVDocument(jsonLDNodes: single))).kind == "food")
        let array = try [#require(ELVRawJSON.parse(Data(#"{"@type": ["Thing", "Hotel"]}"#.utf8)))]
        #expect(ELVAssembler.assemble(source: source, context: ELVExtractionContext(document: ELVDocument(jsonLDNodes: array))).kind == "lodging")
    }

    @Test
    func `A MapKit POI category rawValue matches its bare authored key`() {
        let source = inferringSource(
            poiCategory: ["restaurant": "food", "campground": "lodging"],
            fields: [ELVFieldSpec(name: "category", candidates: [ELVCandidate(from: .const("MKPOICategoryRestaurant"))])]
        )
        #expect(ELVAssembler.assemble(source: source, context: ELVExtractionContext()).kind == "food")
    }

    @Test
    func `Keyword matching is word-bounded: barn never reads as bar`() {
        let table = ["bar": "food", "bed and breakfast": "lodging"]
        func kind(forCategoryText text: String) -> String {
            let source = inferringSource(
                categoryKeyword: table,
                fields: [ELVFieldSpec(name: "type", candidates: [ELVCandidate(from: .const(text))])]
            )
            return ELVAssembler.assemble(source: source, context: ELVExtractionContext()).kind
        }
        #expect(kind(forCategoryText: "Cocktail bar") == "food")
        #expect(kind(forCategoryText: "The Barn Museum").isEmpty)
        #expect(kind(forCategoryText: "A bed and breakfast in Moose") == "lodging")
        // The multi-word phrase must appear verbatim AND word-for-word.
        #expect(kind(forCategoryText: "embed and breakfast").isEmpty)
    }

    @Test
    func `Host brands suggest kinds; lookalike hosts never do`() {
        let source = inferringSource(hostBrand: ["opentable": "food", "hotels.com": "lodging"])
        func kind(_ url: String) -> String {
            ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: URL(string: url))).kind
        }
        #expect(kind("https://www.opentable.com/r/dornans") == "food")
        #expect(kind("https://www.opentable.co.uk/r/x") == "food")
        #expect(kind("https://opentable.evil.com/r/x").isEmpty)
        #expect(kind("https://hotels.com/h/1") == "lodging")
        #expect(kind("https://www.hotels.com/h/1") == "lodging")
        #expect(kind("https://hotels.com.evil.net/h/1").isEmpty)
    }

    @Test
    func `Unmatched evidence yields no suggestion, never a wrong default`() throws {
        let source = inferringSource(
            jsonldType: ["restaurant": "food"],
            categoryKeyword: ["bakery": "food"],
            poiCategory: ["hotel": "lodging"],
            hostBrand: ["opentable": "food"],
            fields: [ELVFieldSpec(name: "type", candidates: [ELVCandidate(from: .const("Municipal office"))])]
        )
        let nodes = try [#require(ELVRawJSON.parse(Data(#"{"@type": "GovernmentOffice"}"#.utf8)))]
        let context = ELVExtractionContext(url: URL(string: "https://city.example.gov/office"), document: ELVDocument(jsonLDNodes: nodes))
        #expect(ELVAssembler.assemble(source: source, context: context).kind.isEmpty)
    }

    @Test
    func `Declared evidence beats the host prior`() throws {
        let source = inferringSource(jsonldType: ["restaurant": "food"], hostBrand: ["opentable": "lodging"])
        let nodes = try [#require(ELVRawJSON.parse(Data(#"{"@type": "Restaurant"}"#.utf8)))]
        let context = ELVExtractionContext(url: URL(string: "https://www.opentable.com/r/x"), document: ELVDocument(jsonLDNodes: nodes))
        #expect(ELVAssembler.assemble(source: source, context: context).kind == "food")
    }

    // MARK: - Authored kinds and entry points

    @Test
    func `An authored kind always beats a suggestion`() throws {
        let source = ELVSource(
            id: "authored.example",
            kind: "place",
            inference: ELVInferenceSpec(jsonldType: ["restaurant": "food"])
        )
        let nodes = try [#require(ELVRawJSON.parse(Data(#"{"@type": "Restaurant"}"#.utf8)))]
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(document: ELVDocument(jsonLDNodes: nodes)))
        #expect(record.kind == "place")
    }

    @Test
    func `A collection child with an explicitly absent kind may infer; the parent's authored kind stands`() throws {
        let source = ELVSource(
            id: "parent.example",
            kind: "place",
            collections: [
                ELVCollectionSpec(name: "children", from: .json("$.items[*]"), item: [
                    ELVFieldSpec(name: "category", candidates: [ELVCandidate(from: .json("$.cat"))]),
                ], kind: ""),
            ],
            inference: ELVInferenceSpec(categoryKeyword: ["trailhead": "hike"])
        )
        let body = try #require(ELVRawJSON.parse(Data(#"{"items": [{"cat": "Trailhead parking"}]}"#.utf8)))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(document: ELVDocument(json: body)))
        #expect(record.kind == "place")
        #expect(record.collections["children"]?.first?.kind == "hike")
    }

    @Test
    func `List items and archive rows infer through the same gate`() throws {
        let source = ELVSource(
            id: "rows.example",
            kind: "",
            rows: [
                ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.name")), ELVCandidate(from: .column("Name"))]),
                ELVFieldSpec(name: "category", candidates: [ELVCandidate(from: .json("$.cat")), ELVCandidate(from: .column("Category"))]),
            ],
            inference: ELVInferenceSpec(categoryKeyword: ["bakery": "food"])
        )
        let item = try #require(ELVRawJSON.parse(Data(#"{"name": "Persephone", "cat": "Bakery & deli"}"#.utf8)))
        let itemRecord = try #require(ELVAssembler.assembleItem(source: source, itemJSON: item))
        #expect(itemRecord.kind == "food")
        let rowRecord = try #require(ELVAssembler.assembleRow(source: source, row: ["Name": "Persephone", "Category": "bakery"], context: ELVExtractionContext()))
        #expect(rowRecord.kind == "food")
    }

    // MARK: - Validator

    @Test
    func `The validator flags empty tables, blank or implausible target kinds, and dead inference`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [
          {"id": "dead.example", "kind": "place", "match": {"host": ["a.example"]}, "fetch": {"mode": "json"},
           "inference": {"jsonldType": {"Restaurant": "food"}}},
          {"id": "empty.example", "match": {"host": ["b.example"]}, "fetch": {"mode": "json"},
           "inference": {"jsonldType": {}}},
          {"id": "junk.example", "match": {"host": ["c.example"]}, "fetch": {"mode": "json"},
           "inference": {"categoryKeyword": {"bakery": "", "hotel": "Hotel Deluxe"}}}
        ]}
        """
        let loaded = try load(json, modes: ["json"])
        let messages = loaded.diagnostics.map(\.description)
        #expect(messages.contains { $0.contains("dead.example") && $0.contains("never runs") })
        #expect(messages.contains { $0.contains("empty.example") && $0.contains("declared but empty") })
        #expect(messages.contains { $0.contains("empty.example") && $0.contains("never suggests a kind") })
        #expect(messages.contains { $0.contains("junk.example") && $0.contains("maps to an empty kind") })
        #expect(messages.contains { $0.contains("junk.example") && $0.contains("not a lowercase kind token") })
    }
}
