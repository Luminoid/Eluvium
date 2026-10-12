import Foundation
import Testing
@testable import EluviumCore

@Suite("ELVRecord coding")
struct ELVRecordCodingTests {
    private func makeRecord() throws -> ELVRecord {
        let url = try #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))
        return ELVRecord(
            sourceId: "alltrails.trail",
            sourceURL: url,
            externalId: "hidden-falls-trail",
            kind: "trail",
            fields: [
                "title": .text("Hidden Falls Trail"),
                "distance": .number(7.2),
                "rating": .rating(value: 4.7, scale: 0 ... 5),
            ],
            collections: [
                "photos": [
                    ELVRecord(sourceId: "alltrails.trail", externalId: "p1", kind: "photo"),
                ],
            ],
            identities: [ELVIdentity(namespace: "alltrails.trail", value: "hidden-falls-trail", origin: .declared)],
            provenance: ["title": ELVProvenance(origin: "css:h1", candidateIndex: 0)]
        )
    }

    @Test
    func `A fully-populated record round-trips through JSON`() throws {
        let record = try makeRecord()
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ELVRecord.self, from: data)
        #expect(decoded == record)
    }

    @Test
    func `Unrecognized top-level keys are preserved and re-emitted unchanged`() throws {
        let wire = """
        {
          "formatVersion": 3,
          "sourceId": "future.source",
          "kind": "trail",
          "fields": {"title": {"type": "text", "value": "A"}},
          "embeddings": {"model": "elv-embed-2", "vector": [0.1, 0.2]},
          "trustScore": 0.93
        }
        """
        let decoded = try JSONDecoder().decode(ELVRecord.self, from: Data(wire.utf8))
        #expect(decoded.formatVersion == 3)
        #expect(decoded.unknown["embeddings"]?["model"] == .string("elv-embed-2"))
        #expect(decoded.unknown["trustScore"] == .number(0.93))

        let reEncoded = try JSONEncoder().encode(decoded)
        let original = try JSONDecoder().decode(ELVRawJSON.self, from: Data(wire.utf8))
        let roundTripped = try JSONDecoder().decode(ELVRawJSON.self, from: reEncoded)
        #expect(roundTripped == original)
    }

    @Test
    func `A record with unknown value payloads survives decode → encode → decode`() throws {
        let wire = """
        {
          "sourceId": "future.source",
          "kind": "thing",
          "fields": {"shape": {"type": "polytope", "dims": 4}}
        }
        """
        let decoded = try JSONDecoder().decode(ELVRecord.self, from: Data(wire.utf8))
        guard case let .unknown(typeTag, _) = try #require(decoded.fields["shape"]) else {
            Issue.record("Expected .unknown field")
            return
        }
        #expect(typeTag == "polytope")
        let secondPass = try JSONDecoder().decode(ELVRecord.self, from: JSONEncoder().encode(decoded))
        #expect(secondPass == decoded)
    }

    @Test
    func `Missing optional containers decode as empty, and empty containers are omitted on encode`() throws {
        let wire = #"{"sourceId": "s", "kind": "k"}"#
        let decoded = try JSONDecoder().decode(ELVRecord.self, from: Data(wire.utf8))
        #expect(decoded.fields.isEmpty)
        #expect(decoded.collections.isEmpty)
        #expect(decoded.formatVersion == 1)

        let reEncoded = try JSONDecoder().decode(ELVRawJSON.self, from: JSONEncoder().encode(decoded))
        #expect(reEncoded["fields"] == nil)
        #expect(reEncoded["collections"] == nil)
    }

    @Test
    func `A sourceURL that no longer parses drops the URL, not the record`() throws {
        let wire = #"{"sourceId": "s", "kind": "k", "sourceURL": ""}"#
        let decoded = try JSONDecoder().decode(ELVRecord.self, from: Data(wire.utf8))
        #expect(decoded.sourceURL == nil)
        #expect(decoded.sourceId == "s")
        let intact = try JSONDecoder().decode(ELVRecord.self, from: Data(#"{"sourceId": "s", "kind": "k", "sourceURL": "https://example.com/x"}"#.utf8))
        #expect(intact.sourceURL?.absoluteString == "https://example.com/x")
    }

    @Test
    func `An unknown identity origin is preserved and re-emitted, never rewritten to a known kind`() throws {
        let wire = """
        {
          "sourceId": "s",
          "kind": "k",
          "identities": [{"namespace": "imdb", "value": "tt1", "origin": {"kind": "oracle"}}]
        }
        """
        let decoded = try JSONDecoder().decode(ELVRecord.self, from: Data(wire.utf8))
        #expect(decoded.identities.first?.origin == .unknown(raw: "oracle"))
        // The old fail-safe re-encoded this as "heuristic", permanently
        // rewriting future origin kinds on the first round trip.
        let reEncoded = try #require(String(data: JSONEncoder().encode(decoded), encoding: .utf8))
        #expect(reEncoded.contains(#""kind":"oracle""#))
        #expect(!reEncoded.contains("heuristic"))
    }
}
