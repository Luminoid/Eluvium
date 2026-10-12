import Foundation
import Testing
@testable import EluviumCore

@Suite("Entity index")
struct ELVEntityIndexTests {
    /// The movie showcase: a Douban watched-list row, an IMDb ratings
    /// CSV row, and a Wikipedia list row (crosswalked through Wikidata) —
    /// three sources, three shapes, one film.
    private func makeMovieIndex() -> ELVEntityIndex {
        var index = ELVEntityIndex()
        index.register(key: ELVRecordKey(sourceId: "douban.list", externalId: "1292052"), identities: [
            ELVIdentity(namespace: "douban.film", value: "1292052", origin: .declared),
            ELVIdentity(namespace: "imdb", value: "tt0111161", origin: .declared),
        ])
        index.register(key: ELVRecordKey(sourceId: "imdb.ratings", externalId: "tt0111161"), identities: [
            ELVIdentity(namespace: "imdb", value: "tt0111161", origin: .declared),
        ])
        index.register(key: ELVRecordKey(sourceId: "wikipedia.list", externalId: "Q172241"), identities: [
            ELVIdentity(namespace: "wikidata", value: "Q172241", origin: .declared),
            ELVIdentity(namespace: "imdb", value: "tt0111161", origin: .crosswalk(via: "wikidata")),
            ELVIdentity(namespace: "douban.film", value: "1292052", origin: .crosswalk(via: "wikidata")),
        ])
        // An unrelated film stays its own entity.
        index.register(key: ELVRecordKey(sourceId: "imdb.ratings", externalId: "tt0076759"), identities: [
            ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .declared),
        ])
        return index
    }

    @Test
    func `Shared strong identities link three sources into one entity, transitively`() throws {
        let index = makeMovieIndex()
        let entity = try #require(index.entity(for: ELVRecordKey(sourceId: "douban.list", externalId: "1292052")))
        #expect(entity.members.count == 3)
        #expect(entity.members.map(\.sourceId).sorted() == ["douban.list", "imdb.ratings", "wikipedia.list"])
        #expect(entity.identities.contains(ELVIdentity(namespace: "wikidata", value: "Q172241", origin: .declared)))
        #expect(index.entities().count == 2)
    }

    @Test
    func `Lists stay intact: the index never mutates or merges records`() throws {
        let index = makeMovieIndex()
        // The entity is computed; member records keep their own identity sets.
        let doubanKey = ELVRecordKey(sourceId: "douban.list", externalId: "1292052")
        #expect(index.identitiesByRecord[doubanKey]?.count == 2)
        let solo = try #require(index.entity(for: ELVRecordKey(sourceId: "imdb.ratings", externalId: "tt0076759")))
        #expect(solo.members.count == 1)
    }

    @Test
    func `A vetoed wrong crosswalk splits the entity, losslessly and reversibly`() throws {
        var index = makeMovieIndex()
        let wikiKey = ELVRecordKey(sourceId: "wikipedia.list", externalId: "Q172241")
        // Suppose Wikidata carried the WRONG IMDb id: sever it on the wiki row.
        index.vetoIdentity(record: wikiKey, namespace: "imdb", value: "tt0111161")
        index.vetoIdentity(record: wikiKey, namespace: "douban.film", value: "1292052")

        let wikiEntity = try #require(index.entity(for: wikiKey))
        #expect(wikiEntity.members == [wikiKey])
        // The identity is still visible on the record — vetoing stops
        // linking, it does not rewrite history.
        #expect(index.identitiesByRecord[wikiKey]?.contains { $0.namespace == "imdb" } == true)
        // The other two stay linked through their declared ids.
        let doubanEntity = try #require(index.entity(for: ELVRecordKey(sourceId: "douban.list", externalId: "1292052")))
        #expect(doubanEntity.members.count == 2)
    }

    @Test
    func `Heuristic identities never auto-link; confirmation links and veto blocks resurrect`() throws {
        var index = ELVEntityIndex()
        let michelin = ELVRecordKey(sourceId: "michelin.restaurant", externalId: "benu")
        let swarm = ELVRecordKey(sourceId: "swarm.venue", externalId: "4abc")
        index.register(key: michelin, identities: [
            ELVIdentity(namespace: "michelin.restaurant", value: "benu", origin: .declared),
        ])
        index.register(key: swarm, identities: [
            ELVIdentity(namespace: "fsq.venue", value: "4abc", origin: .declared),
            // A placeMatch suggestion rides the record as a heuristic identity.
            ELVIdentity(namespace: "michelin.restaurant", value: "benu", origin: .heuristic(confidence: 0.92)),
        ])
        #expect(index.entities().count == 2)

        index.confirmLink(michelin, swarm)
        let linked = try #require(index.entity(for: michelin))
        #expect(linked.members.count == 2)

        index.vetoLink(michelin, swarm)
        #expect(index.entities().count == 2)
        // Confirming again overrides the veto (the user changed their mind).
        index.confirmLink(swarm, michelin)
        #expect(index.entities().count == 1)
    }

    @Test
    func `Weak namespaces do not link even when declared`() {
        var index = ELVEntityIndex()
        index.register(key: ELVRecordKey(sourceId: "a", externalId: "1"), identities: [
            ELVIdentity(namespace: "some.slug", value: "shared", origin: .declared),
        ])
        index.register(key: ELVRecordKey(sourceId: "b", externalId: "2"), identities: [
            ELVIdentity(namespace: "some.slug", value: "shared", origin: .declared),
        ])
        #expect(index.entities().count == 2)

        index.addStrongNamespaces(["some.slug"])
        #expect(index.entities().count == 1)
    }

    @Test
    func `Zero-confidence heuristics and unknown origins never link`() {
        var index = ELVEntityIndex()
        index.register(key: ELVRecordKey(sourceId: "a", externalId: "1"), identities: [
            ELVIdentity(namespace: "imdb", value: "tt1", origin: .heuristic(confidence: 0)),
        ])
        index.register(key: ELVRecordKey(sourceId: "b", externalId: "2"), identities: [
            ELVIdentity(namespace: "imdb", value: "tt1", origin: .declared),
        ])
        index.register(key: ELVRecordKey(sourceId: "c", externalId: "3"), identities: [
            // A future origin kind decodes to .unknown — unjudgeable here,
            // so it must not auto-link either.
            ELVIdentity(namespace: "imdb", value: "tt1", origin: .unknown(raw: "oracle")),
        ])
        #expect(index.entities().count == 3)
    }

    @Test
    func `A sourceId containing the separator round-trips through the storage key`() throws {
        let key = ELVRecordKey(sourceId: "csv|flighty", externalId: "AS6208")
        #expect(ELVRecordKey(storageKey: key.storageKey) == key)

        var index = ELVEntityIndex()
        index.register(key: key, identities: [ELVIdentity(namespace: "imdb", value: "tt1", origin: .declared)])
        let decoded = try JSONDecoder().decode(ELVEntityIndex.self, from: JSONEncoder().encode(index))
        #expect(decoded.identitiesByRecord[key] != nil)
        #expect(decoded == index)
    }

    @Test
    func `Cached components recompute after every mutation, and copies keep their own view`() throws {
        var index = makeMovieIndex()
        // Repeated queries serve the memo; every mutation must invalidate it.
        #expect(index.entities().count == 2)
        #expect(index.entities().count == 2)

        let copy = index
        index.register(key: ELVRecordKey(sourceId: "letterboxd.diary", externalId: "l1"), identities: [
            ELVIdentity(namespace: "imdb", value: "tt0111161", origin: .declared),
        ])
        let entity = try #require(index.entity(for: ELVRecordKey(sourceId: "letterboxd.diary", externalId: "l1")))
        #expect(entity.members.count == 4)
        // The pre-mutation copy answers from its own still-valid components.
        #expect(copy.entities().count == 2)

        let wikiKey = ELVRecordKey(sourceId: "wikipedia.list", externalId: "Q172241")
        index.vetoIdentity(record: wikiKey, namespace: "imdb", value: "tt0111161")
        index.vetoIdentity(record: wikiKey, namespace: "douban.film", value: "1292052")
        #expect(index.entities().count == 3)

        index.unregister(ELVRecordKey(sourceId: "letterboxd.diary", externalId: "l1"))
        #expect(index.entities().count == 3)
        #expect(index.entity(for: ELVRecordKey(sourceId: "letterboxd.diary", externalId: "l1")) == nil)
    }

    @Test
    func `Re-registration is idempotent and replaces a record's identity set`() {
        var index = makeMovieIndex()
        let before = index.entities().count
        index.register(key: ELVRecordKey(sourceId: "douban.list", externalId: "1292052"), identities: [
            ELVIdentity(namespace: "douban.film", value: "1292052", origin: .declared),
            ELVIdentity(namespace: "imdb", value: "tt0111161", origin: .declared),
        ])
        #expect(index.entities().count == before)
    }

    @Test
    func `The index round-trips through JSON with decisions and unknown keys preserved`() throws {
        var index = makeMovieIndex()
        index.confirmLink(
            ELVRecordKey(sourceId: "imdb.ratings", externalId: "tt0076759"),
            ELVRecordKey(sourceId: "douban.list", externalId: "1292052")
        )
        index.vetoIdentity(record: ELVRecordKey(sourceId: "wikipedia.list", externalId: "Q172241"), namespace: "imdb", value: "tt0111161")
        index.unknown["futureKnob"] = .bool(true)

        let decoded = try JSONDecoder().decode(ELVEntityIndex.self, from: JSONEncoder().encode(index))
        #expect(decoded == index)
        #expect(decoded.unknown["futureKnob"] == .bool(true))
        #expect(decoded.entities() == index.entities())
    }

    @Test
    func `Records lacking an externalId cannot join the graph`() {
        var index = ELVEntityIndex()
        let record = ELVRecord(sourceId: "s", kind: "k", identities: [ELVIdentity(namespace: "imdb", value: "tt1", origin: .declared)])
        index.register(record)
        #expect(index.entities().isEmpty)
        #expect(ELVRecordKey(record) == nil)
    }

    @Test
    func `A strong namespace a pack declares links two records once the host adds it`() throws {
        let json = #"{"schemaVersion": 1, "packVersion": "t", "strongNamespaces": ["goodreads.book"], "sources": []}"#
        let pack = try ELVPackLoader.load(embedded: Data(json.utf8))
        let shelf = ELVRecordKey(sourceId: "goodreads.shelf", externalId: "1")
        let review = ELVRecordKey(sourceId: "blog.review", externalId: "p9")
        var index = ELVEntityIndex()
        index.register(key: shelf, identities: [ELVIdentity(namespace: "goodreads.book", value: "4671", origin: .declared)])
        index.register(key: review, identities: [ELVIdentity(namespace: "goodreads.book", value: "4671", origin: .crosswalk(via: "wikidata"))])
        #expect(index.entity(for: shelf)?.members == [shelf])

        index.addStrongNamespaces(pack.strongNamespaces)
        #expect(index.entity(for: shelf)?.members.sorted() == [review, shelf].sorted())
        #expect(ELVIdentityNamespaces.isStrong("goodreads.book") == false)
    }

    @Test
    func `vetoLink reports whether the pair actually came apart`() {
        var index = ELVEntityIndex()
        let first = ELVRecordKey(sourceId: "a", externalId: "1")
        let second = ELVRecordKey(sourceId: "b", externalId: "2")
        let third = ELVRecordKey(sourceId: "c", externalId: "3")
        index.register(key: first, identities: [ELVIdentity(namespace: "imdb", value: "tt1", origin: .declared)])
        index.register(key: second, identities: [ELVIdentity(namespace: "imdb", value: "tt1", origin: .declared)])
        index.register(key: third, identities: [ELVIdentity(namespace: "yelp.business", value: "x", origin: .declared)])

        // Joined by a shared strong identity: the veto is stored but cannot cut it.
        let cutShared = index.vetoLink(first, second)
        #expect(cutShared == false)
        #expect(index.pairVetoes.contains(ELVRecordPair(first, second)))
        #expect(index.entity(for: first)?.members.contains(second) == true)
        // A confirmed link is exactly what a pair veto cuts.
        index.confirmLink(first, third)
        #expect(index.entity(for: third)?.members.contains(first) == true)
        let cutConfirmed = index.vetoLink(first, third)
        #expect(cutConfirmed)
        #expect(index.entity(for: third)?.members == [third])
    }
}
