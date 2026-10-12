import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The media-roster block added 2026-08-23 (Spotify, Apple Music/Podcasts,
/// 小宇宙, YouTube, Douban, Goodreads, IGDB, IGN, Threads): recognition
/// across every URL shape, hostile lookalikes, URL-only extraction for the
/// slug sources, and the Spotify/Douban kind-inference tables.
@Suite("Starter pack media sources")
struct ELVStarterMediaSourcesTests {
    private func loaded() throws -> ELVLoadedPack {
        try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
    }

    /// Recognizes `url` in the loaded registry and assembles the URL-only
    /// record (empty document): exactly what a paste yields offline.
    private func assemble(_ url: String) throws -> ELVRecord {
        let pack = try loaded()
        let target = try #require(URL(string: url))
        let recognition = try #require(pack.registry.recognize(target), "\(url) did not recognize")
        let source = try #require(pack.source(withId: recognition.sourceId))
        return ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: target, params: recognition.params, document: ELVDocument()))
    }

    // MARK: - Recognition

    @Test
    func `Every media provider URL recognizes to its source across all path shapes`() throws {
        let cases: [(url: String, sourceId: String)] = [
            ("https://open.spotify.com/album/6dVIqQ8qmQ5GBnJ9shOYGE", "spotify.media"),
            ("https://open.spotify.com/track/2EuMREhmnIPQFaqXUH5yPu", "spotify.media"),
            ("https://open.spotify.com/show/1X01hX2JSHLZ0EhdqyskFD", "spotify.media"),
            ("https://music.apple.com/us/album/ok-computer/1097861387", "applemusic.album"),
            ("https://music.apple.com/us/album/%E9%BB%91%E5%A4%A2/158796449", "applemusic.album"),
            ("https://podcasts.apple.com/us/podcast/the-daily/id1200361736", "applepodcasts.show"),
            ("https://www.xiaoyuzhoufm.com/podcast/67f5f585d5e59b38db56240a", "xiaoyuzhou.podcast"),
            ("https://www.youtube.com/watch?v=cQcE4_7-X78", "youtube.video"),
            ("https://youtu.be/dQw4w9WgXcQ", "youtube.video"),
            ("https://music.douban.com/subject/1394653/", "douban.subject"),
            ("https://movie.douban.com/subject/1292226/", "douban.subject"),
            ("https://book.douban.com/subject/6518605/", "douban.subject"),
            ("https://www.douban.com/game/26362172/", "douban.subject"),
            ("https://m.douban.com/movie/subject/1292226/", "douban.subject"),
            ("https://m.douban.com/book/subject/24257486/", "douban.subject"),
            ("https://m.douban.com/game/subject/26362172/", "douban.subject"),
            ("https://www.goodreads.com/book/show/49552.The_Stranger", "goodreads.book"),
            ("https://www.igdb.com/games/outer-wilds", "igdb.game"),
            ("https://www.ign.com/games/outer-wilds", "ign.game"),
            ("https://www.threads.com/@zuck/post/DIFAsupTS7Z", "threads.post"),
            ("https://www.threads.net/@zuck/post/C-srcchPpp7", "threads.post"),
        ]
        let registry = try loaded().registry
        for (url, sourceId) in cases {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target)?.sourceId == sourceId, "\(url)")
        }
    }

    @Test
    func `Hostile lookalikes and userinfo spoofs never match any media source`() throws {
        let registry = try loaded().registry
        for url in [
            "https://open.spotify.evil.com/album/6dVIqQ8qmQ5GBnJ9shOYGE",
            "https://douban.com.evil.io/subject/1394653/",
            "https://youtu.be.evil.dev/dQw4w9WgXcQ",
            "https://threads.net.evil.com/@zuck/post/DIFAsupTS7Z",
            "https://evil.com@goodreads.com.attacker.io/book/show/49552.The_Stranger",
            "https://my-igdb.com/games/outer-wilds",
        ] {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target) == nil, "\(url)")
        }
    }

    @Test
    func `Non-media paths on media hosts fall through instead of matching`() throws {
        let registry = try loaded().registry
        // douban people pages match neither path pattern; a Goodreads author
        // page is not /book/show; a Threads profile has no post code.
        for url in [
            "https://www.douban.com/people/12345/",
            "https://www.goodreads.com/author/show/7387840",
            "https://www.threads.com/@zuck",
        ] {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target) == nil, "\(url)")
        }
    }

    // MARK: - URL-only extraction

    @Test
    func `IGDB parses URL-only: slug title, id, and identity without a fetch`() throws {
        let record = try assemble("https://www.igdb.com/games/the-legend-of-zelda-breath-of-the-wild")
        #expect(record.kind == "game")
        #expect(record.externalId == "the-legend-of-zelda-breath-of-the-wild")
        #expect(record.fields["title"] == .text("The Legend Of Zelda Breath Of The Wild"))
        #expect(record.identities.contains { $0.namespace == "igdb.game" })
    }

    @Test
    func `Threads lifts the handle and post code from the URL alone`() throws {
        let record = try assemble("https://www.threads.com/@zuck/post/DIFAsupTS7Z")
        #expect(record.kind == "post")
        #expect(record.externalId == "DIFAsupTS7Z")
        #expect(record.fields["handle"] == .text("zuck"))
    }

    // MARK: - Kind inference

    @Test
    func `Spotify kinds come from the path segment via the category table`() throws {
        #expect(try assemble("https://open.spotify.com/album/6dVIqQ8qmQ5GBnJ9shOYGE").kind == "album")
        #expect(try assemble("https://open.spotify.com/track/2EuMREhmnIPQFaqXUH5yPu").kind == "song")
        #expect(try assemble("https://open.spotify.com/show/1X01hX2JSHLZ0EhdqyskFD").kind == "podcast")
    }

    @Test
    func `Douban kinds come from the subdomain, and the game path from the category table`() throws {
        #expect(try assemble("https://music.douban.com/subject/1394653/").kind == "album")
        #expect(try assemble("https://movie.douban.com/subject/1292226/").kind == "movie")
        #expect(try assemble("https://book.douban.com/subject/6518605/").kind == "book")
        #expect(try assemble("https://www.douban.com/game/26362172/").kind == "game")
        // Every shape shares one identity namespace, so the same subject
        // pasted twice dedups regardless of subdomain.
        let record = try assemble("https://music.douban.com/subject/1394653/")
        #expect(record.externalId == "1394653")
        #expect(record.identities.contains { $0.namespace == "douban.subject" && $0.value == "1394653" })
    }

    @Test
    func `Douban m-dot shapes infer kinds from the path, and the game paste shape captures the numeric id`() throws {
        // The mobile site's share sheet produces these; they are also the
        // post-redirect context URLs of the desktop shapes, so the same
        // category candidates rescue inference after canonicalization.
        #expect(try assemble("https://m.douban.com/music/subject/1394653/").kind == "album")
        #expect(try assemble("https://m.douban.com/movie/subject/1292226/").kind == "movie")
        #expect(try assemble("https://m.douban.com/book/subject/24257486/").kind == "book")
        let game = try assemble("https://m.douban.com/game/subject/26362172/")
        #expect(game.kind == "game")
        // Pattern order matters: /game/subject/:id must win over /game/:id,
        // which would capture "subject" as the id.
        #expect(game.externalId == "26362172")
        #expect(game.identities.contains { $0.namespace == "douban.subject" && $0.value == "26362172" })
    }

    @Test
    func `The douban fetch plan branches by host: movie reroutes to the mirror, the rest fetch directly`() throws {
        let source = try #require(loaded().source(withId: "douban.subject"))
        let steps = try #require(source.fetch?.resolvedSteps)
        #expect(steps.count == 3)
        let movie = try #require(steps.first?.when)
        #expect(try movie.urlPermits(#require(URL(string: "https://movie.douban.com/subject/1292226/"))))
        #expect(try !movie.urlPermits(#require(URL(string: "https://music.douban.com/subject/1394653/"))))
        #expect(steps.first?.url == "https://m.douban.com/movie/subject/{param.id}/")
        let direct = try #require(steps.dropFirst().first?.when)
        #expect(try direct.urlPermits(#require(URL(string: "https://www.douban.com/game/26362172/"))))
        #expect(try !direct.urlPermits(#require(URL(string: "https://movie.douban.com/subject/1292226/"))))
        // Pasted m-dot URLs fetch directly (the mirror serves OG to the
        // mobile persona); without this the plan would have no runnable step.
        #expect(try direct.urlPermits(#require(URL(string: "https://m.douban.com/game/subject/26362172/"))))
    }

    @Test
    func `Fragrantica reads its schema.org microdata now that the JSON-LD block is gone`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "fragrantica.perfume"))
        let url = try #require(URL(string: "https://www.fragrantica.com/perfume/Christian-Dior/Sauvage-31861.html"))
        let html = """
        <html><head><meta property="og:title" content="Sauvage Dior cologne - a fragrance for men 2015"></head><body>
        <div itemtype="http://schema.org/Product" itemscope><h1 itemprop="name" class="text-2xl"> Sauvage Dior <span class="text-lg">for men</span></h1>
        <p itemprop="aggregateRating" itemtype="http://schema.org/AggregateRating" itemscope>Perfume rating&nbsp;<span itemprop="ratingValue" class="font-semibold">3.85</span>\
        &nbsp;out of&nbsp;<span itemprop="bestRating">5</span>&nbsp;with&nbsp;<span itemprop="ratingCount" content="34515" class="font-semibold">34,515</span>&nbsp;votes</p></div>
        </body></html>
        """
        let params = ["brand": "Christian-Dior", "slug": "Sauvage-31861.html"]
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: params, document: ELVDocument(html: html)))
        #expect(record.fields["title"] == .text("Sauvage Dior"))
        #expect(record.fields["rating"] == .rating(value: 3.85, scale: 0 ... 5))
        #expect(record.fields["ratingCount"] == .number(34515))
        // Without the h1, the og:title fallback drops its descriptor tail.
        let ogOnly = ELVAssembler.assemble(source: source, context: ELVExtractionContext(
            url: url, params: params, document: ELVDocument(html: #"<html><head><meta property="og:title" content="Sauvage Dior cologne - a fragrance for men 2015"></head></html>"#)
        ))
        #expect(ogOnly.fields["title"] == .text("Sauvage Dior"))
    }

    // MARK: - Fragments

    @Test
    func `Media sources resolve the shared fragments: the http ladder fills fetch, ogCore appends fields`() throws {
        let pack = try loaded()
        for id in ["youtube.video", "ign.game", "threads.post", "imdb.title"] {
            let source = try #require(pack.source(withId: id), "\(id)")
            #expect(source.fetch?.resolvedSteps.map(\.ua) == ["mobileSafari", "crawler"], "\(id)")
            #expect(source.fields.contains { $0.name == "title" }, "\(id)")
            #expect(source.fields.contains { $0.name == "summary" }, "\(id)")
        }
        // Goodreads declares its own ladder (the fragment fills fetch only
        // when a source has none): the same two http rungs, then a WebKit
        // render past AWS WAF's empty 202 challenge. Fields still ride ogCore.
        let goodreads = try #require(pack.source(withId: "goodreads.book"))
        #expect(goodreads.fetch?.resolvedSteps.map(\.mode) == ["http", "http", "dom"])
        #expect(goodreads.fetch?.resolvedSteps.map(\.ua) == ["mobileSafari", "crawler", "mobileSafari"])
        #expect(goodreads.fields.contains { $0.name == "summary" })
        // douban keeps its own branching plan; only its fields ride ogCore.
        let douban = try #require(pack.source(withId: "douban.subject"))
        #expect(douban.fetch?.resolvedSteps.count == 3)
        #expect(douban.fields.contains { $0.name == "summary" })
    }

    @Test
    func `The audio-bearing media sources scope their enrichment surfaces to their own steps`() throws {
        // The schemaMinor-1 migration: enrichment composites bind lookup /
        // embed fields and track collections to the step that fetches that
        // document, so an enrichment page can never clobber page fields it
        // does not declare; ogCore still appends the source-level ladders.
        let pack = try loaded()
        let spotify = try #require(pack.source(withId: "spotify.media"))
        #expect(spotify.fetch?.resolvedSteps.count == 4)
        #expect(spotify.fetch?.resolvedSteps.dropFirst(2).allSatisfy { $0.jsonIsland == "__NEXT_DATA__" } == true)
        #expect(spotify.fetch?.resolvedSteps[2].when?.pathRegex == "^/track/")
        #expect(spotify.fetch?.resolvedSteps[2].fields?.contains { $0.name == "audio" } == true)
        #expect(spotify.fetch?.resolvedSteps[3].when?.pathRegex == "^/album/")
        #expect(spotify.fetch?.resolvedSteps[3].collections?.contains { $0.name == "tracks" && $0.kind == "song" } == true)
        #expect(spotify.collections.isEmpty)

        let album = try #require(pack.source(withId: "applemusic.album"))
        #expect(album.fetch?.resolvedSteps.map(\.mode) == ["http", "http", "json"])
        #expect(album.fetch?.resolvedSteps.last?.url == "https://itunes.apple.com/lookup?id={param.id}&entity=song")
        #expect(album.fetch?.resolvedSteps.last?.collections?.contains { $0.name == "tracks" && $0.kind == "song" } == true)
        #expect(album.collections.isEmpty)

        let podcasts = try #require(pack.source(withId: "applepodcasts.show"))
        #expect(podcasts.fetch?.resolvedSteps.last?.url == "https://itunes.apple.com/lookup?id={native:text.digits@1(param.id)}")
        #expect(podcasts.fetch?.resolvedSteps.last?.fields?.contains { $0.name == "feedUrl" } == true)
        #expect(!podcasts.fields.contains { $0.name == "feedUrl" })

        let xiaoyuzhou = try #require(pack.source(withId: "xiaoyuzhou.podcast"))
        #expect(xiaoyuzhou.fetch?.resolvedSteps.allSatisfy { $0.jsonIsland == "__NEXT_DATA__" } == true)
        #expect(xiaoyuzhou.collections.contains { $0.name == "episodes" && $0.kind == "episode" })
        // All four still ride ogCore's appended field ladders.
        for id in ["spotify.media", "applemusic.album", "applepodcasts.show", "xiaoyuzhou.podcast"] {
            let source = try #require(pack.source(withId: id))
            #expect(source.fields.contains { $0.name == "title" }, "\(id)")
            #expect(source.fields.contains { $0.name == "summary" }, "\(id)")
        }
    }

    @Test
    func `IMDb resolves a relative og:image against the page URL`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "imdb.title"))
        let url = try #require(URL(string: "https://www.imdb.com/title/tt0076759/"))
        let document = ELVDocument(metas: ["og:image": "/images/M/poster.jpg"])
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: ["id": "tt0076759"], document: document))
        let expected = try #require(URL(string: "https://www.imdb.com/images/M/poster.jpg"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: expected, kind: ELVMediaRef.image)))
    }

    // MARK: - Feed-backed channels (2026-08-29)

    @Test
    func `The feed-backed trio maps the envelope's nextPage pointer the way generic.feed does`() throws {
        let pack = try loaded()
        let floor = try #require(pack.source(withId: "generic.feed"))
        let floorNextPage = try #require(floor.fields.first { $0.name == "nextPage" })
        for id in ["reddit.subreddit", "youtube.channel", "mastodon.profile"] {
            let source = try #require(pack.source(withId: id))
            let nextPage = try #require(source.fields.first { $0.name == "nextPage" }, "\(id)")
            #expect(nextPage.candidates == floorNextPage.candidates, "\(id)")
        }
    }

    @Test
    func `Reddit, YouTube channels, and Mastodon recognize and route to their feeds`() throws {
        let pack = try loaded()

        // Reddit: the subreddit page routes to its .rss via a URL template;
        // post URLs stay off the source (they fall through to the floor).
        let subreddit = try #require(URL(string: "https://www.reddit.com/r/swift/"))
        let redditMatch = try #require(pack.registry.recognize(subreddit))
        #expect(redditMatch.sourceId == "reddit.subreddit")
        #expect(redditMatch.params["name"] == "swift")
        let reddit = try #require(pack.source(withId: "reddit.subreddit"))
        #expect(reddit.fetch?.resolvedSteps.first?.url == "https://www.reddit.com/r/{param.name}/.rss")
        let post = try #require(URL(string: "https://www.reddit.com/r/swift/comments/abc123/some_post/"))
        #expect(pack.registry.recognize(post)?.sourceId != "reddit.subreddit")

        // YouTube: the /channel/:id form templates the videos feed; the
        // @handle form fetches the page and relies on feed autodiscovery.
        // Watch URLs keep recognizing as youtube.video.
        let channel = try #require(URL(string: "https://www.youtube.com/channel/UCE_M8A5yxnLfW0KghEeajjw"))
        #expect(pack.registry.recognize(channel)?.sourceId == "youtube.channel")
        let handle = try #require(URL(string: "https://www.youtube.com/@apple"))
        let handleMatch = try #require(pack.registry.recognize(handle))
        #expect(handleMatch.sourceId == "youtube.channel")
        #expect(handleMatch.params["handle"] == "apple")
        let watch = try #require(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(pack.registry.recognize(watch)?.sourceId == "youtube.video")

        // Mastodon: profile pages on the flagship instances; the feed comes
        // from the page's own rel=alternate autodiscovery.
        let profile = try #require(URL(string: "https://mastodon.social/@Mastodon"))
        let mastodonMatch = try #require(pack.registry.recognize(profile))
        #expect(mastodonMatch.sourceId == "mastodon.profile")
        #expect(mastodonMatch.params["user"] == "Mastodon")
        let mastodon = try #require(pack.source(withId: "mastodon.profile"))
        #expect(mastodon.fetch?.resolvedSteps.first?.url == nil)

        // All three are feed sources meeting the example floor, per pack policy.
        for id in ["reddit.subreddit", "youtube.channel", "mastodon.profile"] {
            let source = try #require(pack.source(withId: id))
            #expect(source.kind == "feed", "\(id)")
            #expect(source.examples.count >= 2, "\(id)")
        }
    }

    // MARK: - Identity (2026-10-10 audit)

    private func record(_ id: String, url: String, params: [String: String] = [:], json: String) throws -> ELVRecord {
        let source = try #require(try loaded().source(withId: id))
        let node = try #require(ELVRawJSON.parse(Data(json.utf8)))
        let target = try #require(URL(string: url))
        return ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: target, params: params, document: ELVDocument(json: node)))
    }

    @Test
    func `YouTube videos carry their identity on every URL shape, not only ?v=`() throws {
        for url in ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ", "https://www.youtube.com/shorts/dQw4w9WgXcQ"] {
            let video = try assemble(url)
            #expect(video.externalId == "dQw4w9WgXcQ", "\(url)")
            #expect(video.identities == [ELVIdentity(namespace: "youtube.video", value: "dQw4w9WgXcQ", origin: .declared)], "\(url)")
        }
    }

    @Test
    func `Xiaoyuzhou infers podcast or episode from the path, each in its own namespace`() throws {
        let show = try assemble("https://www.xiaoyuzhoufm.com/podcast/5e4ee557418a84a0466737b7")
        #expect(show.kind == "podcast")
        #expect(show.identities == [ELVIdentity(namespace: "xiaoyuzhou.podcast", value: "5e4ee557418a84a0466737b7", origin: .declared)])
        let episode = try assemble("https://www.xiaoyuzhoufm.com/episode/60c5f47cc2ec9bd456ec633b")
        #expect(episode.kind == "episode")
        #expect(episode.identities == [ELVIdentity(namespace: "xiaoyuzhou.episode", value: "60c5f47cc2ec9bd456ec633b", origin: .declared)])

        // The show page's episode children are the same kind and namespace a
        // pasted episode gets, under the same record key.
        let page = try record("xiaoyuzhou.podcast", url: "https://www.xiaoyuzhoufm.com/podcast/5e4ee557418a84a0466737b7", params: ["id": "5e4ee557418a84a0466737b7"], json: #"""
        {"props": {"pageProps": {"podcast": {"author": "忽左忽右", "episodes": [{"eid": "60c5f47cc2ec9bd456ec633b", "title": "S2E1"}]}}}}
        """#)
        let child = try #require(page.collections["episodes"]?.first)
        #expect(child.kind == "episode")
        #expect(child.externalId == episode.externalId)
        #expect(child.identities == episode.identities)
    }

    @Test
    func `Track children declare the namespace of the track they are`() throws {
        let pack = try loaded()
        let spotify = try #require(pack.source(withId: "spotify.media"))
        let embed = try #require(spotify.fetch?.resolvedSteps.last?.collections)
        let embedJSON = try #require(ELVRawJSON.parse(Data(#"""
        {"props": {"pageProps": {"state": {"data": {"entity": {"trackList": [
          {"uri": "spotify:track:2EuMREhmnIPQFaqXUH5yPu", "title": "Paranoid Android", "subtitle": "Radiohead"}]}}}}}}
        """#.utf8)))
        let albumURL = try #require(URL(string: "https://open.spotify.com/album/6dVIqQ8qmQ5GBnJ9shOYGE"))
        let tracks = try #require(ELVAssembler.assembleCollections(embed, source: spotify, context: ELVExtractionContext(url: albumURL, document: ELVDocument(json: embedJSON)))["tracks"])
        #expect(tracks.first?.identities == [ELVIdentity(namespace: "spotify", value: "2EuMREhmnIPQFaqXUH5yPu", origin: .declared)])
        // The pasted track carries the same identity.
        #expect(try assemble("https://open.spotify.com/track/2EuMREhmnIPQFaqXUH5yPu").identities == tracks.first?.identities)

        let album = try #require(pack.source(withId: "applemusic.album"))
        let lookup = try #require(album.fetch?.resolvedSteps.last?.collections)
        let lookupJSON = try #require(ELVRawJSON.parse(Data(#"""
        {"resultCount": 2, "results": [{"wrapperType": "collection", "collectionId": 1097861387},
          {"wrapperType": "track", "trackId": 1097862062, "trackName": "Airbag", "trackNumber": 1}]}
        """#.utf8)))
        let albumPage = try #require(URL(string: "https://music.apple.com/us/album/ok-computer/1097861387"))
        let songs = try #require(ELVAssembler.assembleCollections(lookup, source: album, context: ELVExtractionContext(url: albumPage, document: ELVDocument(json: lookupJSON)))["tracks"])
        // The lookup's own album row yields no child.
        #expect(songs.count == 1)
        #expect(songs.first?.identities == [ELVIdentity(namespace: "applemusic.song", value: "1097862062", origin: .declared)])
    }

    @Test
    func `Apple Podcasts declares the built-in itunes.podcast namespace`() throws {
        let show = try assemble("https://podcasts.apple.com/us/podcast/the-daily/id1200361736")
        #expect(show.identities == [ELVIdentity(namespace: "itunes.podcast", value: "1200361736", origin: .declared)])
        #expect(ELVIdentityNamespaces.isStrong("itunes.podcast"))
    }

    @Test
    func `Douban movie shapes add the built-in douban.film, and the movie host fills category`() throws {
        for url in ["https://movie.douban.com/subject/1292226/", "https://m.douban.com/movie/subject/1292226/"] {
            let movie = try assemble(url)
            #expect(movie.identities.contains(ELVIdentity(namespace: "douban.film", value: "1292226", origin: .declared)), "\(url)")
            #expect(movie.identities.contains(ELVIdentity(namespace: "douban.subject", value: "1292226", origin: .declared)), "\(url)")
            #expect(movie.fields["category"] == .text("movie"), "\(url)")
        }
        for url in ["https://music.douban.com/subject/1394653/", "https://book.douban.com/subject/6518605/", "https://www.douban.com/game/26362172/"] {
            let other = try assemble(url)
            #expect(!other.identities.contains { $0.namespace == "douban.film" }, "\(url)")
            #expect(other.fields["category"] != nil, "\(url)")
        }
    }

    @Test
    func `The feed trio keys on the channel id, the lowercased subreddit, and handle@instance`() throws {
        let reddit = try assemble("https://www.reddit.com/r/iOSProgramming/")
        #expect(reddit.externalId == "iosprogramming")
        #expect(reddit.identities == [ELVIdentity(namespace: "reddit.subreddit", value: "iosprogramming", origin: .declared)])

        // Mastodon's context URL is the autodiscovered feed after the fetch.
        for url in ["https://mastodon.social/@Gargron", "https://mastodon.social/@Gargron.rss"] {
            let profile = try record("mastodon.profile", url: url, params: ["user": "Gargron"], json: #"{"title": "Eugen Rochko", "items": []}"#)
            #expect(profile.externalId == "gargron@mastodon.social", "\(url)")
            #expect(profile.identities == [ELVIdentity(namespace: "mastodon.account", value: "gargron@mastodon.social", origin: .declared)], "\(url)")
        }

        // A /channel/ paste reads the id from its path; an @handle paste from
        // the feed URL autodiscovery lands on.
        let feed = #"""
        {"title": "NASA", "author": "NASA", "link": "https://www.youtube.com/channel/UCLA_DiR1FfKNvjuUpBHmylQ",
         "items": [{"externalId": "yt:video:mHXELsEResE", "title": "Launch", "link": "https://www.youtube.com/watch?v=mHXELsEResE"}]}
        """#
        let byHandle = try record("youtube.channel", url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCLA_DiR1FfKNvjuUpBHmylQ", params: ["handle": "NASA"], json: feed)
        let byId = try record("youtube.channel", url: "https://www.youtube.com/channel/UCLA_DiR1FfKNvjuUpBHmylQ", params: ["id": "UCLA_DiR1FfKNvjuUpBHmylQ"], json: feed)
        for channel in [byHandle, byId] {
            #expect(channel.externalId == "UCLA_DiR1FfKNvjuUpBHmylQ")
            #expect(channel.identities == [ELVIdentity(namespace: "youtube.channel", value: "UCLA_DiR1FfKNvjuUpBHmylQ", origin: .declared)])
        }
        // Items shed the feed's `yt:video:` prefix and link to the video.
        let item = try #require(byHandle.collections["items"]?.first)
        #expect(item.externalId == "mHXELsEResE")
        #expect(item.identities == [ELVIdentity(namespace: "youtube.video", value: "mHXELsEResE", origin: .declared)])
        #expect(try assemble("https://www.youtube.com/watch?v=mHXELsEResE").identities == item.identities)
    }

    @Test
    func `YouTube channels read the avatar and description from a channel-page step the feed steps follow`() throws {
        // The channel feed carries neither; an enrichment step over the
        // channel page does, scoped so it can never clobber feed fields.
        // Its title and id are the feed outage fallback: the feed steps'
        // win where they produce.
        let source = try #require(try loaded().source(withId: "youtube.channel"))
        let steps = try #require(source.fetch?.resolvedSteps)
        #expect(steps.map(\.mode) == ["http", "feed", "feed"])
        #expect(steps[0].when == nil)
        #expect(steps[0].fields?.map(\.name) == ["title", "externalId", "summary", "image"])
        #expect(!source.fields.contains { $0.name == "image" || $0.name == "summary" })
        // The feed steps keep their path gates, so both run after the page.
        #expect(steps[1].when?.pathRegex == "^/channel/")
        #expect(steps[2].when?.pathRegex == "^/@")
        // Items stay source-level: the final context is a feed step's.
        #expect(source.collections.map(\.name) == ["items"])
    }

    @Test
    func `A channel page alone leaves a titled, keyed record when the feed is down`() throws {
        // youtube.com's feed endpoint answered 404 for every channel on
        // 2026-10-12; the page step's og:title and `identifier` meta keep
        // the record titled and keyed, items honestly unmet.
        let source = try #require(try loaded().source(withId: "youtube.channel"))
        let fields = try #require(source.fetch?.resolvedSteps.first?.fields)
        let url = try #require(URL(string: "https://www.youtube.com/channel/UCE_M8A5yxnLfW0KghEeajjw"))
        let html = #"<html><head><meta property="og:title" content="Apple"><meta itemprop="identifier" content="UCE_M8A5yxnLfW0KghEeajjw">"#
            + #"<meta property="og:description" content="Apple on YouTube"></head></html>"#
        let page = ELVExtractor.extract(fields: fields, context: ELVExtractionContext(url: url, params: ["id": "UCE_M8A5yxnLfW0KghEeajjw"], document: ELVDocument(html: html)))
        #expect(page.values["title"] == .text("Apple"))
        #expect(page.values["externalId"] == .text("UCE_M8A5yxnLfW0KghEeajjw"))
        #expect(page.values["summary"] == .text("Apple on YouTube"))
        // An identifier that is not a channel id leaves the field to the feed steps.
        let odd = ELVExtractor.extract(fields: fields, context: ELVExtractionContext(url: url, params: [:], document: ELVDocument(html: #"<meta itemprop="identifier" content="not-a-channel">"#)))
        #expect(odd.values["externalId"] == nil)
    }

    @Test
    func `IMDb and Fragrantica ride ogCore, their own ladders still leading`() throws {
        let pack = try loaded()
        let imdb = try #require(pack.source(withId: "imdb.title"))
        #expect(imdb.use == ["httpEscalate", "ogCore"])
        let imdbTitle = try #require(imdb.fields.first { $0.name == "title" })
        #expect(imdbTitle.candidates.first?.from == .jsonld("Movie.name"))
        #expect(imdb.fields.contains { $0.name == "siteName" })

        let fragrantica = try #require(pack.source(withId: "fragrantica.perfume"))
        #expect(fragrantica.use == ["ogCore"])
        let url = try #require(URL(string: "https://www.fragrantica.com/perfume/Christian-Dior/Sauvage-31861.html"))
        let params = ["brand": "Christian-Dior", "slug": "Sauvage-31861.html"]
        let html = #"<html><head><meta name="description" content="Sauvage by Dior"><meta property="og:image" content="/i/31861.jpg"></head></html>"#
        let record = ELVAssembler.assemble(source: fragrantica, context: ELVExtractionContext(url: url, params: params, document: ELVDocument(html: html)))
        // The slug still closes the title ladder before any fragment rung.
        #expect(record.fields["title"] == .text("Sauvage"))
        #expect(record.fields["summary"] == .text("Sauvage by Dior"))
        let image = try #require(URL(string: "https://www.fragrantica.com/i/31861.jpg"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: image, kind: ELVMediaRef.image)))
    }
}
