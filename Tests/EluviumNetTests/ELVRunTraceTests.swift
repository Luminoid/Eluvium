import EluviumCore
import Foundation
import Synchronization
import Testing
@testable import EluviumNet

/// Serves canned bodies keyed by host, with per-host failures and an
/// optional truncation flag.
private final class TraceStubFetcher: ELVFetching, @unchecked Sendable {
    private let bodies: [String: String]
    private let failures: [String: ELVFetchFailure]
    private let truncatedHosts: Set<String>
    private let requestLog = Mutex<[String]>([])

    init(bodies: [String: String], failures: [String: ELVFetchFailure] = [:], truncatedHosts: Set<String> = []) {
        self.bodies = bodies
        self.failures = failures
        self.truncatedHosts = truncatedHosts
    }

    var requestedURLs: [String] { requestLog.withLock { $0 } }

    func fetch(_ url: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
        requestLog.withLock { $0.append(url.absoluteString) }
        let host = url.host ?? ""
        if let failure = failures[host] { throw failure }
        guard let body = bodies[host] else { throw ELVFetchFailure.httpError(status: 404) }
        return ELVFetchResponse(finalURL: url, status: 200, data: Data(body.utf8), bodyText: body, truncated: truncatedHosts.contains(host))
    }
}

/// The per-run trace (what ran, what came up empty) and the silent-failure
/// rules it backs: an empty record from a recognized source is drift, a
/// json or feed step handed the wrong document is drift, and degraded steps
/// stay visible even when the run still produced a record.
@Suite("Run trace")
struct ELVRunTraceTests {
    private func loadPack(_ json: String, dom: Bool = false) throws -> ELVLoadedPack {
        var modes: Set = ["http", "json", "feed", "composite"]
        if dom { modes.insert("dom") }
        return try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: modes, binaryVersion: "0.1"))
    }

    private let itemPack = """
    {
      "schemaVersion": 1, "packVersion": "test",
      "sources": [{
        "id": "trace.item",
        "kind": "item",
        "match": {"host": ["trace.example"], "path": "/item/:slug", "priority": 100},
        "fetch": {"mode": "http"},
        "fields": [
          {"name": "title", "candidates": [{"from": {"meta": "og:title"}}]},
          {"name": "rating", "candidates": [
            {"from": {"jsonld": "Product.aggregateRating.ratingValue"}},
            {"from": {"meta": "rating"}}
          ]}
        ]
      }]
    }
    """

    private let titledHTML = #"<html><head><meta property="og:title" content="Hidden Falls" /></head><body></body></html>"#

    @Test
    func `A run's trace names each step's host, status, bytes, and outcome, and the missed fields with their candidates`() async throws {
        let stub = TraceStubFetcher(bodies: ["trace.example": titledHTML])
        let pipeline = try ELVPipeline(pack: loadPack(itemPack), fetcher: stub)

        let run = try await pipeline.run(url: #require(URL(string: "https://trace.example/item/falls?s=secret-token")))

        let record = try #require(run.record)
        #expect(record.fields["title"] == .text("Hidden Falls"))
        let trace = run.trace
        #expect(trace.inputHost == "trace.example")
        #expect(trace.sourceIds == ["trace.item"])
        #expect(!trace.usedFloors)
        #expect(!trace.servedFromCache)
        let step = try #require(trace.steps.first)
        #expect(trace.steps.count == 1)
        #expect(step.sourceId == "trace.item")
        #expect(step.index == 0)
        #expect(step.mode == "http")
        #expect(step.host == "trace.example")
        #expect(step.status == 200)
        #expect(step.bytes == titledHTML.utf8.count)
        #expect(!step.truncated)
        #expect(step.settled == nil)
        #expect(step.extracted == 1)
        #expect(step.outcome == .produced)
        // The full URL (with its share token) lives only in `finalURL`.
        #expect(step.finalURL?.query == "s=secret-token")
        #expect(trace.fieldMisses == [ELVFieldMiss(field: "rating", candidates: ["jsonld:Product.aggregateRating.ratingValue", "meta:rating"])])
        #expect(!trace.isDegraded)
    }

    @Test
    func `A recognized source that extracts nothing fails as drift, and the trace lists every miss`() async throws {
        let stub = TraceStubFetcher(bodies: ["trace.example": "<html><head></head><body></body></html>"])
        let pipeline = try ELVPipeline(pack: loadPack(itemPack), fetcher: stub)

        let run = try await pipeline.run(url: #require(URL(string: "https://trace.example/item/empty")))

        guard case let .failed(failure, sourceId) = run.result else {
            Issue.record("Expected drift, got \(run.result)")
            return
        }
        #expect(failure == .formatDrift("no fields extracted"))
        #expect(sourceId == "trace.item")
        #expect(run.trace.steps.map(\.outcome) == [.produced])
        #expect(run.trace.fieldMisses.map(\.field) == ["title", "rating"])
    }

    @Test
    func `A URL-only source that parses nothing from a non-detail URL is the host prior, not drift`() async throws {
        // `none` never fetches, so there is no page format to drift: a
        // city page on a tours host still answers with the source's kind
        // (the Tripadvisor Tourism / GetYourGuide city-page corpus entries).
        let urlOnlyPack = """
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "trace.tour",
            "kind": "activity",
            "match": {"host": ["tours.example"], "path": "/**", "priority": 100},
            "fetch": {"mode": "none"},
            "fields": [
              {"name": "externalId", "candidates": [{"from": {"urlRegex": "-t([0-9]+)/?$"}}]}
            ]
          }]
        }
        """
        let stub = TraceStubFetcher(bodies: [:])
        let pipeline = try ELVPipeline(pack: loadPack(urlOnlyPack), fetcher: stub)

        let run = try await pipeline.run(url: #require(URL(string: "https://tours.example/barcelona-l45/")))

        let record = try #require(run.record, "expected the kind-only record, got \(run.result)")
        #expect(record.kind == "activity")
        #expect(record.fields.isEmpty)
        #expect(stub.requestedURLs.isEmpty)
    }

    @Test
    func `A step URL template reads the input's query item, and a missing item fails the step typed`() async throws {
        // The WeRead share link carries its book id as `?v=`; the step
        // fetches the detail page built from it.
        let queryPack = """
        {
          "schemaVersion": 1, "schemaMinor": 3, "packVersion": "test",
          "sources": [{
            "id": "trace.share",
            "kind": "book",
            "match": {"host": ["share.example"], "path": "/book-detail", "priority": 100},
            "canonicalize": {"keep": ["v"]},
            "fetch": {"mode": "http", "url": "https://books.example/detail/{query.v}"},
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
          }]
        }
        """
        let stub = TraceStubFetcher(bodies: ["books.example": titledHTML])
        let pipeline = try ELVPipeline(pack: loadPack(queryPack), fetcher: stub)

        let run = try await pipeline.run(url: #require(URL(string: "https://share.example/book-detail?v=ab12&senderVid=99")))
        #expect(run.record?.fields["title"] == .text("Hidden Falls"))
        #expect(stub.requestedURLs == ["https://books.example/detail/ab12"])

        let missing = try await pipeline.run(url: #require(URL(string: "https://share.example/book-detail?senderVid=99")))
        guard case let .failed(failure, _) = missing.result else {
            Issue.record("Expected a typed failure, got \(missing.result)")
            return
        }
        #expect(failure == .formatDrift("url template input placeholder missing"))
        #expect(stub.requestedURLs.count == 1)
    }

    @Test
    func `Declined, failed, and skipped steps all stay in the trace when an earlier step produced`() async throws {
        let compositePack = """
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "trace.composite",
            "kind": "item",
            "match": {"host": ["trace.example"], "path": "/item/:slug", "priority": 100},
            "fetch": {"mode": "composite", "steps": [
              {"mode": "http"},
              {"mode": "http", "ua": "crawler", "when": {"status": [403]}},
              {"mode": "json", "url": "https://api.trace.example/rating/{param.slug}", "when": {"missingAny": ["rating"]}},
              {"mode": "dom", "when": {"missingAny": ["rating"]}}
            ]},
            "fields": [
              {"name": "title", "candidates": [{"from": {"meta": "og:title"}}]},
              {"name": "rating", "candidates": [{"from": {"json": "$.rating"}}]}
            ]
          }]
        }
        """
        let stub = TraceStubFetcher(bodies: ["trace.example": titledHTML], failures: ["api.trace.example": .blocked(status: 503)])
        // dom is a declared capability, but no renderer is injected.
        let pipeline = try ELVPipeline(pack: loadPack(compositePack, dom: true), fetcher: stub)

        let run = try await pipeline.run(url: #require(URL(string: "https://trace.example/item/falls")))

        #expect(run.record?.fields["title"] == .text("Hidden Falls"))
        #expect(run.trace.steps.map(\.outcome) == [.produced, .declined, .failed(.blocked(status: 503)), .skipped])
        #expect(run.trace.steps.map(\.mode) == ["http", "http", "json", "dom"])
        #expect(run.trace.steps[2].host == "api.trace.example")
        #expect(run.trace.isDegraded)
        #expect(run.trace.fieldMisses.map(\.field) == ["rating"])
    }

    @Test
    func `A json step handed a non-JSON body fails as drift instead of extracting an empty record`() async throws {
        let pack = """
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "trace.api",
            "kind": "item",
            "match": {"host": ["api.trace.example"], "path": "/v1/:id", "priority": 100},
            "fetch": {"mode": "json"},
            "fields": [{"name": "title", "candidates": [{"from": {"json": "$.title"}}]}]
          }]
        }
        """
        let stub = TraceStubFetcher(bodies: ["api.trace.example": "<html><body>Maintenance</body></html>"])
        let pipeline = try ELVPipeline(pack: loadPack(pack), fetcher: stub)

        let run = try await pipeline.run(url: #require(URL(string: "https://api.trace.example/v1/7")))

        guard case let .failed(failure, _) = run.result else {
            Issue.record("Expected drift, got \(run.result)")
            return
        }
        #expect(failure == .formatDrift("json step: response is not JSON"))
        #expect(run.trace.steps.first?.status == 200)
    }

    private let feedPack = """
    {
      "schemaVersion": 1, "packVersion": "test",
      "sources": [{
        "id": "trace.feed",
        "kind": "feed",
        "match": {"host": ["blog.trace.example"], "path": "/**", "priority": 100},
        "fetch": {"mode": "feed"},
        "fields": [{"name": "title", "candidates": [{"from": {"json": "$.title"}}]}]
      }]
    }
    """

    @Test
    func `A feed step that finds no feed fails as drift, whether none is advertised or the advertised link is not one`() async throws {
        let bare = TraceStubFetcher(bodies: ["blog.trace.example": "<html><head><title>Blog</title></head></html>"])
        let bareRun = try await ELVPipeline(pack: loadPack(feedPack), fetcher: bare).run(url: #require(URL(string: "https://blog.trace.example/")))
        guard case let .failed(bareFailure, _) = bareRun.result else {
            Issue.record("Expected drift, got \(bareRun.result)")
            return
        }
        #expect(bareFailure == .formatDrift("feed step: response is not a feed and advertises none"))

        let advertising = #"<html><head><link rel="alternate" type="application/rss+xml" href="https://feeds.trace.example/rss.xml"></head></html>"#
        let misleading = TraceStubFetcher(bodies: [
            "blog.trace.example": advertising,
            "feeds.trace.example": "<html><body>Not a feed</body></html>",
        ])
        let misleadingRun = try await ELVPipeline(pack: loadPack(feedPack), fetcher: misleading).run(url: #require(URL(string: "https://blog.trace.example/")))
        guard case let .failed(misleadingFailure, _) = misleadingRun.result else {
            Issue.record("Expected drift, got \(misleadingRun.result)")
            return
        }
        #expect(misleadingFailure == .formatDrift("feed step: the advertised feed link is not a feed"))
        #expect(misleading.requestedURLs == ["https://blog.trace.example/", "https://feeds.trace.example/rss.xml"])
    }

    @Test
    func `A followed feed link is noted on the step, with the feed's own fetch facts`() async throws {
        let advertising = #"<html><head><link rel="alternate" type="application/rss+xml" href="https://feeds.trace.example/rss.xml"></head></html>"#
        let rss = #"<?xml version="1.0"?><rss version="2.0"><channel><title>Trail Notes</title><item><title>One</title><link>https://blog.trace.example/1</link></item></channel></rss>"#
        let stub = TraceStubFetcher(bodies: ["blog.trace.example": advertising, "feeds.trace.example": rss])

        let run = try await ELVPipeline(pack: loadPack(feedPack), fetcher: stub).run(url: #require(URL(string: "https://blog.trace.example/")))

        #expect(run.record?.fields["title"] == .text("Trail Notes"))
        let step = try #require(run.trace.steps.first)
        #expect(step.notes == ["followed the advertised feed link to feeds.trace.example"])
        #expect(step.finalURL?.host == "feeds.trace.example")
        #expect(step.bytes == rss.utf8.count)
    }

    @Test
    func `A truncated body is reported in the trace even when the step still extracted`() async throws {
        let stub = TraceStubFetcher(bodies: ["trace.example": titledHTML], truncatedHosts: ["trace.example"])
        let pipeline = try ELVPipeline(pack: loadPack(itemPack), fetcher: stub)

        let run = try await pipeline.run(url: #require(URL(string: "https://trace.example/item/falls")))

        #expect(run.record?.fields["title"] == .text("Hidden Falls"))
        #expect(run.trace.steps.first?.truncated == true)
        #expect(run.trace.isDegraded)
    }

    @Test
    func `An async native op that throws is kept in the trace, distinct from an op that found nothing`() async throws {
        ELVNativeOps.registerAsync("test.trace.throwingLookup", version: 1) { _, _ in
            throw URLError(.timedOut)
        }
        ELVNativeOps.registerAsync("test.trace.emptyLookup", version: 1) { _, _ in nil }
        let pack = """
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "trace.place",
            "kind": "place",
            "match": {"host": ["trace.example"], "path": "/item/:slug", "priority": 100},
            "fetch": {"mode": "http"},
            "fields": [
              {"name": "title", "candidates": [{"from": {"meta": "og:title"}}]},
              {"name": "address", "candidates": [{"from": {"native": "test.trace.throwingLookup@1", "input": {"name": "$field.title"}}}]},
              {"name": "phone", "candidates": [{"from": {"native": "test.trace.emptyLookup@1", "input": {"name": "$field.title"}}}]}
            ]
          }]
        }
        """
        let stub = TraceStubFetcher(bodies: ["trace.example": titledHTML])
        let pipeline = try ELVPipeline(pack: loadPack(pack), fetcher: stub)

        let run = try await pipeline.run(url: #require(URL(string: "https://trace.example/item/falls")))

        let record = try #require(run.record)
        #expect(record.fields["address"] == nil)
        #expect(run.trace.nativeOpFailures == [
            ELVNativeOpFailure(field: "address", op: "test.trace.throwingLookup@1", error: "NSURLErrorDomain -1001"),
        ])
        #expect(run.trace.fieldMisses.map(\.field) == ["address", "phone"])
        #expect(run.trace.isDegraded)
    }

    @Test
    func `The generic floors keep returning an empty link card, and the trace says each floor came up empty`() async throws {
        let floorPack = """
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "floor.og",
            "kind": "link",
            "fetch": {"mode": "http"},
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
          }]
        }
        """
        let stub = TraceStubFetcher(bodies: ["plain.example": "<html><body>nothing</body></html>"])
        let pipeline = try ELVPipeline(pack: loadPack(floorPack), fetcher: stub)

        let run = try await pipeline.run(url: #require(URL(string: "https://plain.example/page")))

        let record = try #require(run.record)
        #expect(record.fields.isEmpty)
        #expect(run.trace.usedFloors)
        #expect(run.trace.sourceIds == ["floor.og"])
        #expect(run.trace.notes == ["floor floor.og extracted nothing"])
        #expect(run.trace.steps.first?.sourceId == nil)
        #expect(run.trace.steps.first?.outcome == .produced)
    }

    @Test
    func `runSeed on an unknown source fails typed and says why in the trace`() async throws {
        let pipeline = try ELVPipeline(pack: loadPack(itemPack), fetcher: TraceStubFetcher(bodies: [:]))

        let run = await pipeline.runSeed(sourceId: "lists.unknown")

        guard case let .failed(failure, _) = run.result else {
            Issue.record("Expected a failure, got \(run.result)")
            return
        }
        #expect(failure == .invalidURL)
        #expect(run.trace.notes == ["no active source lists.unknown"])
        #expect(run.trace.steps.isEmpty)
    }

    @Test
    func `An ingest session cache hit returns the original trace marked as served from cache`() async throws {
        let stub = TraceStubFetcher(bodies: ["trace.example": titledHTML])
        let session = try ELVIngestSession(pack: loadPack(itemPack), fetcher: stub)
        let url = try #require(URL(string: "https://trace.example/item/falls"))

        let first = await session.ingest(url: url)
        let second = await session.ingest(url: url)

        #expect(!first.trace.servedFromCache)
        #expect(second.trace.servedFromCache)
        #expect(second.trace.steps == first.trace.steps)
        #expect(stub.requestedURLs.count == 1)
    }
}
