import EluviumCore
import Foundation
import Synchronization
import Testing
@testable import EluviumNet

/// A one-shot gate: gated fetches park here until the test opens it, so
/// concurrent ingests are observably in flight.
private actor FetchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A fixture-replaying fetcher for session tests: counts every fetch that
/// STARTS (the coalescing assertions), lets responses be swapped mid-test
/// (the bot wall lifting), and optionally parks deliveries on a gate. After
/// the gate it re-checks cancellation, so a cancelled shared run would
/// surface as a typed failure instead of a record.
private final class SessionStubFetcher: ELVFetching, @unchecked Sendable {
    private struct State {
        var responses: [String: ELVFetchResponse]
        var failures: [String: ELVFetchFailure]
        var started: [String] = []
    }

    private let state: Mutex<State>
    private let gate: FetchGate?

    init(responses: [String: ELVFetchResponse], failures: [String: ELVFetchFailure] = [:], gate: FetchGate? = nil) {
        state = Mutex(State(responses: responses, failures: failures))
        self.gate = gate
    }

    var fetchCount: Int { state.withLock { $0.started.count } }

    func setFailure(_ failure: ELVFetchFailure?, forHost host: String) {
        state.withLock { $0.failures[host] = failure }
    }

    func setResponse(_ response: ELVFetchResponse, forHost host: String) {
        state.withLock { $0.responses[host] = response }
    }

    func fetch(_ url: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
        state.withLock { $0.started.append(url.absoluteString) }
        if let gate {
            await gate.wait()
            try Task.checkCancellation()
        }
        let host = url.host ?? ""
        let (failure, response) = state.withLock { ($0.failures[host], $0.responses[host]) }
        if let failure { throw failure }
        guard let response else { throw ELVFetchFailure.httpError(status: 404) }
        return response
    }
}

@Suite("Ingest session cache and coalescing")
struct ELVIngestSessionTests {
    private func loadPack(_ json: String) throws -> ELVLoadedPack {
        try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: ["http", "json", "feed"], binaryVersion: "0.1"))
    }

    private func response(url: String, html: String, status: Int = 200) throws -> ELVFetchResponse {
        try ELVFetchResponse(finalURL: #require(URL(string: url)), status: status, data: Data(html.utf8), bodyText: html, truncated: false)
    }

    /// Polls until `condition` holds — the deterministic half of the gated
    /// tests (waiting for a fetch to have started before acting on it).
    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("condition never became true")
    }

    /// A recognized source with a canonicalize rule, so cache keying is
    /// observable across tracking-param variants.
    private let trailPack = """
    {
      "schemaVersion": 1, "packVersion": "test",
      "sources": [{
        "id": "trail.page",
        "kind": "trail",
        "match": {"host": ["trail.example"], "path": "/trail/:slug", "priority": 100},
        "canonicalize": {"strip": ["utm_*", "sh"]},
        "fetch": {"mode": "http"},
        "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
      }]
    }
    """

    private let trailHTML = #"<html><head><meta property="og:title" content="Hidden Falls" /></head><body></body></html>"#

    private func record(from result: ELVPipelineResult) -> ELVRecord? {
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return nil
        }
        return record
    }

    @Test
    func `A second ingest of the same URL is served from the session cache without refetching`() async throws {
        let stub = try SessionStubFetcher(responses: ["trail.example": response(url: "https://trail.example/trail/hidden-falls", html: trailHTML)])
        let session = try ELVIngestSession(pack: loadPack(trailPack), fetcher: stub)

        let variant = try #require(URL(string: "https://trail.example/trail/hidden-falls?utm_source=share&sh=abc"))
        let bare = try #require(URL(string: "https://trail.example/trail/hidden-falls"))

        let first = try #require(await record(from: session.ingest(url: variant).result))
        #expect(first.fields["title"] == .text("Hidden Falls"))
        #expect(stub.fetchCount == 1)

        // The key is the CANONICALIZED input URL: the bare form and
        // the tracking-param variant share one entry, so neither refetches.
        let second = try #require(await record(from: session.ingest(url: bare).result))
        #expect(second == first)
        let third = try #require(await record(from: session.ingest(url: variant).result))
        #expect(third == first)
        #expect(stub.fetchCount == 1)
    }

    @Test
    func `Concurrent ingests of the same URL coalesce into one fetch`() async throws {
        // A page yielding nothing (the recognized source's typed
        // "no fields extracted" drift): never pinned, so a late second
        // ingest would show up as a SECOND fetch — a visible failure rather
        // than a cache hit masquerading as coalescing.
        let bareHTML = "<html><head></head><body></body></html>"
        let gate = FetchGate()
        let stub = try SessionStubFetcher(responses: ["trail.example": response(url: "https://trail.example/trail/bare", html: bareHTML)], gate: gate)
        let session = try ELVIngestSession(pack: loadPack(trailPack), fetcher: stub)
        let url = try #require(URL(string: "https://trail.example/trail/bare"))

        let first = Task { await session.ingest(url: url).result }
        try await waitUntil { stub.fetchCount == 1 }
        let second = Task { await session.ingest(url: url).result }
        // The gate is still closed, so the run cannot complete before the
        // joiner arrives; the sleep only lets the joiner reach the actor.
        try await Task.sleep(for: .milliseconds(20))
        await gate.open()

        for awaited in await [first.value, second.value] {
            guard case let .failed(failure, sourceId) = awaited else {
                Issue.record("Expected the shared drift failure, got \(awaited)")
                continue
            }
            #expect(failure == .formatDrift("no fields extracted"))
            #expect(sourceId == "trail.page")
        }
        #expect(stub.fetchCount == 1)

        // And the failure was never pinned: a fresh ingest refetches.
        _ = await session.ingest(url: url).result
        #expect(stub.fetchCount == 2)
    }

    @Test
    func `Cancelling one awaiter cancels neither the shared run nor the other awaiter`() async throws {
        let gate = FetchGate()
        let stub = try SessionStubFetcher(responses: ["trail.example": response(url: "https://trail.example/trail/hidden-falls", html: trailHTML)], gate: gate)
        let session = try ELVIngestSession(pack: loadPack(trailPack), fetcher: stub)
        let url = try #require(URL(string: "https://trail.example/trail/hidden-falls"))

        let preview = Task { await session.ingest(url: url).result }
        try await waitUntil { stub.fetchCount == 1 }
        let enrich = Task { await session.ingest(url: url).result }
        try await Task.sleep(for: .milliseconds(20))

        preview.cancel()
        await gate.open()

        // The stub re-checks cancellation after the gate: had the preview's
        // cancellation reached the shared task, this would be a typed
        // "cancelled" failure, not a record.
        let enriched = try #require(await record(from: enrich.value))
        #expect(enriched.fields["title"] == .text("Hidden Falls"))
        // The cancelled awaiter still receives the shared result:
        // `Task.value` on a non-throwing task does not propagate its own
        // cancellation into the join.
        let previewed = try #require(await record(from: preview.value))
        #expect(previewed == enriched)
        #expect(stub.fetchCount == 1)
    }

    @Test
    func `A blocked result is never cached and the retry refetches`() async throws {
        let stub = SessionStubFetcher(responses: [:], failures: ["trail.example": .blocked(status: 403)])
        let session = try ELVIngestSession(pack: loadPack(trailPack), fetcher: stub)
        let url = try #require(URL(string: "https://trail.example/trail/hidden-falls"))

        guard case let .failed(failure, sourceId) = await session.ingest(url: url).result else {
            Issue.record("Expected .failed")
            return
        }
        #expect(failure == .blocked(status: 403))
        #expect(sourceId == "trail.page")

        // The bot wall lifts: the retry must reach the network and succeed,
        // which it can only do if the failure was never pinned.
        stub.setFailure(nil, forHost: "trail.example")
        try stub.setResponse(response(url: "https://trail.example/trail/hidden-falls", html: trailHTML), forHost: "trail.example")
        let retried = try #require(await record(from: session.ingest(url: url).result))
        #expect(retried.fields["title"] == .text("Hidden Falls"))
        #expect(stub.fetchCount == 2)
    }

    @Test
    func `Pinning past capacity resets the cache wholesale`() async throws {
        let capacity = ELVIngestSession.cacheCapacity
        let stub = try SessionStubFetcher(responses: ["trail.example": response(url: "https://trail.example/trail/any", html: trailHTML)])
        let session = try ELVIngestSession(pack: loadPack(trailPack), fetcher: stub)
        func url(_ index: Int) throws -> URL {
            try #require(URL(string: "https://trail.example/trail/t\(index)"))
        }

        for index in 1 ... capacity {
            _ = try await session.ingest(url: url(index)).result
        }
        #expect(stub.fetchCount == capacity)
        // Still within capacity: the first entry is a hit.
        _ = try await session.ingest(url: url(1)).result
        #expect(stub.fetchCount == capacity)

        // The pin past capacity wipes wholesale (session-lifetime bound):
        // the overflow entry survives, everything earlier refetches.
        _ = try await session.ingest(url: url(capacity + 1)).result
        #expect(stub.fetchCount == capacity + 1)
        _ = try await session.ingest(url: url(capacity + 1)).result
        #expect(stub.fetchCount == capacity + 1)
        _ = try await session.ingest(url: url(1)).result
        #expect(stub.fetchCount == capacity + 2)
    }

    @Test
    func `Reset clears the cache so the next ingest refetches`() async throws {
        let stub = try SessionStubFetcher(responses: ["trail.example": response(url: "https://trail.example/trail/hidden-falls", html: trailHTML)])
        let session = try ELVIngestSession(pack: loadPack(trailPack), fetcher: stub)
        let url = try #require(URL(string: "https://trail.example/trail/hidden-falls"))

        _ = await session.ingest(url: url).result
        _ = await session.ingest(url: url).result
        #expect(stub.fetchCount == 1)

        await session.reset()
        let refetched = try #require(await record(from: session.ingest(url: url).result))
        #expect(refetched.fields["title"] == .text("Hidden Falls"))
        #expect(stub.fetchCount == 2)
    }
}
