import Foundation
import Testing
@testable import EluviumCore

@Suite("ELVRecord merging")
struct ELVMergeTests {
    private func existingRecord() -> ELVRecord {
        ELVRecord(
            sourceId: "chewy.product",
            externalId: "54767",
            kind: "product",
            fields: [
                "title": .text("User Edited Title"),
                "notes": .text(""),
            ],
            provenance: ["title": ELVProvenance(origin: "user")]
        )
    }

    @Test
    func `.fillEmptyOnly keeps existing values and fills only absent or empty fields`() {
        let incoming = ELVRecord(
            sourceId: "chewy.product",
            externalId: "54767",
            kind: "product",
            fields: [
                "title": .text("Scraped Title"),
                "notes": .text("Scraped notes"),
                "price": .money(minorUnits: 5499, currencyCode: "USD"),
            ],
            provenance: [
                "title": ELVProvenance(origin: "meta:og:title"),
                "notes": ELVProvenance(origin: "css:.notes"),
                "price": ELVProvenance(origin: "jsonld:Product.offers.price"),
            ]
        )
        let merged = existingRecord().merging(incoming, policy: .fillEmptyOnly)
        #expect(merged.fields["title"] == .text("User Edited Title"))
        #expect(merged.fields["notes"] == .text("Scraped notes"))
        #expect(merged.fields["price"] == .money(minorUnits: 5499, currencyCode: "USD"))
        #expect(merged.provenance["title"]?.origin == "user")
        #expect(merged.provenance["price"]?.origin == "jsonld:Product.offers.price")
    }

    @Test
    func `.preferIncoming overrides with non-empty incoming values but never erases with empty ones`() {
        let incoming = ELVRecord(
            sourceId: "chewy.product",
            externalId: "54767",
            kind: "product",
            fields: [
                "title": .text("Fresh Title"),
                "notes": .text(""),
            ]
        )
        let merged = existingRecord().merging(incoming, policy: .preferIncoming)
        #expect(merged.fields["title"] == .text("Fresh Title"))
        #expect(merged.fields["notes"] == .text(""))
    }

    @Test
    func `Keyed collections merge by externalId: matches merge recursively, new children append`() {
        let existing = ELVRecord(
            sourceId: "podcast.show",
            kind: "podcast",
            collections: [
                "episodes": [
                    ELVRecord(sourceId: "podcast.show", externalId: "e1", kind: "episode", fields: ["title": .text("One"), "played": .number(1)]),
                ],
            ]
        )
        let incoming = ELVRecord(
            sourceId: "podcast.show",
            kind: "podcast",
            collections: [
                "episodes": [
                    ELVRecord(sourceId: "podcast.show", externalId: "e1", kind: "episode", fields: ["title": .text("One (remastered)")]),
                    ELVRecord(sourceId: "podcast.show", externalId: "e2", kind: "episode", fields: ["title": .text("Two")]),
                ],
            ]
        )
        let merged = existing.merging(incoming, policy: .fillEmptyOnly)
        let episodes = merged.collections["episodes"] ?? []
        #expect(episodes.count == 2)
        #expect(episodes.first?.fields["title"] == .text("One"))
        #expect(episodes.first?.fields["played"] == .number(1))
        #expect(episodes.last?.fields["title"] == .text("Two"))

        let replaced = existing.merging(incoming, policy: .preferIncoming)
        #expect(replaced.collections["episodes"]?.first?.fields["title"] == .text("One (remastered)"))
        #expect(replaced.collections["episodes"]?.first?.fields["played"] == .number(1))
    }

    @Test
    func `Unkeyed collections cannot correlate: fillEmptyOnly keeps existing, preferIncoming replaces`() {
        let existing = ELVRecord(
            sourceId: "s",
            kind: "k",
            collections: ["notes": [ELVRecord(sourceId: "s", kind: "note", fields: ["text": .text("old")])]]
        )
        let incoming = ELVRecord(
            sourceId: "s",
            kind: "k",
            collections: ["notes": [ELVRecord(sourceId: "s", kind: "note", fields: ["text": .text("new")])]]
        )
        let kept = existing.merging(incoming, policy: .fillEmptyOnly)
        #expect(kept.collections["notes"]?.first?.fields["text"] == .text("old"))
        let replaced = existing.merging(incoming, policy: .preferIncoming)
        #expect(replaced.collections["notes"]?.first?.fields["text"] == .text("new"))
    }

    @Test
    func `Identities union without duplicates`() {
        let existing = ELVRecord(
            sourceId: "douban.film",
            kind: "movie",
            identities: [ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .declared)]
        )
        let incoming = ELVRecord(
            sourceId: "douban.film",
            kind: "movie",
            identities: [
                ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .declared),
                ELVIdentity(namespace: "douban.film", value: "1292052", origin: .declared),
            ]
        )
        let merged = existing.merging(incoming, policy: .fillEmptyOnly)
        #expect(merged.identities.count == 2)
    }

    @Test
    func `Unknown bags merge under the policy so newer-binary data survives a merge on this binary`() {
        var existing = existingRecord()
        existing.unknown["embeddings"] = .string("old")
        var incoming = existingRecord()
        incoming.unknown["embeddings"] = .string("new")
        incoming.unknown["extra"] = .number(1)

        let kept = existing.merging(incoming, policy: .fillEmptyOnly)
        #expect(kept.unknown["embeddings"] == .string("old"))
        #expect(kept.unknown["extra"] == .number(1))

        let replaced = existing.merging(incoming, policy: .preferIncoming)
        #expect(replaced.unknown["embeddings"] == .string("new"))
    }

    @Test
    func `preferIncoming replaces a corrected declared id per namespace and keeps other sources' identities`() {
        let existing = ELVRecord(sourceId: "douban.film", externalId: "1", kind: "movie", identities: [
            ELVIdentity(namespace: "imdb", value: "tt0000001", origin: .declared),
            ELVIdentity(namespace: "douban.film", value: "1", origin: .declared),
            ELVIdentity(namespace: "imdb", value: "tt0000002", origin: .crosswalk(via: "wikidata")),
            ELVIdentity(namespace: "tmdb.movie", value: "11", origin: .heuristic(confidence: 0.8)),
        ])
        let incoming = ELVRecord(sourceId: "douban.film", externalId: "1", kind: "movie", identities: [
            ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .declared),
        ])
        let preferred = existing.merging(incoming, policy: .preferIncoming)
        #expect(preferred.identities == [
            ELVIdentity(namespace: "douban.film", value: "1", origin: .declared),
            ELVIdentity(namespace: "imdb", value: "tt0000002", origin: .crosswalk(via: "wikidata")),
            ELVIdentity(namespace: "tmdb.movie", value: "11", origin: .heuristic(confidence: 0.8)),
            ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .declared),
        ])
        // fillEmptyOnly still unions: the stale id stays beside the new one.
        let filled = existing.merging(incoming, policy: .fillEmptyOnly)
        #expect(filled.identities.count == 5)
    }
}
