import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The `lists.*` chunk: seeded inventory (Wikidata SPARQL, regexRows over
/// server-rendered markup, inline entries), recognition of the two lists
/// with a pasteable URL, and the entry identities that put a list row and
/// the record it points at into one entity.
@Suite("Starter pack list sources")
struct ELVStarterListsSourcesTests {
    private func loaded() throws -> ELVLoadedPack {
        try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
    }

    /// Assembles a seeded list from a captured body at its own seed URL.
    private func assembleSeed(_ id: String, document: ELVDocument) throws -> ELVRecord {
        let source = try #require(try loaded().source(withId: id), "\(id)")
        let seed = try #require(source.seed.flatMap { URL(string: $0) }, "\(id)")
        return ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: seed, document: document))
    }

    /// Recognizes `url` and assembles the URL-only record (empty document).
    private func assemble(_ url: String) throws -> ELVRecord {
        let pack = try loaded()
        let target = try #require(URL(string: url))
        let recognition = try #require(pack.registry.recognize(target), "\(url) did not recognize")
        let source = try #require(pack.source(withId: recognition.sourceId))
        return ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: target, params: recognition.params, document: ELVDocument()))
    }

    private func sparql(_ bindings: String) throws -> ELVDocument {
        let node = try #require(ELVRawJSON.parse(Data(#"{"head": {"vars": []}, "results": {"bindings": [\#(bindings)]}}"#.utf8)))
        return ELVDocument(json: node)
    }

    private func key(_ record: ELVRecord) throws -> ELVRecordKey {
        try ELVRecordKey(sourceId: record.sourceId, externalId: #require(record.externalId))
    }

    // MARK: - Inventory

    @Test
    func `Seeded list sources load as browsable inventory, never as floors, and their entries assemble`() throws {
        let pack = try loaded()
        let seeded = pack.seededSources.map(\.id)
        #expect(seeded == [
            "lists.oscars.bestpicture", "lists.tga.goty", "lists.ign.tens", "lists.applemusic.100best",
            "lists.michelin.la", "lists.liucixin.books", "lists.vangogh.paintings",
        ])
        #expect(pack.genericFloors.map(\.id) == ["generic.feed", "generic.opengraph"])
        // The walkable-catalog roster (list specs) is pack config, so a
        // host never hardcodes catalog ids: exactly the dex today.
        #expect(pack.enumerableSources.map(\.id) == ["pokeapi.dex"])
        // Michelin entries are restaurants: the `food` kind Yelp and
        // Tripadvisor restaurant records carry, not a generic map `place`.
        #expect(pack.source(withId: "lists.michelin.la")?.collections.first?.kind == "food")

        // The inline-entries list assembles offline: the pack IS the list.
        let ign = try #require(pack.source(withId: "lists.ign.tens"))
        let seedString = try #require(ign.seed)
        let seedURL = try #require(URL(string: seedString))
        let record = ELVAssembler.assemble(source: ign, context: ELVExtractionContext(url: seedURL, document: ELVDocument()))
        let entries = try #require(record.collections["entries"])
        #expect(entries.count == 16)
        #expect(entries.allSatisfy { $0.kind == "game" })
        let eldenRing = try #require(entries.first { $0.externalId == "elden-ring" })
        #expect(eldenRing.fields["title"] == .text("Elden Ring"))
        #expect(eldenRing.fields["year"] == .number(2022))
    }

    @Test
    func `The 100 Best and Michelin list URLs recognize, and the Wikidata seeds are pack-authored https`() throws {
        let pack = try loaded()
        let hundred = try #require(URL(string: "https://100best.music.apple.com/us"))
        #expect(pack.registry.recognize(hundred)?.sourceId == "lists.applemusic.100best")
        let michelin = try #require(URL(string: "https://guide.michelin.com/us/en/california/us-los-angeles/restaurants"))
        #expect(pack.registry.recognize(michelin)?.sourceId == "lists.michelin.la")
        for source in pack.seededSources {
            let seedString = try #require(source.seed, "\(source.id)")
            let seed = try #require(URL(string: seedString), "\(source.id)")
            #expect(seed.scheme == "https", "\(source.id)")
        }
    }

    @Test
    func `A list whose title falls back to a const pins its entries in every example`() throws {
        // The const title passes a dead fetch, so the entries are the canary.
        let pack = try loaded()
        for id in ["lists.applemusic.100best", "lists.michelin.la"] {
            let source = try #require(pack.source(withId: id))
            let title = try #require(source.fields.first { $0.name == "title" })
            #expect(title.candidates.contains { if case .const = $0.from { true } else { false } }, "\(id)")
            #expect(source.examples.count >= 2, "\(id)")
            for example in source.examples {
                #expect(example.expectedNonEmptyCollections.contains("entries"), "\(example.input)")
            }
        }
    }

    // MARK: - Entry identities

    @Test
    func `Van Gogh and Liu Cixin entries key on their Wikidata QIDs`() throws {
        // Trimmed WDQS answer shapes (the bare-label book id is illustrative).
        let paintings = try assembleSeed("lists.vangogh.paintings", document: sparql(#"""
        {"painting": {"type": "uri", "value": "http://www.wikidata.org/entity/Q45585"},
         "paintingLabel": {"type": "literal", "value": "The Starry Night"}, "year": {"value": "1889"},
         "img": {"type": "uri", "value": "http://commons.wikimedia.org/wiki/Special:FilePath/Van%20Gogh%20-%20Starry%20Night.jpg"}}
        """#))
        let painting = try #require(paintings.collections["entries"]?.first)
        #expect(painting.kind == "artwork")
        #expect(painting.externalId == "Q45585")
        #expect(painting.identities == [ELVIdentity(namespace: "wikidata", value: "Q45585", origin: .declared)])
        let image = try #require(URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/Van%20Gogh%20-%20Starry%20Night.jpg"))
        #expect(painting.fields["image"] == .media(ELVMediaRef(url: image, kind: ELVMediaRef.image)))

        // A book with no English Wikipedia article still has its QID.
        let books = try assembleSeed("lists.liucixin.books", document: sparql(#"""
        {"book": {"type": "uri", "value": "http://www.wikidata.org/entity/Q607112"}, "bookLabel": {"value": "The Three-Body Problem"},
         "year": {"value": "2008"}, "article": {"type": "uri", "value": "https://en.wikipedia.org/wiki/The_Three-Body_Problem_(novel)"}},
        {"book": {"type": "uri", "value": "http://www.wikidata.org/entity/Q100002"}, "bookLabel": {"value": "Q100002"}, "year": {"value": "2014"}}
        """#))
        let entries = try #require(books.collections["entries"])
        #expect(entries.map(\.externalId) == ["Q607112", "Q100002"])
        #expect(entries.first?.identities == [ELVIdentity(namespace: "wikidata", value: "Q607112", origin: .declared)])
        // A bare-QID label is no title; the entry stands on its id.
        #expect(entries.last?.fields["title"] == nil)
        let article = try #require(URL(string: "https://en.wikipedia.org/wiki/The_Three-Body_Problem_(novel)"))
        #expect(entries.first?.fields["url"] == .url(article))
    }

    @Test
    func `IGN and 100 Best entries declare the namespace of the record they point at`() throws {
        let ign = try assembleSeed("lists.ign.tens", document: ELVDocument())
        let eldenRing = try #require(ign.collections["entries"]?.first { $0.externalId == "elden-ring" })
        #expect(eldenRing.identities == [ELVIdentity(namespace: "ign.game", value: "elden-ring", origin: .declared)])

        let html = #"""
        <html><body><script>window.data=[{position:"1",kind:"album",url:"https://music.apple.com/us/album/the-miseducation-of-lauryn-hill/1440769883",\#
        name:"The Miseducation of Lauryn Hill",artistName:"Ms. Lauryn Hill"}]</script></body></html>
        """#
        let hundred = try assembleSeed("lists.applemusic.100best", document: ELVDocument(html: html))
        let album = try #require(hundred.collections["entries"]?.first)
        #expect(album.externalId == "1440769883")
        #expect(album.identities == [ELVIdentity(namespace: "applemusic.album", value: "1440769883", origin: .declared)])
        // The const title fallback is why the examples pin the entries.
        #expect(hundred.fields["title"] == .text("Apple Music 100 Best Albums"))
    }

    @Test
    func `A list entry and the record it points at land in one entity through the pack's strong namespaces`() throws {
        let pack = try loaded()
        let tga = try assembleSeed("lists.tga.goty", document: sparql(#"""
        {"gameLabel": {"value": "Sekiro: Shadows Die Twice"}, "year": {"value": "2019"}, "igdb": {"value": "sekiro-shadows-die-twice"}}
        """#))
        let entry = try #require(tga.collections["entries"]?.first)
        let game = try assemble("https://www.igdb.com/games/sekiro-shadows-die-twice")
        #expect(game.sourceId == "igdb.game")

        var index = ELVEntityIndex()
        for record in [entry, game] {
            try index.register(key: key(record), identities: record.identities)
        }
        // `igdb.game` is pack vocabulary, not a binary built-in: without the
        // pack's strong set the two records stay apart.
        #expect(!ELVIdentityNamespaces.isStrong("igdb.game"))
        #expect(index.entities().count == 2)

        index.addStrongNamespaces(pack.strongNamespaces)
        let entity = try #require(index.entity(for: key(game)))
        #expect(try Set(entity.members) == [key(entry), key(game)])

        // The same holds for a 100 Best row and the pasted Apple Music album.
        let html = #"""
        <html><body><script>window.data=[{position:"1",url:"https://music.apple.com/us/album/the-miseducation-of-lauryn-hill/1440769883",\#
        name:"The Miseducation of Lauryn Hill",artistName:"Ms. Lauryn Hill"}]</script></body></html>
        """#
        let row = try #require(try assembleSeed("lists.applemusic.100best", document: ELVDocument(html: html)).collections["entries"]?.first)
        let albumPage = try assemble("https://music.apple.com/us/album/the-miseducation-of-lauryn-hill/1440769883")
        try index.register(key: key(row), identities: row.identities)
        try index.register(key: key(albumPage), identities: albumPage.identities)
        let albumEntity = try #require(index.entity(for: key(albumPage)))
        #expect(try Set(albumEntity.members) == [key(row), key(albumPage)])
    }
}
