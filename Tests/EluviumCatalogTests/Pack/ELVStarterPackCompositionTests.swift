import Foundation
import Testing
@testable import EluviumCatalog
@testable import EluviumCore

/// Pins the multi-file composition of the bundled starter pack: the source
/// chunks live in `ELVStarterPack+*.swift` and join in declaration order,
/// which is behavior (recognition tie-breaks, skip-report order). A chunk
/// edit that breaks JSON syntax or reorders sources must fail here by name,
/// not as a whole-pack decode error.
@Suite("Starter pack composition")
struct ELVStarterPackCompositionTests {
    /// The full roster in declaration order. Append new sources to their
    /// family chunk and to this pin in the same change.
    private static let orderedIds = [
        "shortlinks.travel", "gmaps.place", "gmaps.place.mapkit", "gmaps.share", "applemaps.place",
        "pokeapi.pokemon", "pokeapi.dex", "themeparks.entity", "wikipedia.article", "sixflags.attraction",
        "alltrails.trail", "komoot.route", "flighty.flight", "flighttracker.flight",
        "x.post", "imdb.title", "spotify.media", "applemusic.album", "applepodcasts.show",
        "xiaoyuzhou.podcast", "youtube.video", "douban.subject", "goodreads.book", "igdb.game",
        "ign.game", "threads.post", "fragrantica.perfume", "reddit.subreddit", "youtube.channel", "mastodon.profile",
        "camera.lens", "camera.lens.sigma",
        "booking.lodging", "airbnb.lodging", "vrbo.lodging", "agoda.lodging", "expedia.lodging",
        "hostelworld.lodging", "hotels.lodging", "tripadvisor.review", "yelp.review",
        "gyg.tour", "viator.tour", "klook.tour", "carrental.brands",
        "xiaohongshu.post", "shortlinks.media",
        "inat.observation", "inat.taxon", "inat.user", "inat.export", "merlin.species", "allaboutbirds.guide", "ebird.mydata",
        "weread.book", "weread.review", "weread.notes",
        "lists.oscars.bestpicture", "lists.tga.goty", "lists.ign.tens", "lists.applemusic.100best",
        "lists.michelin.la", "lists.liucixin.books", "lists.vangogh.paintings",
        "generic.feed", "generic.opengraph",
    ]

    @Test
    func `The composed pack decodes to the full roster in declaration order`() throws {
        let pack = try ELVPackLoader.load(embedded: ELVStarterPack.data)
        #expect(pack.pack.sources.map(\.id) == Self.orderedIds)
    }

    @Test
    func `Every family chunk parses as standalone JSON, so a syntax slip names its file`() {
        #expect(starterPackChunks.count == 11)
        for chunk in starterPackChunks {
            let wrapped = Data(("[" + chunk.json + "]").utf8)
            #expect((try? JSONSerialization.jsonObject(with: wrapped)) != nil, "\(chunk.name) is not standalone-valid JSON")
            #expect(!chunk.json.hasSuffix(","), "\(chunk.name) must not carry a trailing comma; the join supplies it")
        }
    }

    @Test
    func `The chunk table drives both the pack and the family roster`() {
        // Every family the CLI offers is a table family, and vice versa.
        #expect(Set(starterPackChunks.map(\.family)) == Set(ELVCatalogFamilies.known))
        // The union of the families is exactly the composed roster: no source
        // is unreachable from --families, none is offered that the pack lacks.
        let familyIds = ELVCatalogFamilies.ids(forFamilies: ELVCatalogFamilies.known)
        #expect(Set(familyIds) == Set(Self.orderedIds))
        #expect(familyIds.count == Self.orderedIds.count)
        // Within a family, ids keep declaration order (table order).
        for family in ELVCatalogFamilies.known {
            let ids = ELVCatalogFamilies.families[family] ?? []
            #expect(ids == Self.orderedIds.filter { ids.contains($0) }, "\(family)")
        }
    }

    @Test
    func `Backslash line continuations were consumed at compile time, not shipped as bytes`() {
        // A surviving continuation would leave a newline mid-URL /
        // mid-pattern at these known junction points. (A blanket
        // no-backslash-newline check is wrong: JSON content may end a line
        // with an ESCAPED backslash, which keeps its newline by design.)
        #expect(ELVStarterPack.json.contains("https://query.wikidata.org/sparql?format=json&query=SELECT%20%3FfilmLabel"))
        #expect(ELVStarterPack.json.contains("(?s:.*?)href="))
    }

    @Test
    func `The pack version and prologue survived the split`() {
        #expect(ELVStarterPack.json.contains("\"packVersion\": \"2026.10.12-starter.1\""))
        #expect(ELVStarterPack.json.hasPrefix("{\n  \"schemaVersion\": 1"))
    }

    @Test
    func `The text form decodes from the one stored copy of the bytes`() {
        // `data` is the stored copy; `json` is computed from it, so the two
        // can never disagree.
        #expect(Data(ELVStarterPack.json.utf8) == ELVStarterPack.data)
    }
}
