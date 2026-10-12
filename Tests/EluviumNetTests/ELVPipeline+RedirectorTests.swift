import EluviumCatalog
import EluviumCore
import Foundation
import Testing
@testable import EluviumNet

@Suite("Redirector pipeline")
struct ELVPipelineRedirectorTests {
    private let packJSON = """
    {
      "schemaVersion": 1, "packVersion": "test",
      "sources": [
        {
          "id": "shortlinks.travel",
          "kind": "link",
          "match": {"host": ["maps.app.goo.gl", "yelp.to"], "path": "/**", "priority": 90},
          "resolvesVia": "shortlink.expand",
          "requires": ["native:shortlink.expand"]
        },
        {
          "id": "pokeapi.pokemon",
          "kind": "creature",
          "match": {"host": ["pokeapi.co"], "path": "/api/v2/pokemon/:id", "priority": 100},
          "fetch": {"mode": "json"},
          "fields": [
            {"name": "externalId", "candidates": [{"from": {"urlParam": "id"}}]},
            {"name": "title", "candidates": [{"from": {"json": "$.name"}}]}
          ]
        }
      ]
    }
    """

    private struct JSONFetcher: ELVFetching {
        func fetch(_ url: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
            let body = #"{"name": "pikachu"}"#
            return ELVFetchResponse(finalURL: url, status: 200, data: Data(body.utf8), bodyText: body, truncated: false)
        }
    }

    private func makePipeline() throws -> ELVPipeline {
        ELVStubChase.register()
        let pack = try ELVPackLoader.load(embedded: Data(packJSON.utf8), capabilities: ELVCapabilities(fetchModes: ["http", "json"], binaryVersion: "0.1"))
        return ELVPipeline(pack: pack, fetcher: JSONFetcher())
    }

    @Test
    func `A short link expands and re-enters recognition at the real source`() async throws {
        let pipeline = try makePipeline()
        let short = try #require(URL(string: "https://maps.app.goo.gl/to-pokeapi"))
        let result = await pipeline.run(url: short).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.sourceId == "pokeapi.pokemon")
        #expect(record.externalId == "25")
        #expect(record.fields["title"] == .text("pikachu"))
    }

    @Test
    func `A chase landing on another redirector fails instead of looping`() async throws {
        let pipeline = try makePipeline()
        let short = try #require(URL(string: "https://maps.app.goo.gl/to-redirector"))
        let result = await pipeline.run(url: short).result
        guard case let .failed(failure, _) = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
        #expect(failure == .formatDrift("chase landed on another redirector (loop)"))
    }

    @Test
    func `A failed chase surfaces as a typed failure, not a bare record`() async throws {
        let pipeline = try makePipeline()
        let short = try #require(URL(string: "https://maps.app.goo.gl/to-nowhere"))
        let result = await pipeline.run(url: short).result
        guard case .failed = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
    }

    @Test
    func `A dead short link surfaces the chain's HTTP error and the redirector's id, not a bare -1`() async throws {
        let pipeline = try makePipeline()
        let short = try #require(URL(string: "https://maps.app.goo.gl/to-dead"))
        let result = await pipeline.run(url: short).result
        guard case let .failed(failure, sourceId) = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
        #expect(failure == .httpError(status: 404))
        #expect(sourceId == "shortlinks.travel")
    }

    @Test
    func `A redirector chase is traced as its own step before the real source's`() async throws {
        let pipeline = try makePipeline()
        let short = try #require(URL(string: "https://maps.app.goo.gl/to-pokeapi"))

        let run = await pipeline.run(url: short)

        #expect(run.record?.sourceId == "pokeapi.pokemon")
        #expect(run.trace.inputHost == "maps.app.goo.gl")
        #expect(run.trace.sourceIds == ["shortlinks.travel", "pokeapi.pokemon"])
        #expect(run.trace.steps.map(\.mode) == ["native", "json"])
        #expect(run.trace.steps.map(\.outcome) == [.redirected, .produced])
        #expect(run.trace.steps.first?.host == "maps.app.goo.gl")
        #expect(run.trace.steps.last?.host == "pokeapi.co")
    }
}

@Suite("URL-shaped sources")
struct ELVNoneFetchTests {
    /// Proves `"mode": "none"` never touches the network: this fetcher
    /// fails the test if called.
    private struct TrappingFetcher: ELVFetching {
        func fetch(_: URL, persona _: ELVUAPersona, referer _: URL?, accept _: String?, budget _: ELVFetchBudget) async throws -> ELVFetchResponse {
            Issue.record("A none-mode source must not fetch")
            throw ELVFetchFailure.formatDrift("none-mode source fetched")
        }
    }

    @Test
    func `The gmaps place source extracts a record from the URL alone`() async throws {
        ELVStubChase.register()
        let pack = try ELVPackLoader.load(embedded: Data(ELVStarterPack.json.utf8), capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed"], binaryVersion: "0.1"))
        let pipeline = ELVPipeline(pack: pack, fetcher: TrappingFetcher())

        let pinned = try #require(URL(string: "https://www.google.com/maps/place/Jenny+Lake/@43.7904,-110.7624,15z/data=!8m2!3d43.7911!4d-110.7622"))
        let result = await pipeline.run(url: pinned).result
        guard case let .record(record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(record.sourceId == "gmaps.place")
        #expect(record.fields["title"] == .text("Jenny Lake"))
        #expect(record.fields["geo"] == .geo(latitude: 43.7911, longitude: -110.7622))
        #expect(record.fields["viewport"] == .geo(latitude: 43.7904, longitude: -110.7624))

        // The `?q=` share form: name + locality, viewport-only never pins.
        let query = try #require(URL(string: "https://maps.google.com/maps?q=Grand+Prismatic+Spring+Overlook,+Yellowstone+National+Park,+WY&ftid=0x5351eb:0"))
        let queryResult = await pipeline.run(url: query).result
        guard case let .record(queryRecord) = queryResult else {
            Issue.record("Expected a record, got \(queryResult)")
            return
        }
        #expect(queryRecord.fields["title"] == .text("Grand Prismatic Spring Overlook"))
        #expect(queryRecord.fields["locality"] == .text("Yellowstone National Park, WY"))
        #expect(queryRecord.fields["geo"] == nil)
        #expect(queryRecord.externalId == "0x5351eb:0")
    }
}
