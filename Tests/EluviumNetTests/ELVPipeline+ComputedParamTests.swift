import EluviumCatalog
import EluviumCore
import Foundation
import Synchronization
import Testing
@testable import EluviumNet

/// A canned fetcher keyed by host, logging every requested URL — the
/// computed-param template's assertable surface is the exact URL the
/// pipeline built.
private final class HostFetcher: ELVFetching, @unchecked Sendable {
    private let bodies: [String: String]
    private let requestLog = Mutex<[String]>([])

    init(bodies: [String: String]) {
        self.bodies = bodies
    }

    var requestedURLs: [String] { requestLog.withLock { $0 } }

    func fetch(_ url: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
        requestLog.withLock { $0.append(url.absoluteString) }
        guard let body = bodies[url.host ?? ""] else { throw ELVFetchFailure.httpError(status: 404) }
        return ELVFetchResponse(finalURL: url, status: 200, data: Data(body.utf8), bodyText: body, truncated: false)
    }
}

/// The computed-param URL template and the x.post source,
/// end to end over the REAL starter pack against canned bodies — plus the
/// awaited field walk that serves async native ops to field candidates.
@Suite("Computed-param pipeline")
struct ELVPipelineComputedParamTests {
    private func starterPipeline(fetcher: any ELVFetching) throws -> ELVPipeline {
        let pack = try ELVPackLoader.load(
            embedded: ELVStarterPack.data,
            capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed"], binaryVersion: "0.1")
        )
        return ELVPipeline(pack: pack, fetcher: fetcher)
    }

    private let syndicationBody = """
    {
      "__typename": "Tweet", "id_str": "20",
      "text": "just setting up my twttr",
      "created_at": "2006-03-21T20:50:14.000Z",
      "user": { "id_str": "12", "name": "jack", "screen_name": "jack" },
      "favorite_count": 176089
    }
    """

    @Test
    func `A tweet URL fetches the syndication endpoint with the computed token and keeps the page as sourceURL`() async throws {
        let fetcher = HostFetcher(bodies: ["cdn.syndication.twimg.com": syndicationBody])
        let pipeline = try starterPipeline(fetcher: fetcher)
        // Share tracking params ride in and are canonicalized away.
        let url = try #require(URL(string: "https://x.com/jack/status/20?s=46&t=AbCdEf"))
        let result = await pipeline.run(url: url).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        // The token is computed from the id by the template's native op —
        // the value ELVSyndicationToken's own tests pin for id 20.
        #expect(fetcher.requestedURLs == ["https://cdn.syndication.twimg.com/tweet-result?id=20&token=6dq1a2xwd93"])
        #expect(record.sourceId == "x.post")
        #expect(record.externalId == "20")
        #expect(record.fields["text"] == .text("just setting up my twttr"))
        #expect(record.fields["handle"] == .text("jack"))
        #expect(record.fields["likeCount"] == .number(176_089))
        // The record's sourceURL is the recognized page (canonicalized),
        // never the API endpoint the template fetched.
        #expect(record.sourceURL?.absoluteString == "https://x.com/jack/status/20")
        #expect(record.identities == [ELVIdentity(namespace: "x.tweet", value: "20", origin: .declared)])
    }

    @Test
    func `An empty syndication answer (token churn) escalates to the oEmbed step`() async throws {
        let oembed = """
        {
          "author_name": "jack",
          "author_url": "https://twitter.com/jack",
          "html": "<blockquote><p>just setting up my twttr</p>&mdash; jack (@jack)</blockquote>"
        }
        """
        let fetcher = HostFetcher(bodies: [
            "cdn.syndication.twimg.com": "{}",
            "publish.x.com": oembed,
        ])
        let pipeline = try starterPipeline(fetcher: fetcher)
        let url = try #require(URL(string: "https://x.com/jack/status/20"))
        let result = await pipeline.run(url: url).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        // Exactly two fetches: the churned `{}` fired the oEmbed escalation,
        // and the oEmbed text satisfied the third step's trigger.
        #expect(fetcher.requestedURLs.count == 2)
        #expect(fetcher.requestedURLs.first?.contains("cdn.syndication.twimg.com") == true)
        #expect(fetcher.requestedURLs.last == "https://publish.x.com/oembed?url=https%3A%2F%2Fx.com%2Fjack%2Fstatus%2F20")
        guard case let .text(text)? = record.fields["text"] else {
            Issue.record("Expected oEmbed text")
            return
        }
        #expect(text.contains("just setting up my twttr"))
        #expect(record.fields["author"] == .text("jack"))
    }

    @Test
    func `A label-less Maps URL escalates from none to http and classifies the page metas`() async throws {
        let html = """
        <html><head>
          <meta property="og:title" content="Benu · 4.6★(3,067) · Fine dining restaurant" />
          <meta property="og:description" content="★★★★☆ · Restaurant · 22 Hawthorne St, San Francisco" />
        </head></html>
        """
        let fetcher = HostFetcher(bodies: ["www.google.com": html])
        let pipeline = try starterPipeline(fetcher: fetcher)
        let url = try #require(URL(string: "https://www.google.com/maps?ftid=0x808f7fc5d3d0f0f9:0x3a0e2"))
        let result = await pipeline.run(url: url).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        // One fetch: the place page's metas, read by the scoped meta step,
        // and the classifier routed the segments; the URL named nothing, so
        // the page's name is the label.
        #expect(fetcher.requestedURLs.count == 1)
        #expect(record.sourceId == "gmaps.place")
        #expect(record.externalId == "0x808f7fc5d3d0f0f9:0x3a0e2")
        #expect(record.fields["label"] == .text("Benu"))
        #expect(record.fields["placeType"] == .text("Fine dining restaurant"))
        #expect(record.fields["category"] == .text("food"))
        #expect(record.fields["rating"] == .rating(value: 4.6, scale: 0 ... 5))
        #expect(record.fields["address"] == .text("22 Hawthorne St, San Francisco"))
    }

    @Test
    func `The awaited field walk serves async native ops to candidates, in declared order`() async throws {
        ELVNativeOps.registerAsync("test.pipeline.asyncField", version: 1) { input, _ in
            ["value": .text("async:\(input["seed"] ?? "-")")]
        }
        let packJSON = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [{
          "id": "async.example", "kind": "thing",
          "match": {"host": ["api.example"], "path": "/thing/:id", "priority": 100},
          "fetch": {"mode": "json"},
          "fields": [
            {"name": "externalId", "candidates": [{"from": {"urlParam": "id"}}]},
            {"name": "title", "candidates": [
              {"from": {"json": "$.missing"}},
              {"from": {"native": "test.pipeline.asyncField@1", "input": {"seed": "$param.id"}}, "select": "value"}
            ]}
          ]
        }]}
        """
        let pack = try ELVPackLoader.load(embedded: Data(packJSON.utf8), capabilities: ELVCapabilities(fetchModes: ["json"], binaryVersion: "0.1"))
        // The async op in a field candidate list is live through the
        // pipeline, so the validator has nothing to flag.
        #expect(pack.diagnostics.isEmpty, "\(pack.diagnostics)")
        let pipeline = ELVPipeline(pack: pack, fetcher: HostFetcher(bodies: ["api.example": "{}"]))
        let result = try await pipeline.run(url: #require(URL(string: "https://api.example/thing/7"))).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.fields["title"] == .text("async:7"))
        #expect(record.externalId == "7")
    }
}
