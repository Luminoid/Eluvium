import EluviumCore
import Foundation
import Synchronization
import Testing
@testable import EluviumNet

/// A counting fetcher that answers every URL with one page.
private final class PastePageFetcher: ELVFetching, @unchecked Sendable {
    private let html: String
    private let count = Mutex(0)

    init(html: String) {
        self.html = html
    }

    var fetchCount: Int { count.withLock { $0 } }

    func fetch(_ url: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
        count.withLock { $0 += 1 }
        return ELVFetchResponse(finalURL: url, status: 200, data: Data(html.utf8), bodyText: html, truncated: false)
    }
}

@Suite("Pasted input through the pipeline")
struct ELVPipelinePasteTests {
    /// The AllTrails shape: the page's name, then the share name, then the
    /// slug; stats prefer the blurb. The redirector lands on it, so the
    /// paste must survive the chase.
    private let packJSON = """
    {
      "schemaVersion": 1, "schemaMinor": 5, "packVersion": "paste-test",
      "sources": [
        {
          "id": "shortlinks.travel", "kind": "link",
          "match": {"host": ["yelp.to"], "path": "/**", "priority": 90},
          "resolvesVia": "shortlink.expand"
        },
        {
          "id": "test.trail", "title": "AllTrails", "kind": "trail",
          "match": {"host": ["alltrails.com"], "path": "/trail/:country/:region/:slug", "priority": 100},
          "fetch": {"mode": "http"},
          "fields": [
            {"name": "title", "candidates": [
              {"from": {"meta": "og:title"}},
              {"from": {"paste": "label"}},
              {"from": {"urlParam": "slug"}, "pipe": ["slugToTitle"]}
            ]},
            {"name": "distance", "candidates": [
              {"from": {"native": "trail.statsFromText@2", "input": {"text": "$paste.text"}}, "select": "distance"},
              {"from": {"native": "trail.statsFromText@2"}, "select": "distance"}
            ]}
          ],
          "label": ["title"]
        }
      ]
    }
    """

    private func pipeline(html: String) throws -> (ELVPipeline, PastePageFetcher) {
        ELVStubChase.register()
        let pack = try ELVPackLoader.load(embedded: Data(packJSON.utf8), capabilities: ELVCapabilities(fetchModes: ["http"], binaryVersion: ELVBinary.version))
        let fetcher = PastePageFetcher(html: html)
        return (ELVPipeline(pack: pack, fetcher: fetcher), fetcher)
    }

    @Test
    func `the share name and blurb stats survive a redirect chase`() async throws {
        let (pipeline, _) = try pipeline(html: "<html><head></head><body>No metas here</body></html>")
        let input = try #require(ELVPastedInput.parse("Moderate · 5.1 mi\nHidden Falls on AllTrails https://yelp.to/to-alltrails"))
        let run = await pipeline.run(input: input)
        let record = try #require(run.record)
        #expect(record.sourceId == "test.trail")
        #expect(record.fields["label"] == .text("Hidden Falls"))
        #expect(record.fields["distance"] == .text("5.1 mi"))
    }

    @Test
    func `the page name outranks the share name once fetched`() async throws {
        let (pipeline, _) = try pipeline(html: #"<html><head><meta property="og:title" content="Hidden Falls via Jenny Lake"></head></html>"#)
        let input = try #require(ELVPastedInput.parse("Hidden Falls on AllTrails https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))
        let record = try #require(await pipeline.run(input: input).record)
        #expect(record.fields["label"] == .text("Hidden Falls via Jenny Lake"))
        #expect(record.provenance["label"]?.origin == "label:title")
    }

    @Test
    func `a typed label outranks the page`() async throws {
        let (pipeline, _) = try pipeline(html: #"<html><head><meta property="og:title" content="Hidden Falls via Jenny Lake"></head></html>"#)
        let input = try #require(ELVPastedInput.parse("https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))
        let record = try #require(await pipeline.run(input: input, userLabel: "Day 2 hike").record)
        #expect(record.fields["label"] == .text("Day 2 hike"))
    }

    @Test
    func `the session keys a paste by its blurb as well as its link`() async throws {
        ELVStubChase.register()
        let pack = try ELVPackLoader.load(embedded: Data(packJSON.utf8), capabilities: ELVCapabilities(fetchModes: ["http"], binaryVersion: ELVBinary.version))
        let fetcher = PastePageFetcher(html: "<html><head></head><body></body></html>")
        let session = ELVIngestSession(pack: pack, fetcher: fetcher)
        let link = "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"
        let bare = try #require(ELVPastedInput.parse(link))
        let shared = try #require(ELVPastedInput.parse("5.1 mi\nHidden Falls on AllTrails \(link)"))

        _ = await session.ingest(input: bare)
        let again = await session.ingest(input: bare)
        #expect(again.trace.servedFromCache)
        let blurbRun = await session.ingest(input: shared)
        #expect(!blurbRun.trace.servedFromCache)
        #expect(blurbRun.record?.fields["distance"] == .text("5.1 mi"))
        #expect(fetcher.fetchCount == 2)
        // The preview is the same pack's offline reading.
        #expect(session.preview(input: shared).record.fields["label"] == .text("Hidden Falls"))
    }

    @Test
    func `completeOnly refuses to pin a run whose platform lookup threw`() async throws {
        let json = """
        {
          "schemaVersion": 1, "schemaMinor": 5, "packVersion": "pin-test",
          "sources": [{
            "id": "test.lookup", "kind": "place",
            "match": {"host": ["lookup.test"], "path": "/:name", "priority": 100},
            "fetch": {"mode": "none"},
            "fields": [
              {"name": "title", "candidates": [{"from": {"urlParam": "name"}}]},
              {"name": "geo", "candidates": [{"from": {"native": "test.failingLookup@1", "input": {"name": "$field.title"}}}]}
            ]
          }]
        }
        """
        struct LookupDown: Error {}
        ELVNativeOps.registerAsync("test.failingLookup", version: 1) { _, _ in throw LookupDown() }
        let pack = try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: [], binaryVersion: ELVBinary.version))
        let url = try #require(URL(string: "https://lookup.test/benu"))

        let lenient = ELVIngestSession(pack: pack, fetcher: PastePageFetcher(html: ""))
        _ = await lenient.ingest(url: url)
        #expect(await lenient.ingest(url: url).trace.servedFromCache)

        let strict = ELVIngestSession(pack: pack, fetcher: PastePageFetcher(html: ""), pinPolicy: .completeOnly)
        let first = await strict.ingest(url: url)
        #expect(first.record?.fields["title"] == .text("benu"))
        #expect(!first.trace.nativeOpFailures.isEmpty)
        #expect(await strict.ingest(url: url).trace.servedFromCache == false)
    }
}
