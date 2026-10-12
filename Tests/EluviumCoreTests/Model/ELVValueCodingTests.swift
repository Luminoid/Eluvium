import Foundation
import Testing
@testable import EluviumCore

@Suite("ELVValue coding")
struct ELVValueCodingTests {
    private func roundTrip(_ value: ELVValue) throws -> ELVValue {
        let data = try JSONEncoder().encode([value])
        return try #require(JSONDecoder().decode([ELVValue].self, from: data).first)
    }

    @Test
    func `Every leaf case round-trips through JSON`() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let cases: [ELVValue] = [
            .text("Hidden Falls Trail"),
            .number(4.5),
            .money(minorUnits: 129_900, currencyCode: "EUR"),
            .date(Date(timeIntervalSince1970: 1_723_400_000), precision: .day),
            .duration(5400),
            .url(url),
            .phone("+1 415-555-0100"),
            .address(ELVPostalAddress(street: "1 Ferry Building", locality: "San Francisco", region: "CA", postalCode: "94111", countryCode: "US")),
            .geo(latitude: 43.7904, longitude: -110.7624),
            .media(ELVMediaRef(url: url, kind: ELVMediaRef.image, alt: "cover")),
            .rating(value: 4.7, scale: 0 ... 5),
            .tags(["hiking", "waterfall"]),
            .list([.text("a"), .number(1)]),
        ]
        for value in cases {
            #expect(try roundTrip(value) == value)
        }
    }

    @Test
    func `Nested record values round-trip`() throws {
        let child = ELVRecord(sourceId: "tmdb.person", externalId: "1", kind: "person", fields: ["name": .text("Mark Hamill")])
        let value = ELVValue.record(child)
        #expect(try roundTrip(value) == value)
    }

    @Test
    func `An unknown type tag decodes to .unknown and re-emits its payload unchanged`() throws {
        let wire = #"[{"type":"hologram","frames":3,"payload":{"depth":2,"codec":"hvc1"}}]"#
        let decoded = try #require(JSONDecoder().decode([ELVValue].self, from: Data(wire.utf8)).first)
        guard case let .unknown(typeTag, raw) = decoded else {
            Issue.record("Expected .unknown, got \(decoded)")
            return
        }
        #expect(typeTag == "hologram")
        #expect(raw["frames"] == .number(3))

        let reEncoded = try JSONEncoder().encode([decoded])
        let original = try JSONDecoder().decode([ELVRawJSON].self, from: Data(wire.utf8))
        let roundTripped = try JSONDecoder().decode([ELVRawJSON].self, from: reEncoded)
        #expect(roundTripped == original)
    }

    @Test
    func `An unknown shape decodes to .unknown and re-emits its payload unchanged`() throws {
        // The escape hatch covers unknown *shape*, not just unknown tags: a
        // bare scalar, an object without "type", a non-string "type", null.
        for wire in [#"[42]"#, #"["free text"]"#, #"[{"w": 1, "x": 0.5}]"#, #"[{"type": 42}]"#, #"[null]"#] {
            let decoded = try #require(JSONDecoder().decode([ELVValue].self, from: Data(wire.utf8)).first)
            guard case .unknown(typeTag: "(unshaped)", raw: _) = decoded else {
                Issue.record("Expected .unknown for \(wire), got \(decoded)")
                continue
            }
            let reEncoded = try JSONEncoder().encode([decoded])
            let original = try JSONDecoder().decode([ELVRawJSON].self, from: Data(wire.utf8))
            #expect(try JSONDecoder().decode([ELVRawJSON].self, from: reEncoded) == original, "\(wire)")
        }
    }

    @Test
    func `An unknown date precision decodes and re-encodes as its own token`() throws {
        let wire = #"[{"type":"date","epochSeconds":0,"precision":"fortnight"}]"#
        let decoded = try #require(JSONDecoder().decode([ELVValue].self, from: Data(wire.utf8)).first)
        #expect(decoded == .date(Date(timeIntervalSince1970: 0), precision: .unknown("fortnight")))
        let reEncoded = try JSONDecoder().decode([ELVRawJSON].self, from: JSONEncoder().encode([decoded]))
        #expect(reEncoded.first?["precision"] == .string("fortnight"))
        #expect(ELVDatePrecision(rawValue: "day") == .day)
        #expect(ELVDatePrecision.unknown("fortnight").rawValue == "fortnight")
    }

    @Test
    func `Address and media leaves keep a newer binary's keys through a round trip`() throws {
        let wire = #"""
        [{"type": "address", "address": {"street": "1 Ferry Building", "plusCode": "849VQHFJ+X6", "geo": {"lat": 37.79}}},
         {"type": "media", "media": {"url": "https://img.example/a.jpg", "kind": "image", "width": 1200, "blurhash": "LEHV6n"}}]
        """#
        let decoded = try JSONDecoder().decode([ELVValue].self, from: Data(wire.utf8))
        guard case let .address(address) = decoded[0], case let .media(media) = decoded[1] else {
            Issue.record("Expected typed address and media leaves, got \(decoded)")
            return
        }
        #expect(address.street == "1 Ferry Building")
        #expect(address.unknown["plusCode"] == .string("849VQHFJ+X6"))
        #expect(media.kind == ELVMediaRef.image)
        #expect(media.unknown["width"] == .number(1200))

        let original = try JSONDecoder().decode(ELVRawJSON.self, from: Data(wire.utf8))
        let roundTripped = try JSONDecoder().decode(ELVRawJSON.self, from: JSONEncoder().encode(decoded))
        #expect(roundTripped == original)
    }

    @Test
    func `Emptiness counts blank text, empty tags, and empty lists`() {
        #expect(ELVValue.text("  \n").isEmpty)
        #expect(ELVValue.tags([]).isEmpty)
        #expect(ELVValue.list([]).isEmpty)
        #expect(!ELVValue.text("x").isEmpty)
        #expect(!ELVValue.number(0).isEmpty)
        #expect(!ELVValue.money(minorUnits: 0, currencyCode: "USD").isEmpty)
    }

    @Test
    func `A malformed known-tag payload degrades to .unknown instead of throwing`() throws {
        // The additive-only promise: one bad leaf (an inverted rating
        // scale, a missing key) must never discard the record tree. The
        // payload rides .unknown verbatim, so nothing is lost on re-encode.
        let inverted = #"[{"type":"rating","value":3,"scaleMin":5,"scaleMax":0}]"#
        let decoded = try #require(JSONDecoder().decode([ELVValue].self, from: Data(inverted.utf8)).first)
        guard case let .unknown(typeTag, raw) = decoded else {
            Issue.record("Expected .unknown, got \(decoded)")
            return
        }
        #expect(typeTag == "rating")
        #expect(raw["scaleMin"] == .number(5))

        let missingKey = #"[{"type":"money","currencyCode":"USD"}]"#
        let money = try #require(JSONDecoder().decode([ELVValue].self, from: Data(missingKey.utf8)).first)
        guard case .unknown("money", _) = money else {
            Issue.record("Expected .unknown for the keyless money leaf")
            return
        }
    }

    @Test
    func `A record survives one malformed leaf; the siblings decode typed`() throws {
        let wire = """
        {"sourceId": "s", "kind": "movie", "fields": {
          "title": {"type": "text", "value": "Alien"},
          "rating": {"type": "rating", "value": 3, "scaleMin": 5, "scaleMax": 0}
        }}
        """
        let record = try JSONDecoder().decode(ELVRecord.self, from: Data(wire.utf8))
        #expect(record.fields["title"] == .text("Alien"))
        guard case .unknown("rating", _)? = record.fields["rating"] else {
            Issue.record("Expected the bad rating to land as .unknown")
            return
        }
    }
}

@Suite("Media referer")
struct ELVMediaRefererTests {
    @Test
    func `A media ref's referer round-trips, and refs written before it decode unchanged`() throws {
        let url = try #require(URL(string: "https://img.example/cover.jpg"))
        let page = try #require(URL(string: "https://movie.example/subject/1"))
        let value = ELVValue.media(ELVMediaRef(url: url, kind: ELVMediaRef.image, referer: page))
        let data = try JSONEncoder().encode([value])
        #expect(try JSONDecoder().decode([ELVValue].self, from: data).first == value)

        // A pre-referer payload (no key at all) decodes with referer nil.
        let legacy = Data(#"[{"type":"media","media":{"url":"https://img.example/cover.jpg","kind":"image"}}]"#.utf8)
        let decoded = try #require(JSONDecoder().decode([ELVValue].self, from: legacy).first)
        #expect(decoded == .media(ELVMediaRef(url: url, kind: ELVMediaRef.image)))
    }

    @Test
    func `imageReferer "page" stamps assembled media refs with the page URL, top-level and in collections`() throws {
        let source = ELVSource(
            id: "douban.like",
            kind: "movie",
            fields: [
                ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))]),
                ELVFieldSpec(name: "image", candidates: [ELVCandidate(from: .json("$.cover"), coercion: ELVCoercion(kind: "image"))]),
            ],
            collections: [
                ELVCollectionSpec(name: "stills", from: .json("$.stills[*]"), item: [
                    ELVFieldSpec(name: "image", candidates: [ELVCandidate(from: .json("$.src"), coercion: ELVCoercion(kind: "image"))]),
                ]),
            ],
            imageReferer: "page"
        )
        let page = try #require(URL(string: "https://movie.example/subject/1292052/"))
        let body = ELVRawJSON.object([
            "title": .string("A Film"),
            "cover": .string("https://img.example/cover.jpg"),
            "stills": .array([.object(["src": .string("https://img.example/still1.jpg")])]),
        ])
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: page, document: ELVDocument(json: body)))
        guard case let .media(cover)? = record.fields["image"] else {
            Issue.record("no cover media"); return
        }
        #expect(cover.referer == page)
        guard case let .media(still)? = record.collections["stills"]?.first?.fields["image"] else {
            Issue.record("no still media"); return
        }
        #expect(still.referer == page)

        // Without the key, nothing is stamped.
        var plain = source
        plain.imageReferer = nil
        let bare = ELVAssembler.assemble(source: plain, context: ELVExtractionContext(url: page, document: ELVDocument(json: body)))
        guard case let .media(bareCover)? = bare.fields["image"] else {
            Issue.record("no bare cover"); return
        }
        #expect(bareCover.referer == nil)
    }
}
