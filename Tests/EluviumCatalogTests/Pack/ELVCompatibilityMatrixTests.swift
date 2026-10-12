import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The compatibility matrix: {historical / future pack shapes} × {this
/// binary} and {records serialized by historical formatVersions} × {the
/// current decoder, asserting round-trip byte equality including `unknown`}.
/// The fixtures here are FROZEN — they must never track the live starter
/// pack or model code, because their whole value is being what an older or
/// newer author actually wrote.
@Suite("Compatibility matrix")
struct ELVCompatibilityMatrixTests {
    /// A pack as a newer minor-version author would write it: additive
    /// unknown keys at every level, future ops / pipes / coercions /
    /// selectors in candidate lists, and sources this binary cannot meet.
    /// Frozen 2026-08-11.
    private let futureMinorPack = """
    {
      "schemaVersion": 1,
      "schemaMinor": 7,
      "packVersion": "matrix-fixture",
      "futureTopLevel": {"anything": true},
      "sources": [
        {
          "id": "compat.basic",
          "kind": "thing",
          "futureSourceKey": "ignored",
          "match": {"host": ["compat.example"], "path": "/thing/:id", "priority": 100, "futureMatchKey": 9},
          "fetch": {"mode": "json", "futureFetchKey": "x"},
          "fields": [
            {"name": "externalId", "candidates": [{"from": {"urlParam": "id"}}]},
            {"name": "title", "futureFieldKey": true, "candidates": [
              {"from": {"json": "$.name"}, "futureCandidateKey": 1}
            ]}
          ]
        },
        {
          "id": "compat.graded",
          "kind": "thing",
          "match": {"host": ["graded.example"], "path": "/x/:id", "priority": 100},
          "fetch": {"mode": "json"},
          "fields": [
            {"name": "externalId", "candidates": [{"from": {"urlParam": "id"}}]},
            {"name": "title", "candidates": [
              {"from": {"hologram": "future-selector"}},
              {"from": {"native": "future.op@9"}, "select": "value"},
              {"from": {"json": "$.name"}, "pipe": ["holoTrim"]},
              {"from": {"json": "$.name"}, "as": "quaternion"},
              {"from": {"json": "$.name"}}
            ]},
            {"name": "ghost", "candidates": [
              {"from": {"native": "future.op@9"}, "select": "value"},
              {"from": {"json": "$.missing"}, "as": "quaternion"}
            ]}
          ]
        },
        {
          "id": "compat.needsFutureOp",
          "kind": "thing",
          "match": {"host": ["op.example"], "path": "/**", "priority": 100},
          "requires": ["native:future.op@9"]
        },
        {
          "id": "compat.needsFutureBinary",
          "kind": "thing",
          "match": {"host": ["binary.example"], "path": "/**", "priority": 100},
          "minBinary": "99.0"
        }
      ]
    }
    """

    private func loaded() throws -> ELVLoadedPack {
        try ELVPackLoader.load(embedded: Data(futureMinorPack.utf8), capabilities: ELVCapabilities(fetchModes: ["http", "json"], binaryVersion: "0.1"))
    }

    @Test
    func `A newer schemaMinor with unknown keys at every level loads clean`() throws {
        let pack = try loaded()
        #expect(pack.pack.schemaMinor == 7)
        #expect(pack.sources.map(\.id) == ["compat.basic", "compat.graded"])
        #expect(pack.skipped.map(\.id) == ["compat.needsFutureOp", "compat.needsFutureBinary"])
    }

    @Test
    func `Unknown selector, op, pipe, and coercion each invalidate only their candidate`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "compat.graded"))
        let json = try #require(ELVRawJSON.parse(Data(#"{"name": "Survivor"}"#.utf8)))
        let url = try #require(URL(string: "https://graded.example/x/7"))
        let context = ELVExtractionContext(url: url, params: ["id": "7"], document: ELVDocument(json: json))
        let record = ELVAssembler.assemble(source: source, context: context)

        // Four future-shaped candidates fell through; the plain fifth wins.
        #expect(record.fields["title"] == .text("Survivor"))
        // A field with no valid candidate is simply absent — the record stands.
        #expect(record.fields["ghost"] == nil)
        #expect(record.externalId == "7")
    }

    @Test
    func `A higher schemaVersion is rejected wholesale, never half-loaded`() {
        let breaking = futureMinorPack.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
        #expect(throws: ELVPackError.self) {
            try ELVPackLoader.load(embedded: Data(breaking.utf8), capabilities: ELVCapabilities(fetchModes: ["json"], binaryVersion: "0.1"))
        }
    }

    @Test
    func `The frozen 2026-08-11 starter pack loads on every future binary`() throws {
        // "backward compatibility is absolute": this assertion is the
        // corpus seed. The fixture in ELVFrozenPacks is the 2026-08-11 pack
        // verbatim; the live pack has since grown and is asserted separately
        // in ELVStarterPackTests.
        let pack = try ELVPackLoader.load(
            embedded: Data(ELVFrozenPacks.starter20260811.utf8),
            capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed"], binaryVersion: "0.1")
        )
        #expect(pack.pack.sources.count == 9)
        #expect(pack.genericFloors.count == 2)
        #expect(pack.pack.packVersion == "2026.08.11-starter")
    }

    // MARK: - Persisted records × the current decoder

    /// A record as a v1 binary wrote it. Frozen 2026-08-11.
    private let v1Record = """
    {"formatVersion": 1, "sourceId": "pokeapi.pokemon", "kind": "pokemon", "externalId": "25",
     "fields": {"title": {"type": "text", "value": "Pikachu"}, "height": {"type": "number", "value": 4}}}
    """

    /// A record as a NEWER binary would write it: a future formatVersion,
    /// future top-level keys, and a future value type. Frozen 2026-08-11.
    private let futureRecord = """
    {"formatVersion": 3, "sourceId": "future.source", "kind": "hologram", "externalId": "h1",
     "trustScore": 0.93,
     "embeddings": {"model": "elv-embed-2", "dims": 768},
     "fields": {
       "title": {"type": "text", "value": "Future Thing"},
       "shape": {"type": "quaternion", "w": 1, "x": 0, "y": 0, "z": 0.5}
     }}
    """

    private func canonical(_ record: ELVRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    @Test
    func `Historical and future records round-trip byte-identically, unknown included`() throws {
        for fixture in [v1Record, futureRecord] {
            let first = try JSONDecoder().decode(ELVRecord.self, from: Data(fixture.utf8))
            let encodedOnce = try canonical(first)
            let second = try JSONDecoder().decode(ELVRecord.self, from: encodedOnce)
            let encodedTwice = try canonical(second)
            // Byte equality across the decode → encode → decode → encode
            // cycle: nothing an unrecognized author wrote is dropped or
            // reordered by passing through this binary.
            #expect(encodedOnce == encodedTwice)
            #expect(first == second)
        }
    }

    @Test
    func `Everything a newer binary wrote is preserved and re-emitted unchanged`() throws {
        let decoded = try JSONDecoder().decode(ELVRecord.self, from: Data(futureRecord.utf8))
        #expect(decoded.formatVersion == 3)
        #expect(decoded.unknown["trustScore"] == .number(0.93))
        #expect(decoded.unknown["embeddings"]?["dims"] == .number(768))
        guard case let .unknown(typeTag, raw)? = decoded.fields["shape"] else {
            Issue.record("Expected the future value type to decode as .unknown")
            return
        }
        #expect(typeTag == "quaternion")
        #expect(raw["z"] == .number(0.5))

        // The re-emitted form still carries the future keys, so a
        // new → old → new sync hop loses nothing (the point of keeping unknown keys).
        let reEmitted = try canonical(decoded)
        let text = try #require(String(data: reEmitted, encoding: .utf8))
        #expect(text.contains("trustScore"))
        #expect(text.contains("quaternion"))
        #expect(text.contains("elv-embed-2"))
    }
}
