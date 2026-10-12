import Foundation
import Testing
@testable import EluviumCore

@Suite("Fetch-step URL preconditions")
struct ELVFetchPreconditionTests {
    private func load(_ json: String) throws -> ELVLoadedPack {
        try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: ["http"], binaryVersion: "0.1"))
    }

    @Test
    func `hostMatches and pathRegex decode with scalar leniency and make a trigger non-vacuous`() throws {
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "sources": [{
            "id": "pre.decode",
            "kind": "thing",
            "match": {"host": ["example.com"]},
            "fetch": {"mode": "composite", "steps": [
              {"mode": "http", "when": {"hostMatches": "movie.example.com", "pathRegex": "^/subject/"}},
              {"mode": "http", "when": {"hostMatches": ["music.example.com", "www.example.com"]}}
            ]},
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
          }]
        }
        """
        let loaded = try load(json)
        let steps = try #require(loaded.source(withId: "pre.decode")?.fetch?.resolvedSteps)
        let first = try #require(steps.first?.when)
        #expect(first.hostMatches == ["movie.example.com"])
        #expect(first.pathRegex == "^/subject/")
        #expect(!first.isVacuous)
        #expect(!first.hasResponseConditions)
        let second = try #require(steps.last?.when)
        #expect(second.hostMatches == ["music.example.com", "www.example.com"])
        // A pure URL gate is a live condition, not a dead trigger.
        #expect(!loaded.diagnostics.contains { $0.message.contains("never fires") })
    }

    @Test
    func `urlPermits uses exact-or-subdomain host semantics and ANDs the path regex`() throws {
        let host = ELVEscalationTrigger(hostMatches: ["douban.com"])
        #expect(try host.urlPermits(#require(URL(string: "https://movie.douban.com/subject/1"))))
        #expect(try host.urlPermits(#require(URL(string: "https://douban.com/game/1"))))
        #expect(try !host.urlPermits(#require(URL(string: "https://douban.com.evil.io/subject/1"))))
        #expect(try !host.urlPermits(#require(URL(string: "https://example.com/subject/1"))))

        let path = ELVEscalationTrigger(pathRegex: "^/game/")
        #expect(try path.urlPermits(#require(URL(string: "https://www.douban.com/game/1"))))
        #expect(try !path.urlPermits(#require(URL(string: "https://www.douban.com/subject/1"))))

        let both = ELVEscalationTrigger(hostMatches: ["www.douban.com"], pathRegex: "^/game/")
        #expect(try both.urlPermits(#require(URL(string: "https://www.douban.com/game/1"))))
        #expect(try !both.urlPermits(#require(URL(string: "https://movie.douban.com/game/1"))))

        // No URL keys means no URL gate: everything is admitted.
        let response = ELVEscalationTrigger(status: [403])
        #expect(try response.urlPermits(#require(URL(string: "https://anything.example/x"))))
        #expect(response.hasResponseConditions)
    }

    @Test
    func `The validator flags inert anyOf URL keys, bad path regexes, and empty host patterns`() throws {
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "sources": [{
            "id": "pre.lint",
            "kind": "thing",
            "match": {"host": ["example.com"]},
            "fetch": {"mode": "composite", "steps": [
              {"mode": "http"},
              {"mode": "http", "when": {"anyOf": [{"status": [403], "hostMatches": ["a.example.com"]}]}},
              {"mode": "http", "when": {"pathRegex": "("}},
              {"mode": "http", "when": {"hostMatches": [""]}}
            ]},
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
          }]
        }
        """
        let diagnostics = try load(json).diagnostics
        #expect(diagnostics.contains { $0.message.contains("inside anyOf are inert") })
        #expect(diagnostics.contains { $0.message.contains("pathRegex \"(\" does not compile") })
        #expect(diagnostics.contains { $0.message.contains("empty hostMatches pattern") })
    }

    @Test
    func `A trigger with no URL gate and no response condition is still dead`() throws {
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "sources": [{
            "id": "pre.dead",
            "kind": "thing",
            "match": {"host": ["example.com"]},
            "fetch": {"mode": "composite", "steps": [
              {"mode": "http"},
              {"mode": "http", "when": {}}
            ]},
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
          }]
        }
        """
        #expect(try load(json).diagnostics.contains { $0.message.contains("never fires") })
    }
}
