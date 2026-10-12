import Foundation
import Testing
@testable import EluviumCore

@Suite("Pack fragments")
struct ELVSourceFragmentTests {
    private func load(_ json: String, modes: Set<String> = ["http", "json"]) throws -> ELVLoadedPack {
        try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: modes, binaryVersion: "0.1"))
    }

    @Test
    func `A fragment fills an absent fetch plan and appends fields, merging same-name fields source-first`() throws {
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "fragments": {
            "httpLadder": {"fetch": {"mode": "composite", "steps": [
              {"mode": "http", "ua": "mobileSafari"},
              {"mode": "http", "ua": "crawler", "when": {"status": [403]}}
            ]}},
            "og": {"fields": [
              {"name": "title", "candidates": [{"from": {"meta": "og:title"}}]},
              {"name": "image", "candidates": [{"from": {"meta": "og:image"}, "as": "image"}]}
            ]}
          },
          "sources": [{
            "id": "frag.user",
            "kind": "thing",
            "match": {"host": ["example.com"], "path": "/x/:id"},
            "use": ["httpLadder", "og"],
            "fields": [
              {"name": "externalId", "candidates": [{"from": {"urlParam": "id"}}]},
              {"name": "title", "candidates": [{"from": {"jsonld": "Thing.name"}}]}
            ]
          }]
        }
        """
        let loaded = try load(json)
        let source = try #require(loaded.source(withId: "frag.user"))
        #expect(source.fetch?.resolvedSteps.map(\.ua) == ["mobileSafari", "crawler"])
        #expect(source.fields.map(\.name) == ["externalId", "title", "image"])
        // The source's own candidate outranks the shared ladder: first
        // winning candidate is the extractor's contract, so order IS override.
        let title = try #require(source.fields.first(where: { $0.name == "title" }))
        #expect(title.candidates.map(\.from) == [.jsonld("Thing.name"), .meta("og:title")])
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test
    func `A source's own fetch plan wins over the fragment's`() throws {
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "fragments": {"httpLadder": {"fetch": {"mode": "http", "ua": "crawler"}}},
          "sources": [{
            "id": "frag.ownFetch",
            "kind": "thing",
            "match": {"host": ["example.com"]},
            "use": ["httpLadder"],
            "fetch": {"mode": "json"},
            "fields": [{"name": "title", "candidates": [{"from": {"json": "$.name"}}]}]
          }]
        }
        """
        let source = try #require(load(json).source(withId: "frag.ownFetch"))
        #expect(source.fetch?.mode == "json")
    }

    @Test
    func `An unknown fragment name resolves to nothing and the validator flags it`() throws {
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "fragments": {"real": {"fetch": {"mode": "http"}}},
          "sources": [{
            "id": "frag.dangling",
            "kind": "thing",
            "match": {"host": ["example.com"]},
            "use": ["real", "missing"],
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
          }]
        }
        """
        let loaded = try load(json)
        let source = try #require(loaded.source(withId: "frag.dangling"))
        #expect(source.fetch?.mode == "http")
        #expect(source.fields.map(\.name) == ["title"])
        #expect(loaded.diagnostics.contains { $0.message.contains("use references fragment \"missing\"") })
    }

    @Test
    func `Unused and empty fragments are surfaced as diagnostics`() throws {
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "fragments": {
            "dead": {"fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]},
            "hollow": {}
          },
          "sources": [{
            "id": "frag.none",
            "kind": "thing",
            "match": {"host": ["example.com"]},
            "fetch": {"mode": "http"},
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
          }]
        }
        """
        let diagnostics = try load(json).diagnostics
        #expect(diagnostics.contains { $0.message.contains("fragment \"dead\" is declared but no source uses it") })
        #expect(diagnostics.contains { $0.message.contains("fragment \"hollow\" declares no fetch and no fields") })
    }

    @Test
    func `A structurally broken fragments block costs the fragments, never the pack`() throws {
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "fragments": ["not", "an", "object"],
          "sources": [{
            "id": "frag.survivor",
            "kind": "thing",
            "match": {"host": ["example.com"]},
            "fetch": {"mode": "http"},
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}],
            "use": ["anything"]
          }]
        }
        """
        let loaded = try load(json)
        #expect(loaded.source(withId: "frag.survivor") != nil)
        #expect(loaded.pack.fragments.isEmpty)
        #expect(loaded.diagnostics.contains { $0.message.contains("fragments dropped") })
    }

    @Test
    func `A fragment-supplied fetch plan counts toward capability gating`() throws {
        // Resolution runs before the gate, so a source riding a dom fragment
        // is skipped by a binary without a renderer instead of half-working.
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "fragments": {"domLadder": {"fetch": {"mode": "dom"}}},
          "sources": [{
            "id": "frag.needsDom",
            "kind": "thing",
            "match": {"host": ["example.com"]},
            "use": ["domLadder"],
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
          }]
        }
        """
        let loaded = try load(json, modes: ["http"])
        #expect(loaded.skipped.map(\.id) == ["frag.needsDom"])
    }
}
