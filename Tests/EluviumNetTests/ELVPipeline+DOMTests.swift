import EluviumCatalog
import EluviumCore
import Foundation
import Synchronization
import Testing
@testable import EluviumNet

/// A stub DOM renderer that records the request it was handed and returns a
/// canned settled result — proving the pipeline compiles the right CSS
/// queries and consumes the result, without a real WebKit render.
private final class StubDOMRenderer: ELVDOMRendering, @unchecked Sendable {
    let result: ELVDOMResult
    private let lastRequestBox = Mutex<ELVDOMRequest?>(nil)

    init(result: ELVDOMResult) {
        self.result = result
    }

    var lastRequest: ELVDOMRequest? { lastRequestBox.withLock { $0 } }

    func render(_ request: ELVDOMRequest) async throws -> ELVDOMResult {
        lastRequestBox.withLock { $0 = request }
        return result
    }
}

private struct FailingHTTPFetcher: ELVFetching {
    func fetch(_: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
        throw ELVFetchFailure.blocked(status: 403)
    }
}

@Suite("DOM pipeline")
struct ELVPipelineDOMTests {
    private let domPackJSON = """
    {
      "schemaVersion": 1, "packVersion": "test",
      "sources": [{
        "id": "alltrails.trail",
        "kind": "trail",
        "match": {"host": ["alltrails.com"], "path": "/trail/:country/:region/:slug", "priority": 100},
        "fetch": {"mode": "dom", "ua": "desktopSafari", "settle": {"signals": ["h1", "jsonld"]}},
        "requires": ["fetch:dom"],
        "fields": [
          {"name": "externalId", "candidates": [{"from": {"urlParam": "slug"}}]},
          {"name": "title", "candidates": [
            {"from": {"css": "h1"}, "pipe": ["trim"]},
            {"from": {"meta": "og:title"}}
          ]},
          {"name": "difficulty", "candidates": [{"from": {"css": ".difficulty", "attr": "text"}}]}
        ]
      }]
    }
    """

    private func loadDOMPack() throws -> ELVLoadedPack {
        try ELVPackLoader.load(embedded: Data(domPackJSON.utf8), capabilities: ELVCapabilities(fetchModes: ["http", "json", "dom"], binaryVersion: "0.1"))
    }

    @Test
    func `A dom source renders through the injected engine, extracting CSS and HTML`() async throws {
        let html = "<html><head><title>t</title></head><body><h1>Hidden Falls Trail</h1></body></html>"
        let renderer = try StubDOMRenderer(result: ELVDOMResult(
            finalURL: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")),
            html: html,
            cssResults: ["h1": "Hidden Falls Trail", ".difficulty": "Moderate"],
            settled: true
        ))
        let pipeline = try ELVPipeline(pack: loadDOMPack(), fetcher: FailingHTTPFetcher(), domRenderer: renderer)
        let result = try await pipeline.run(url: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))).result

        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.fields["title"] == .text("Hidden Falls Trail"))
        #expect(record.fields["difficulty"] == .text("Moderate"))
        #expect(record.externalId == "hidden-falls-trail")

        // The pipeline compiled exactly the source's CSS queries into the
        // request; the key carries the attr so `.difficulty` with attr "text"
        // becomes `.difficulty@text`.
        let requested = renderer.lastRequest?.css.map(\.key).sorted()
        #expect(requested == [".difficulty@text", "h1"])
        #expect(renderer.lastRequest?.settle.signals == ["h1", "jsonld"])
        #expect(renderer.lastRequest?.userAgent.contains("Macintosh") == true)
    }

    @Test
    func `Without an injected renderer, a dom-only source is unreachable (recognized but no runnable step)`() async throws {
        // Load with dom capability so the source stays active, but inject no
        // renderer: the dom step can't run, so the pipeline reports failure
        // rather than a bare record.
        let pipeline = try ELVPipeline(pack: loadDOMPack(), fetcher: FailingHTTPFetcher(), domRenderer: nil)
        let result = try await pipeline.run(url: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))).result
        guard case let .failed(failure, _) = result else {
            Issue.record("Expected .failed with no renderer, got \(result)")
            return
        }
        // The skipped step is named, not collapsed to a bare httpError(-1).
        #expect(failure == .formatDrift("no runnable fetch step (modes: dom)"))
    }

    @Test
    func `A settled-but-empty render (challenge shell) surfaces as blocked, not an empty record`() async throws {
        let renderer = try StubDOMRenderer(result: ELVDOMResult(
            finalURL: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")),
            html: "",
            cssResults: [:],
            settled: true
        ))
        let pipeline = try ELVPipeline(pack: loadDOMPack(), fetcher: FailingHTTPFetcher(), domRenderer: renderer)
        let result = try await pipeline.run(url: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))).result
        guard case let .failed(failure, _) = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
        #expect(failure == .blocked(status: 200))
    }

    @Test
    func `A composite http→dom source escalates to dom on an empty http record`() async throws {
        let compositeJSON = """
        {
          "schemaVersion": 1, "packVersion": "test",
          "sources": [{
            "id": "chewy.product",
            "kind": "product",
            "match": {"host": ["chewy.com"], "path": "/dp/:id", "priority": 100},
            "fetch": {"mode": "composite", "steps": [
              {"mode": "http", "ua": "mobileSafari"},
              {"mode": "dom", "ua": "desktopSafari", "when": {"emptyRecord": true}}
            ]},
            "requires": ["fetch:dom"],
            "fields": [
              {"name": "title", "candidates": [{"from": {"css": "h1"}}, {"from": {"meta": "og:title"}}]}
            ]
          }]
        }
        """
        // http returns a challenge shell (empty), dom returns the real title.
        struct ShellFetcher: ELVFetching {
            func fetch(_ url: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
                ELVFetchResponse(finalURL: url, status: 200, data: Data("<html></html>".utf8), bodyText: "<html></html>", truncated: false)
            }
        }
        let renderer = try StubDOMRenderer(result: ELVDOMResult(
            finalURL: #require(URL(string: "https://www.chewy.com/dp/54767")),
            html: "<h1>Prescription Diet</h1>",
            cssResults: ["h1": "Prescription Diet"],
            settled: true
        ))
        let pack = try ELVPackLoader.load(embedded: Data(compositeJSON.utf8), capabilities: ELVCapabilities(fetchModes: ["http", "dom"], binaryVersion: "0.1"))
        let pipeline = ELVPipeline(pack: pack, fetcher: ShellFetcher(), domRenderer: renderer)
        let result = try await pipeline.run(url: #require(URL(string: "https://www.chewy.com/dp/54767"))).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.fields["title"] == .text("Prescription Diet"))
        #expect(renderer.lastRequest != nil) // dom step actually ran
    }

    @Test
    func `A settled render whose final evaluate failed reports the evaluate error, not a bot wall`() async throws {
        let renderer = try StubDOMRenderer(result: ELVDOMResult(
            finalURL: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")),
            html: "",
            cssResults: [:],
            settled: true,
            extractionError: "evaluate timed out"
        ))
        let pipeline = try ELVPipeline(pack: loadDOMPack(), fetcher: FailingHTTPFetcher(), domRenderer: renderer)

        let run = try await pipeline.run(url: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")))

        guard case let .failed(failure, sourceId) = run.result else {
            Issue.record("Expected a failure, got \(run.result)")
            return
        }
        #expect(failure == .formatDrift("final evaluate failed: evaluate timed out"))
        #expect(sourceId == "alltrails.trail")
        let step = try #require(run.trace.steps.first)
        #expect(step.outcome == .failed(.formatDrift("final evaluate failed: evaluate timed out")))
        #expect(step.settled == true)
        #expect(step.bytes == 0)
        #expect(step.notes == ["final evaluate failed: evaluate timed out"])

        // The same empty render with an evaluate that ran is still the
        // challenge-shell case.
        let shell = try StubDOMRenderer(result: ELVDOMResult(
            finalURL: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")),
            html: "",
            cssResults: [:],
            settled: true
        ))
        let shellRun = try await ELVPipeline(pack: loadDOMPack(), fetcher: FailingHTTPFetcher(), domRenderer: shell)
            .run(url: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")))
        guard case let .failed(shellFailure, _) = shellRun.result else {
            Issue.record("Expected a failure, got \(shellRun.result)")
            return
        }
        #expect(shellFailure == .blocked(status: 200))
        #expect(shellRun.trace.steps.first?.settled == true)
    }

    @Test
    func `An unsettled render that yields nothing fails with the load error instead of an empty record`() async throws {
        let renderer = try StubDOMRenderer(result: ELVDOMResult(
            finalURL: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")),
            html: "",
            cssResults: [:],
            settled: false,
            loadError: "NSURLErrorDomain -1003",
            extractionError: "evaluate timed out"
        ))
        // Without the URL-derived externalId, nothing can fill the record.
        let urlFreeJSON = domPackJSON.replacingOccurrences(of: #"{"name": "externalId", "candidates": [{"from": {"urlParam": "slug"}}]},"#, with: "")
        let pack = try ELVPackLoader.load(embedded: Data(urlFreeJSON.utf8), capabilities: ELVCapabilities(fetchModes: ["http", "json", "dom"], binaryVersion: "0.1"))
        let pipeline = ELVPipeline(pack: pack, fetcher: FailingHTTPFetcher(), domRenderer: renderer)

        let run = try await pipeline.run(url: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")))

        guard case let .failed(failure, sourceId) = run.result else {
            Issue.record("Expected a failure, got \(run.result)")
            return
        }
        #expect(failure == .formatDrift("render did not settle; load failed: NSURLErrorDomain -1003; final evaluate failed: evaluate timed out"))
        #expect(sourceId == "alltrails.trail")
        let step = try #require(run.trace.steps.first)
        #expect(step.settled == false)
        #expect(step.notes == ["load failed: NSURLErrorDomain -1003", "final evaluate failed: evaluate timed out"])
    }

    @Test
    func `An unsettled render that still extracted keeps its record, with settled false in the trace`() async throws {
        let html = "<html><head><title>t</title></head><body><h1>Hidden Falls Trail</h1></body></html>"
        let renderer = try StubDOMRenderer(result: ELVDOMResult(
            finalURL: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")),
            html: html,
            cssResults: ["h1": "Hidden Falls Trail"],
            settled: false
        ))
        let pipeline = try ELVPipeline(pack: loadDOMPack(), fetcher: FailingHTTPFetcher(), domRenderer: renderer)

        let run = try await pipeline.run(url: #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail")))

        #expect(run.record?.fields["title"] == .text("Hidden Falls Trail"))
        let step = try #require(run.trace.steps.first)
        #expect(step.mode == "dom")
        #expect(step.settled == false)
        #expect(step.bytes == html.utf8.count)
        #expect(run.trace.isDegraded)
        #expect(run.trace.fieldMisses.map(\.field) == ["difficulty"])
    }
}

/// The canonical-URL capture flow over the REAL starter pack: the iOS
/// Google Maps `?q=` share (coordinate-less everywhere a fetch can see)
/// captures the client-side rewrite and re-enters recognition at
/// gmaps.place, which owns the `!3d!4d` pin.
@Suite("Canonical capture pipeline")
struct ELVCanonicalCapturePipelineTests {
    private func starterPipeline(renderer: StubDOMRenderer) throws -> ELVPipeline {
        let pack = try ELVPackLoader.load(
            embedded: ELVStarterPack.data,
            capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1")
        )
        // gmaps.share renders through the stub and gmaps.place is
        // URL-only (`none`), so the HTTP fetcher must never fire.
        return ELVPipeline(pack: pack, fetcher: FailingHTTPFetcher(), domRenderer: renderer)
    }

    @Test
    func `A coordinate-less ?q= share captures the canonical URL and re-enters recognition at gmaps.place`() async throws {
        let canonical = try #require(URL(
            string: "https://www.google.com/maps/place/Grand+Prismatic+Spring+Overlook/@44.5251,-110.8382,17z/data=!8m2!3d44.5251!4d-110.8382"
        ))
        // Mid-rewrite pages are legitimately empty: the capture alone drives
        // the outcome, never the shell's contents.
        let renderer = StubDOMRenderer(result: ELVDOMResult(
            finalURL: canonical, html: "", cssResults: [:], settled: false, canonicalURL: canonical
        ))
        let pipeline = try starterPipeline(renderer: renderer)
        let share = try #require(URL(string: "https://maps.google.com/?q=Grand+Prismatic+Spring+Overlook,+Yellowstone+National+Park,+WY"))
        let result = await pipeline.run(url: share).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        // The final record is gmaps.place's: the iOS share became the
        // desktop share, pin included.
        #expect(record.sourceId == "gmaps.place")
        #expect(record.fields["title"] == .text("Grand Prismatic Spring Overlook"))
        #expect(record.fields["geo"] == .geo(latitude: 44.5251, longitude: -110.8382))
        #expect(record.sourceURL == canonical)
        #expect(record.provenance["captureCanonical"] == nil)
        // The dom request carried the pack-declared capture predicate.
        #expect(renderer.lastRequest?.captureCanonical?.untilURLRegex.contains("!3d") == true)
    }

    @Test
    func `A captured canonical that maps back to a capturing source fails instead of looping`() async throws {
        let loop = try #require(URL(string: "https://maps.google.com/?q=Second+Place"))
        let renderer = StubDOMRenderer(result: ELVDOMResult(
            finalURL: loop, html: "", cssResults: [:], settled: false, canonicalURL: loop
        ))
        let pipeline = try starterPipeline(renderer: renderer)
        let result = try await pipeline.run(url: #require(URL(string: "https://maps.google.com/?q=First+Place"))).result
        guard case let .failed(failure, sourceId) = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
        #expect(failure == .formatDrift("canonical capture landed on a capturing source (loop)"))
        #expect(sourceId == "gmaps.share")
    }

    @Test
    func `A capture timeout falls through to the ?q= extraction with a diagnostic`() async throws {
        let share = try #require(URL(string: "https://maps.google.com/?q=Grand+Prismatic+Spring+Overlook,+Yellowstone+National+Park,+WY&ftid=0x5351eb:0"))
        // The render landed somewhere that never rewrote to /maps/place/…:
        // no canonical, just the shell.
        let renderer = StubDOMRenderer(result: ELVDOMResult(
            finalURL: share, html: "<html><body><div>maps shell</div></body></html>", cssResults: [:], settled: false, canonicalURL: nil
        ))
        let pipeline = try starterPipeline(renderer: renderer)
        let result = await pipeline.run(url: share).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        // The step's own URL extraction still lands name + locality + ftid —
        // and no pin (skip beats wrong).
        #expect(record.sourceId == "gmaps.share")
        #expect(record.fields["title"] == .text("Grand Prismatic Spring Overlook"))
        #expect(record.fields["locality"] == .text("Yellowstone National Park, WY"))
        #expect(record.fields["geo"] == nil)
        #expect(record.externalId == "0x5351eb:0")
        // The miss is diagnosable from the record alone.
        #expect(record.provenance["captureCanonical"]?.origin.contains("timed out") == true)
    }
}
