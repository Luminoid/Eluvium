import EluviumCore
import Foundation
import Synchronization
import Testing
@testable import EluviumNet

/// A fixture-replaying fetcher: the whole pipeline runs offline against
/// canned bodies keyed by host. Records every requested URL so tests can
/// assert fetch counts (the floor pass must fetch once, not once per floor).
private final class StubFetcher: ELVFetching, @unchecked Sendable {
    private let responses: [String: ELVFetchResponse]
    private let failures: [String: ELVFetchFailure]
    private let requestLog = Mutex<[String]>([])
    private let budgetLog = Mutex<[String: Int]>([:])

    init(responses: [String: ELVFetchResponse], failures: [String: ELVFetchFailure] = [:]) {
        self.responses = responses
        self.failures = failures
    }

    var requestedURLs: [String] { requestLog.withLock { $0 } }
    /// The last byte budget each host was fetched with (the maxBytes plumb).
    var budgets: [String: Int] { budgetLog.withLock { $0 } }

    func fetch(_ url: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget: ELVFetchBudget) async throws -> ELVFetchResponse {
        requestLog.withLock { $0.append(url.absoluteString) }
        budgetLog.withLock { $0[url.host ?? ""] = budget.maxBytes }
        let host = url.host ?? ""
        if let failure = failures[host] { throw failure }
        guard let response = responses[host] else { throw ELVFetchFailure.httpError(status: 404) }
        return response
    }
}

@Suite("Pipeline end to end")
struct ELVPipelineTests {
    private func loadPack(_ json: String, dom: Bool = false) throws -> ELVLoadedPack {
        var modes: Set = ["http", "json", "archive", "feed", "composite"]
        if dom { modes.insert("dom") }
        return try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: modes, binaryVersion: "0.1"))
    }

    private func response(host: String, url: String, html: String, status: Int = 200) throws -> ELVFetchResponse {
        try ELVFetchResponse(finalURL: #require(URL(string: url)), status: status, data: Data(html.utf8), bodyText: html, truncated: false)
    }

    private let alltrailsPack = """
    {
      "schemaVersion": 1, "packVersion": "test",
      "sources": [{
        "id": "alltrails.trail",
        "kind": "trail",
        "match": {"host": ["alltrails.com"], "path": "/trail/:country/:region/:slug", "priority": 100},
        "canonicalize": {"strip": ["utm_*", "sh"]},
        "fetch": {"mode": "http", "ua": "mobileSafari"},
        "fields": [
          {"name": "externalId", "candidates": [{"from": {"urlParam": "slug"}}]},
          {"name": "title", "candidates": [
            {"from": {"jsonld": "TouristAttraction.name"}},
            {"from": {"meta": "og:title"}, "pipe": [{"stripSuffix": " | AllTrails"}]}
          ]},
          {"name": "rating", "candidates": [{"from": {"jsonld": "TouristAttraction.aggregateRating.ratingValue"}, "as": "rating"}]},
          {"name": "image", "candidates": [{"from": {"meta": "og:image"}, "pipe": ["resolveURL"], "as": "image"}]}
        ],
        "identities": [{"ns": "alltrails.trail", "from": {"urlParam": "slug"}}]
      }]
    }
    """

    private let alltrailsHTML = """
    <html><head>
      <title>Hidden Falls Trail | AllTrails</title>
      <meta property="og:title" content="Hidden Falls Trail | AllTrails" />
      <meta property="og:image" content="/img/hidden-falls.jpg" />
      <script type="application/ld+json">
        {"@type": "TouristAttraction", "name": "Hidden Falls Trail",
         "aggregateRating": {"ratingValue": 4.7, "reviewCount": 1203}}
      </script>
    </head><body><h1>Hidden Falls Trail</h1></body></html>
    """

    @Test
    func `An AllTrails URL recognizes, fetches, extracts, and assembles a record`() async throws {
        let pack = try loadPack(alltrailsPack)
        let stub = try StubFetcher(responses: [
            "www.alltrails.com": response(host: "www.alltrails.com", url: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail", html: alltrailsHTML),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let url = try #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail?utm_source=share&sh=abc"))

        let stages = Mutex<[ELVPipelineStage]>([])
        let result = await pipeline.run(url: url) { stage in stages.withLock { $0.append(stage) } }.result

        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        let expectedImage = try #require(URL(string: "https://www.alltrails.com/img/hidden-falls.jpg"))
        #expect(record.sourceId == "alltrails.trail")
        #expect(record.kind == "trail")
        #expect(record.externalId == "hidden-falls-trail")
        #expect(record.fields["title"] == .text("Hidden Falls Trail"))
        #expect(record.fields["rating"] == .rating(value: 4.7, scale: 0 ... 5))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: expectedImage, kind: ELVMediaRef.image)))
        #expect(record.identities == [ELVIdentity(namespace: "alltrails.trail", value: "hidden-falls-trail", origin: .declared)])
        #expect(stages.withLock { $0 } == [.recognize, .fetch, .extract, .assemble])
    }

    @Test
    func `A cancellation thrown by the transport reports the pipeline's cancellation marker`() async throws {
        // URLSession surfaces a mid-transfer task cancellation as
        // URLError(.cancelled); the fetcher rethrows it as
        // CancellationError, and the pipeline must report its marker — a
        // user action, never a transport failure.
        struct CancellingFetcher: ELVFetching {
            func fetch(_: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
                throw CancellationError()
            }
        }
        let pack = try loadPack(alltrailsPack)
        let pipeline = ELVPipeline(pack: pack, fetcher: CancellingFetcher())
        let url = try #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))

        let result = await pipeline.run(url: url) { _ in }.result

        guard case let .failed(failure, sourceId) = result else {
            Issue.record("Expected a failure, got \(result)")
            return
        }
        #expect(failure == .formatDrift("cancelled"))
        #expect(sourceId == "alltrails.trail")
    }

    @Test
    func `A jsonIsland step promotes embedded script JSON into fields and collections beside the HTML`() async throws {
        let pack = try loadPack("""
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "island.show",
            "kind": "podcast",
            "match": {"host": ["island.example"], "path": "/show/:id", "priority": 100},
            "fetch": {"mode": "http", "ua": "mobileSafari", "jsonIsland": "__NEXT_DATA__"},
            "fields": [
              {"name": "title", "candidates": [{"from": {"meta": "og:title"}}]},
              {"name": "author", "candidates": [{"from": {"json": "$.props.podcast.author"}}]}
            ],
            "collections": [{
              "name": "episodes", "from": {"json": "$.props.podcast.episodes[*]"}, "kind": "episode",
              "item": [
                {"name": "externalId", "candidates": [{"from": {"json": "$.eid"}}]},
                {"name": "title", "candidates": [{"from": {"json": "$.title"}}]},
                {"name": "audio", "candidates": [{"from": {"json": "$.url"}, "as": "audio"}]}
              ]
            }]
          }]
        }
        """)
        let html = """
        <html><head><meta property="og:title" content="Story FM" />
        <script id="__NEXT_DATA__" type="application/json">
        {"props": {"podcast": {"author": "寇爱哲", "episodes": [
          {"eid": "e1", "title": "One", "url": "https://media.example/e1.m4a"},
          {"eid": "e2", "title": "Two", "url": "https://media.example/e2.m4a"}
        ]}}}
        </script></head></html>
        """
        let stub = try StubFetcher(responses: [
            "island.example": response(host: "island.example", url: "https://island.example/show/s1", html: html),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let url = try #require(URL(string: "https://island.example/show/s1"))

        let result = await pipeline.run(url: url).result

        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        // The HTML document stays intact beside the promoted island.
        #expect(record.fields["title"] == .text("Story FM"))
        #expect(record.fields["author"] == .text("寇爱哲"))
        let episodes = try #require(record.collections["episodes"])
        let audioURL = try #require(URL(string: "https://media.example/e1.m4a"))
        #expect(episodes.count == 2)
        #expect(episodes.first?.externalId == "e1")
        #expect(episodes.first?.fields["audio"] == .media(ELVMediaRef(url: audioURL, kind: ELVMediaRef.audio)))
    }

    @Test
    func `A paginating feed surfaces its rel-next pointer as the nextPage field`() async throws {
        let pack = try loadPack("""
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "feed.paged",
            "kind": "feed",
            "match": {"host": ["paged.example"], "path": "/**", "priority": 100},
            "fetch": {"mode": "feed", "ua": "mobileSafari"},
            "fields": [
              {"name": "title", "candidates": [{"from": {"json": "$.title"}}]},
              {"name": "nextPage", "candidates": [{"from": {"json": "$.nextURL"}, "as": "url"}]}
            ],
            "collections": [{
              "name": "items", "from": {"json": "$.items[*]"}, "kind": "article",
              "item": [{"name": "title", "candidates": [{"from": {"json": "$.title"}}]}]
            }]
          }]
        }
        """)
        let feed = """
        <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Paged</title>
        <atom:link rel="next" href="https://paged.example/feed?page=2"/>
        <item><title>One</title><guid>g1</guid></item></channel></rss>
        """
        let stub = try StubFetcher(responses: [
            "paged.example": response(host: "paged.example", url: "https://paged.example/feed", html: feed),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let url = try #require(URL(string: "https://paged.example/feed"))

        let result = await pipeline.run(url: url).result

        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        let next = try #require(URL(string: "https://paged.example/feed?page=2"))
        #expect(record.fields["nextPage"] == .url(next))
        #expect(record.collections["items"]?.count == 1)
    }

    @Test
    func `runSeed starts a seed-only source without recognition, and unknown ids fail typed`() async throws {
        let pack = try loadPack("""
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "lists.test",
            "kind": "list",
            "seed": "https://sparql.example/query?format=json",
            "fetch": {"mode": "json", "ua": "mobileSafari"},
            "fields": [{"name": "title", "candidates": [{"from": {"const": "Winners"}}]}],
            "collections": [{
              "name": "entries", "from": {"json": "$.results.bindings[*]"}, "kind": "movie",
              "item": [
                {"name": "title", "candidates": [{"from": {"json": "$.filmLabel.value"}}]},
                {"name": "year", "candidates": [{"from": {"json": "$.year.value"}, "as": "int"}]}
              ]
            }]
          }]
        }
        """)
        let body = """
        {"results": {"bindings": [
          {"filmLabel": {"value": "Anora"}, "year": {"value": "2025"}},
          {"filmLabel": {"value": "Oppenheimer"}, "year": {"value": "2024"}}
        ]}}
        """
        let stub = try StubFetcher(responses: [
            "sparql.example": response(host: "sparql.example", url: "https://sparql.example/query?format=json", html: body),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)

        let result = await pipeline.runSeed(sourceId: "lists.test").result

        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.fields["title"] == .text("Winners"))
        #expect(record.collections["entries"]?.map { $0.fields["title"] } == [.text("Anora"), .text("Oppenheimer")])
        #expect(record.collections["entries"]?.first?.fields["year"] == .number(2025))

        guard case let .failed(failure, sourceId) = await pipeline.runSeed(sourceId: "lists.unknown").result else {
            Issue.record("Expected a typed failure for an unknown seed id")
            return
        }
        #expect(failure == .invalidURL)
        #expect(sourceId == "lists.unknown")
    }

    @Test
    func `A plain-http input upgrades to https at the front door`() async throws {
        // Share sheets paste http:// links (xhslink does); the egress policy
        // is https-only and ATS refuses http in-app, so the pipeline must
        // never let the scheme reach the transport.
        let pack = try loadPack(alltrailsPack)
        let stub = try StubFetcher(responses: [
            "www.alltrails.com": response(host: "www.alltrails.com", url: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail", html: alltrailsHTML),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let result = try await pipeline.run(url: #require(URL(string: "http://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))).result
        guard case .record = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(stub.requestedURLs.allSatisfy { $0.hasPrefix("https://") })
    }

    private let brancherPack = """
    {
      "schemaVersion": 1, "packVersion": "test",
      "sources": [{
        "id": "branch.subject",
        "kind": "thing",
        "match": {"host": ["douban.com"], "path": ["/subject/:id/**", "/game/:id/**"], "priority": 100},
        "fetch": {"mode": "composite", "steps": [
          {"mode": "http", "ua": "mobileSafari", "url": "https://m.douban.com/movie/subject/{param.id}/", "when": {"hostMatches": ["movie.douban.com"]}},
          {"mode": "http", "ua": "mobileSafari", "when": {"hostMatches": ["music.douban.com", "www.douban.com"]}},
          {"mode": "http", "ua": "crawler", "when": {"hostMatches": ["music.douban.com", "www.douban.com"], "missingAny": ["title"]}}
        ]},
        "fields": [
          {"name": "externalId", "candidates": [{"from": {"urlParam": "id"}}]},
          {"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}
        ]
      }]
    }
    """

    private func brancherHTML(_ title: String) -> String {
        #"<html><head><meta property="og:title" content="\#(title)" /></head><body></body></html>"#
    }

    @Test
    func `A URL-gated template step reroutes one host shape and never fetches the walled origin`() async throws {
        // The douban shape: movie pages serve a login interstitial, the
        // mobile mirror serves full OG. The first step is URL-gated to the
        // movie host and rewrites to the mirror; a pure URL gate runs from
        // the first step on.
        let pack = try loadPack(brancherPack)
        let stub = try StubFetcher(responses: [
            "m.douban.com": response(host: "m.douban.com", url: "https://m.douban.com/movie/subject/1292226/", html: brancherHTML("2001太空漫游")),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let result = try await pipeline.run(url: #require(URL(string: "https://movie.douban.com/subject/1292226/"))).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.externalId == "1292226")
        #expect(record.fields["title"] == .text("2001太空漫游"))
        #expect(stub.requestedURLs == ["https://m.douban.com/movie/subject/1292226/"])
    }

    @Test
    func `Steps gated to other hosts are skipped, and a satisfied response condition stops the ladder`() async throws {
        let pack = try loadPack(brancherPack)
        let stub = try StubFetcher(responses: [
            "music.douban.com": response(host: "music.douban.com", url: "https://music.douban.com/subject/1394653/", html: brancherHTML("OK Computer")),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let result = try await pipeline.run(url: #require(URL(string: "https://music.douban.com/subject/1394653/"))).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.fields["title"] == .text("OK Computer"))
        // The movie-only template step never fired, and the crawler retry's
        // missingAny condition was already met, so exactly one fetch left.
        #expect(stub.requestedURLs == ["https://music.douban.com/subject/1394653/"])
    }

    @Test
    func `The second path pattern matches and its params feed extraction`() async throws {
        let pack = try loadPack(brancherPack)
        let stub = try StubFetcher(responses: [
            "www.douban.com": response(host: "www.douban.com", url: "https://www.douban.com/game/26362172/", html: brancherHTML("星际拓荒 Outer Wilds")),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let result = try await pipeline.run(url: #require(URL(string: "https://www.douban.com/game/26362172/"))).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.externalId == "26362172")
        #expect(record.fields["title"] == .text("星际拓荒 Outer Wilds"))
    }

    @Test
    func `An unrecognized URL returns .unrecognized without fetching`() async throws {
        let pack = try loadPack(alltrailsPack)
        let pipeline = ELVPipeline(pack: pack, fetcher: StubFetcher(responses: [:]))
        let result = try await pipeline.run(url: #require(URL(string: "https://example.com/whatever"))).result
        guard case .unrecognized = result else {
            Issue.record("Expected .unrecognized, got \(result)")
            return
        }
    }

    @Test
    func `A blocked fetch surfaces as a typed failure, not an empty record`() async throws {
        let pack = try loadPack(alltrailsPack)
        let stub = StubFetcher(responses: [:], failures: ["www.alltrails.com": .blocked(status: 403)])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let result = try await pipeline.run(url: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))).result
        guard case let .failed(failure, sourceId) = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
        #expect(failure == .blocked(status: 403))
        #expect(sourceId == "alltrails.trail")
    }

    @Test
    func `A JSON API source parses the body and assembles child collections`() async throws {
        let packJSON = """
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "pokeapi.pokemon",
            "kind": "pokemon",
            "match": {"host": ["pokeapi.co"], "path": "/api/v2/pokemon/:id"},
            "fetch": {"mode": "json"},
            "fields": [
              {"name": "externalId", "candidates": [{"from": {"json": "$.id"}}]},
              {"name": "name", "candidates": [{"from": {"json": "$.name"}, "pipe": ["capitalizeFirst"]}]},
              {"name": "height", "candidates": [{"from": {"json": "$.height"}, "as": "int"}]}
            ],
            "collections": [{
              "name": "types",
              "from": {"json": "$.types[*]"},
              "item": [{"name": "name", "candidates": [{"from": {"json": "$.type.name"}}]}]
            }]
          }]
        }
        """
        let body = """
        {"id": 25, "name": "pikachu", "height": 4,
         "types": [{"slot": 1, "type": {"name": "electric"}}]}
        """
        let pack = try loadPack(packJSON)
        let stub = try StubFetcher(responses: [
            "pokeapi.co": response(host: "pokeapi.co", url: "https://pokeapi.co/api/v2/pokemon/25", html: body),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let result = try await pipeline.run(url: #require(URL(string: "https://pokeapi.co/api/v2/pokemon/25"))).result

        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.externalId == "25")
        #expect(record.fields["name"] == .text("Pikachu"))
        #expect(record.fields["height"] == .number(4))
        #expect(record.collections["types"]?.first?.fields["name"] == .text("electric"))
    }

    @Test
    func `Re-running the same source folds under fillEmptyOnly, preserving edits`() async throws {
        let pack = try loadPack(alltrailsPack)
        let stub = try StubFetcher(responses: [
            "www.alltrails.com": response(host: "www.alltrails.com", url: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail", html: alltrailsHTML),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let url = try #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))
        guard case let .record(first) = await pipeline.run(url: url).result else {
            Issue.record("Expected a record")
            return
        }
        var edited = first
        edited.fields["title"] = .text("My Custom Name")
        guard case let .record(second) = await pipeline.run(url: url).result else {
            Issue.record("Expected a record")
            return
        }
        let merged = edited.merging(second, policy: .fillEmptyOnly)
        #expect(merged.fields["title"] == .text("My Custom Name"))
        #expect(merged.fields["rating"] == .rating(value: 4.7, scale: 0 ... 5))
    }

    private let floorsPack = """
    {
      "schemaVersion": 1, "packVersion": "test",
      "sources": [
        {
          "id": "generic.feed", "kind": "feed",
          "fetch": {"mode": "feed"},
          "fields": [{"name": "title", "candidates": [{"from": {"json": "$.title"}}]}]
        },
        {
          "id": "generic.opengraph", "kind": "link",
          "fetch": {"mode": "http"},
          "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
        }
      ]
    }
    """

    @Test
    func `The feed floor claims only real feed documents; a homepage with a feed link stays an OG record`() async throws {
        let pack = try loadPack(floorsPack)
        let homepage = """
        <html><head>
          <link rel="alternate" type="application/atom+xml" href="/atom.xml" />
          <meta property="og:title" content="Swift.org" />
        </head><body></body></html>
        """
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>A Feed</title></channel></rss>
        """
        let stub = try StubFetcher(responses: [
            "swift.org": response(host: "swift.org", url: "https://swift.org/", html: homepage),
            "feeds.example": response(host: "feeds.example", url: "https://feeds.example/rss.xml", html: rss),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)

        guard case let .record(link) = try await pipeline.run(url: #require(URL(string: "https://swift.org/"))).result else {
            Issue.record("Expected an OG record for the homepage")
            return
        }
        #expect(link.sourceId == "generic.opengraph")
        #expect(link.fields["title"] == .text("Swift.org"))
        // The floor pass fetches ONCE and every floor reads the shared
        // response — not one request per floor, and no autodiscovery hop.
        #expect(stub.requestedURLs == ["https://swift.org/"])

        guard case let .record(feed) = try await pipeline.run(url: #require(URL(string: "https://feeds.example/rss.xml"))).result else {
            Issue.record("Expected a feed record for the feed document")
            return
        }
        #expect(feed.sourceId == "generic.feed")
        #expect(feed.fields["title"] == .text("A Feed"))
        #expect(stub.requestedURLs.count == 2)
    }

    private let compositeMergePack = """
    {
      "schemaVersion": 1, "packVersion": "test",
      "sources": [{
        "id": "merge.article",
        "kind": "article",
        "match": {"host": ["rich.example"], "path": "/a/:id", "priority": 100},
        "fetch": {"mode": "composite", "steps": [
          {"mode": "http"},
          {"mode": "http", "url": "https://thin.example/a/{param.id}", "when": {"missingAny": ["rating"]}}
        ]},
        "fields": [
          {"name": "title", "candidates": [{"from": {"meta": "og:title"}}]},
          {"name": "summary", "candidates": [{"from": {"meta": "og:description"}}]},
          {"name": "rating", "candidates": [{"from": {"jsonld": "Article.aggregateRating.ratingValue"}, "as": "rating"}]}
        ]
      }]
    }
    """

    @Test
    func `Composite escalation merges fill-empty: a thinner escalated page cannot discard step 1's fields`() async throws {
        let richHTML = """
        <html><head>
          <meta property="og:title" content="Rich Title" />
          <meta property="og:description" content="A summary only step 1 serves" />
        </head><body></body></html>
        """
        let thinHTML = #"<html><head><meta property="og:title" content="Thin Title" /></head><body></body></html>"#
        let pack = try loadPack(compositeMergePack)
        let stub = try StubFetcher(responses: [
            "rich.example": response(host: "rich.example", url: "https://rich.example/a/1", html: richHTML),
            "thin.example": response(host: "thin.example", url: "https://thin.example/a/1", html: thinHTML),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let result = try await pipeline.run(url: #require(URL(string: "https://rich.example/a/1"))).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        // The escalated step wins where it produced; step 1's summary
        // survives the thinner second page instead of being wiped wholesale.
        #expect(record.fields["title"] == .text("Thin Title"))
        #expect(record.fields["summary"] == .text("A summary only step 1 serves"))
    }

    @Test
    func `A thrown step's status feeds the next step's status trigger`() async throws {
        let packJSON = """
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "status.article",
            "kind": "article",
            "match": {"host": ["status.example"], "path": "/a/:id", "priority": 100},
            "fetch": {"mode": "composite", "steps": [
              {"mode": "http"},
              {"mode": "http", "url": "https://blocked.example/a/{param.id}", "when": {"missingAny": ["title"]}},
              {"mode": "http", "url": "https://rescue.example/a/{param.id}", "when": {"status": [403]}}
            ]},
            "fields": [
              {"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}
            ]
          }]
        }
        """
        let bareHTML = "<html><head></head><body></body></html>"
        let rescueHTML = #"<html><head><meta property="og:title" content="Rescued" /></head><body></body></html>"#
        let pack = try loadPack(packJSON)
        let stub = try StubFetcher(
            responses: [
                "status.example": response(host: "status.example", url: "https://status.example/a/1", html: bareHTML),
                "rescue.example": response(host: "rescue.example", url: "https://rescue.example/a/1", html: rescueHTML),
            ],
            failures: ["blocked.example": .blocked(status: 403)]
        )
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let result = try await pipeline.run(url: #require(URL(string: "https://status.example/a/1"))).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        // Step 2 threw blocked(403); step 3's `status: [403]` trigger must
        // see that status, not step 1's stale 200.
        #expect(record.fields["title"] == .text("Rescued"))
        #expect(stub.requestedURLs.count == 3)
    }

    @Test
    func `A source whose steps all need unavailable transports fails with a named formatDrift, not a bare -1`() async throws {
        let packJSON = """
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "archive.rows",
            "kind": "row",
            "match": {"host": ["archive.example"], "path": "/**", "priority": 100},
            "fetch": {"mode": "archive", "format": "csv"},
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
          }]
        }
        """
        let pack = try loadPack(packJSON)
        let stub = StubFetcher(responses: [:])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let result = try await pipeline.run(url: #require(URL(string: "https://archive.example/export.csv"))).result
        guard case let .failed(failure, sourceId) = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
        #expect(failure == .formatDrift("no runnable fetch step (modes: archive)"))
        #expect(sourceId == "archive.rows")
        #expect(stub.requestedURLs.isEmpty)
    }

    private let truncPack = """
    {
      "schemaVersion": 1, "packVersion": "test",
      "sources": [{
        "id": "trunc.article",
        "kind": "article",
        "match": {"host": ["trunc.example"], "path": "/**", "priority": 100},
        "fetch": {"mode": "http"},
        "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
      }]
    }
    """

    @Test
    func `A truncated body that extracts nothing fails as formatDrift instead of an empty record`() async throws {
        let pack = try loadPack(truncPack)
        var cut = try response(host: "trunc.example", url: "https://trunc.example/a", html: #"<html><head><meta property="og:ti"#)
        cut.truncated = true
        let pipeline = ELVPipeline(pack: pack, fetcher: StubFetcher(responses: ["trunc.example": cut]))
        let result = try await pipeline.run(url: #require(URL(string: "https://trunc.example/a"))).result
        guard case let .failed(failure, sourceId) = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
        #expect(failure == .formatDrift("body truncated at byte cap"))
        #expect(sourceId == "trunc.article")
    }

    @Test
    func `A truncated body that still extracts proceeds as a partial record by design`() async throws {
        let pack = try loadPack(truncPack)
        var partial = try response(host: "trunc.example", url: "https://trunc.example/a", html: #"<html><head><meta property="og:title" content="Survived" /><p>cut he"#)
        partial.truncated = true
        let pipeline = ELVPipeline(pack: pack, fetcher: StubFetcher(responses: ["trunc.example": partial]))
        let result = try await pipeline.run(url: #require(URL(string: "https://trunc.example/a"))).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.fields["title"] == .text("Survived"))
    }

    @Test
    func `A list source resolved as a single page surfaces its items as a collection`() async throws {
        let packJSON = """
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "pokeapi.dex",
            "kind": "pokemon",
            "match": {"host": ["pokeapi.co"], "path": "/api/v2/pokemon"},
            "fetch": {"mode": "json"},
            "rows": [
              {"name": "externalId", "candidates": [{"from": {"json": "$.url"}}]},
              {"name": "title", "candidates": [{"from": {"json": "$.name"}, "pipe": ["capitalizeFirst"]}]}
            ],
            "list": {
              "seed": "https://pokeapi.co/api/v2/pokemon?limit=2",
              "items": {"json": "$.results[*]"},
              "next": {"json": "$.next"},
              "total": {"json": "$.count"},
              "maxPages": 5
            }
          }]
        }
        """
        let body = """
        {"count": 1302, "next": "https://pokeapi.co/api/v2/pokemon?offset=2&limit=2",
         "results": [
           {"name": "bulbasaur", "url": "https://pokeapi.co/api/v2/pokemon/1/"},
           {"name": "ivysaur", "url": "https://pokeapi.co/api/v2/pokemon/2/"}
         ]}
        """
        let pack = try loadPack(packJSON)
        let stub = try StubFetcher(responses: [
            "pokeapi.co": response(host: "pokeapi.co", url: "https://pokeapi.co/api/v2/pokemon?limit=2", html: body),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let result = try await pipeline.run(url: #require(URL(string: "https://pokeapi.co/api/v2/pokemon?limit=2"))).result

        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        let items = try #require(record.collections["items"])
        #expect(items.count == 2)
        #expect(items.first?.fields["title"] == .text("Bulbasaur"))
        #expect(items.last?.externalId == "https://pokeapi.co/api/v2/pokemon/2/")
    }

    // MARK: - Step-scoped extraction

    private let scopedPack = """
    {
      "schemaVersion": 1, "schemaMinor": 1, "packVersion": "test",
      "sources": [{
        "id": "album.page",
        "kind": "album",
        "match": {"host": ["page.example"], "path": "/album/:id", "priority": 100},
        "fetch": {"mode": "composite", "steps": [
          {"mode": "http"},
          {"mode": "json", "url": "https://api.example/lookup?id={param.id}",
           "fields": [{"name": "author", "candidates": [{"from": {"json": "$.artistName"}}]}],
           "collections": [{"name": "tracks", "from": {"json": "$.results[*]"}, "kind": "song",
             "item": [{"name": "title", "candidates": [{"from": {"json": "$.name"}}]}]}]}
        ]},
        "fields": [
          {"name": "title", "candidates": [{"from": {"meta": "og:title"}}, {"from": {"json": "$.title"}}]}
        ],
        "examples": []
      }]
    }
    """

    private func scopedStub() throws -> StubFetcher {
        try StubFetcher(responses: [
            "page.example": response(host: "page.example", url: "https://page.example/album/abc", html: "<html><head><meta property=\"og:title\" content=\"Real Title\"></head></html>"),
            "api.example": ELVFetchResponse(
                finalURL: #require(URL(string: "https://api.example/lookup?id=abc")),
                status: 200,
                data: Data(#"{"title": "JUNK", "artistName": "The Band", "results": [{"name": "One"}, {"name": "Two"}]}"#.utf8),
                bodyText: #"{"title": "JUNK", "artistName": "The Band", "results": [{"name": "One"}, {"name": "Two"}]}"#,
                truncated: false
            ),
        ])
    }

    @Test
    func `A scoped step cannot overwrite fields it does not declare, and its collections bind to its own context`() async throws {
        let pack = try loadPack(scopedPack)
        let stub = try scopedStub()
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let url = try #require(URL(string: "https://page.example/album/abc"))
        guard case let .record(record) = await pipeline.run(url: url).result else {
            Issue.record("Expected a record")
            return
        }
        // The lookup document carries a junk title; the scoped ladder never
        // reads it, so step 1's real title survives the merge.
        #expect(record.fields["title"] == .text("Real Title"))
        #expect(record.fields["author"] == .text("The Band"))
        // Step-scoped collections assembled from the lookup step's context,
        // even though the record's final context is the page's.
        #expect(record.collections["tracks"]?.map { $0.fields["title"] } == [.text("One"), .text("Two")])
        #expect(record.collections["tracks"]?.first?.kind == "song")
    }

    @Test
    func `Without scoping, a later step's junk overwrites the page title (the hazard B1 exists for)`() async throws {
        let unscoped = scopedPack
            .replacingOccurrences(of: #""fields": [{"name": "author", "candidates": [{"from": {"json": "$.artistName"}}]}],"#, with: "")
        let pack = try loadPack(unscoped)
        let pipeline = try ELVPipeline(pack: pack, fetcher: scopedStub())
        let url = try #require(URL(string: "https://page.example/album/abc"))
        guard case let .record(record) = await pipeline.run(url: url).result else {
            Issue.record("Expected a record")
            return
        }
        // Documentation of the pre-B1 behavior: the flat ladder re-runs on
        // the lookup JSON and the fill-empty merge lets the junk title win.
        #expect(record.fields["title"] == .text("JUNK"))
    }

    @Test
    func `Step maxBytes reaches the fetcher; unscoped steps keep the standard budget`() async throws {
        let budgetPack = scopedPack.replacingOccurrences(
            of: #"{"mode": "json", "url": "https://api.example/lookup?id={param.id}","#,
            with: #"{"mode": "json", "url": "https://api.example/lookup?id={param.id}", "maxBytes": 5000000,"#
        )
        let pack = try loadPack(budgetPack)
        let stub = try scopedStub()
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let url = try #require(URL(string: "https://page.example/album/abc"))
        _ = await pipeline.run(url: url).result
        #expect(stub.budgets["api.example"] == 5_000_000)
        #expect(stub.budgets["page.example"] == 3_000_000)
    }

    @Test
    func `A dangling trigger reference never admits its step`() async throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t",
         "sources": [{"id": "album.page", "kind": "album",
           "match": {"host": ["page.example"], "path": "/album/:id", "priority": 100},
           "fetch": {"mode": "composite", "steps": [
             {"mode": "http"},
             {"mode": "json", "url": "https://api.example/lookup?id={param.id}", "when": "vanished"}
           ]},
           "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}],
           "examples": []}]}
        """
        let pack = try loadPack(json)
        let stub = try scopedStub()
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let url = try #require(URL(string: "https://page.example/album/abc"))
        guard case let .record(record) = await pipeline.run(url: url).result else {
            Issue.record("Expected a record from step 1")
            return
        }
        #expect(record.fields["title"] == .text("Real Title"))
        // The conditional-and-unresolvable step never fetched.
        #expect(!stub.requestedURLs.contains { $0.contains("api.example") })
    }

    @Test
    func `A truncated step whose scoped collections still produced is partial output, not a failure`() async throws {
        let pack = try loadPack(scopedPack)
        let json = #"{"artistName": "The Band", "results": [{"name": "One"}]}"#
        let stub = try StubFetcher(responses: [
            "page.example": response(host: "page.example", url: "https://page.example/album/abc", html: "<html><head><meta property=\"og:title\" content=\"Real Title\"></head></html>"),
            "api.example": ELVFetchResponse(
                finalURL: #require(URL(string: "https://api.example/lookup?id=abc")),
                status: 200,
                data: Data(json.utf8),
                bodyText: json,
                truncated: true
            ),
        ])
        let pipeline = ELVPipeline(pack: pack, fetcher: stub)
        let url = try #require(URL(string: "https://page.example/album/abc"))
        guard case let .record(record) = await pipeline.run(url: url).result else {
            Issue.record("Expected a record from the truncated-but-productive step")
            return
        }
        #expect(record.collections["tracks"]?.count == 1)
    }
}
