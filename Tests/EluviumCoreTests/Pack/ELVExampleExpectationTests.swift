import EluviumCore
import Foundation
import Testing

/// The corpus expectation check that the health run, a host's corpus
/// screen, and its log all report, so they can never disagree.
@Suite("Example expectations")
struct ELVExampleExpectationTests {
    @Test
    func `Expectation checks cover kind and non-empty fields`() {
        let example = ELVExample(input: "https://example.com/x", expectedKind: "trail", expectedNonEmpty: ["title", "distance", "blurb"])
        let bad = ELVRecord(sourceId: "s", kind: "product", fields: ["title": .text("A"), "blurb": .text("   ")])
        #expect(example.unmetExpectations(for: bad) == [
            "kind trail (got product)",
            "non-empty distance (missing)",
            "non-empty blurb (empty)",
        ])
        let good = ELVRecord(sourceId: "s", kind: "trail", fields: ["title": .text("A"), "distance": .number(5), "blurb": .text("b")])
        #expect(example.unmetExpectations(for: good).isEmpty)
    }

    @Test
    func `Expected externalId reads the promoted record id, and a url-hash floor id does not satisfy it`() {
        // The assembler pops the externalId field onto the record, so the
        // checker must not look for it in `fields` (hotels.lodging pins it).
        let example = ELVExample(input: "https://example.com/x", expectedNonEmpty: ["externalId"])
        let lifted = ELVRecord(sourceId: "s", externalId: "432368", kind: "lodging")
        #expect(example.unmetExpectations(for: lifted).isEmpty)
        let floor = ELVRecord(sourceId: "s", externalId: "url:8d4c8fbf11e86f98", kind: "lodging")
        #expect(example.unmetExpectations(for: floor) == ["non-empty externalId (missing)"])
        let absent = ELVRecord(sourceId: "s", kind: "lodging")
        #expect(example.unmetExpectations(for: absent) == ["non-empty externalId (missing)"])
    }

    @Test
    func `An example with no expectations always passes`() {
        let example = ELVExample(input: "https://example.com/x")
        #expect(example.unmetExpectations(for: ELVRecord(sourceId: "s", kind: "")).isEmpty)
    }

    @Test
    func `Collection expectations decode leniently and name missing or empty collections`() throws {
        let wire = #"""
        [{"input": "https://example.com/album/1", "expect": {"kind": "album", "nonEmptyCollections": ["tracks", "credits", "art"]}},
         {"input": "https://example.com/list", "expect": {"nonEmptyCollections": "items"}}]
        """#
        let examples = try JSONDecoder().decode([ELVExample].self, from: Data(wire.utf8))
        #expect(examples[0].expectedNonEmptyCollections == ["tracks", "credits", "art"])
        #expect(examples[1].expectedNonEmptyCollections == ["items"])

        let track = ELVRecord(sourceId: "s", kind: "track")
        let album = ELVRecord(sourceId: "s", kind: "album", collections: ["tracks": [track], "credits": []])
        #expect(examples[0].unmetExpectations(for: album) == [
            "non-empty collection credits (empty)",
            "non-empty collection art (missing)",
        ])
        let full = ELVExample(input: "x", expectedNonEmptyCollections: ["tracks"])
        #expect(full.unmetExpectations(for: album).isEmpty)
    }
}
