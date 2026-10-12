import Foundation
import Testing
@testable import EluviumCore

@Suite("Pack grammar robustness")
struct ELVPackGrammarTests {
    private func load(_ json: String, modes: Set<String> = ["http", "json"]) throws -> ELVLoadedPack {
        try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: modes, binaryVersion: "0.1"))
    }

    @Test
    func `Scalar shorthands decode as one-element lists everywhere they are unambiguous`() throws {
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "sources": [{
            "id": "scalar.example",
            "kind": "thing",
            "match": {"host": "example.com", "path": "/x/:id", "priority": 10},
            "canonicalize": {"strip": "utm_*"},
            "requires": "native:text.digits@1",
            "fetch": {"mode": "composite", "steps": [
              {"mode": "json"},
              {"mode": "json", "ua": "crawler", "when": {"status": 403, "missingAny": "title"}}
            ]},
            "fields": [
              {"name": "title", "candidates": [{"from": {"json": "$.name"}, "pipe": ["trim"]}]}
            ],
            "examples": [{"input": "https://example.com/x/1", "expect": {"kind": "thing", "nonEmpty": "title"}}]
          }]
        }
        """
        let loaded = try load(json, modes: ["json"])
        let source = try #require(loaded.source(withId: "scalar.example"))
        #expect(source.match?.hosts == ["example.com"])
        #expect(source.canonicalize?.strip == ["utm_*"])
        #expect(source.requires == ["native:text.digits@1"])
        let when = try #require(source.fetch?.resolvedSteps.last?.when)
        #expect(when.status == [403])
        #expect(when.missingAny == ["title"])
        #expect(source.fields.first?.candidates.first?.pipes == [.trim])
        #expect(source.examples.first?.expectedNonEmpty == ["title"])
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test
    func `A bare pipe string is one unsupported pipe that invalidates only its candidate`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [{
          "id": "bare.pipe", "kind": "thing",
          "match": {"host": ["example.com"]},
          "fetch": {"mode": "json"},
          "fields": [{"name": "title", "candidates": [
            {"from": {"json": "$.name"}, "pipe": "trim"},
            {"from": {"json": "$.name"}, "pipe": ["trim"]}
          ]}]
        }]}
        """
        let loaded = try load(json, modes: ["json"])
        let source = try #require(loaded.source(withId: "bare.pipe"))
        #expect(source.fields[0].candidates[0].pipes == [.unsupported(name: "(malformed)")])
        #expect(source.fields[0].candidates[1].pipes == [.trim])
        #expect(loaded.diagnostics.map(\.description).contains { $0.contains("unsupported pipe \"(malformed)\"") })
        let body = try #require(ELVRawJSON.parse(Data(#"{"name": " Survivor "}"#.utf8)))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(document: ELVDocument(json: body)))
        #expect(record.fields["title"] == .text("Survivor"))
    }

    @Test
    func `regexReplace takes the pair spelling only; the object form is an unsupported pipe`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [{
          "id": "regex.example", "kind": "thing",
          "match": {"host": ["example.com"]},
          "fetch": {"mode": "json"},
          "fields": [
            {"name": "a", "candidates": [{"from": {"json": "$.a"}, "pipe": [{"regexReplace": ["a(b)", "$1"]}]}]},
            {"name": "b", "candidates": [{"from": {"json": "$.b"}, "pipe": [{"regexReplace": {"pattern": "a(b)", "template": "$1"}}]}]}
          ]
        }]}
        """
        let loaded = try load(json, modes: ["json"])
        let source = try #require(loaded.source(withId: "regex.example"))
        #expect(source.fields[0].candidates[0].pipes == [.regexReplace(pattern: "a(b)", template: "$1")])
        #expect(source.fields[1].candidates[0].pipes == [.unsupported(name: "regexReplace")])
        #expect(loaded.diagnostics.map(\.description).contains { $0.contains("field \"b\": unsupported pipe \"regexReplace\"") })
    }

    @Test
    func `A malformed selector invalidates only its candidate; the field falls through`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [{
          "id": "degrade.example", "kind": "thing",
          "match": {"host": ["example.com"], "path": "/x/:id"},
          "fetch": {"mode": "json"},
          "fields": [
            {"name": "title", "candidates": [
              {"from": {"css": "h1", "json": "$.wrong"}},
              {"from": "just-a-string"},
              {"from": {"json": 42}},
              {"from": {"json": "$.name"}}
            ]}
          ]
        }]}
        """
        let loaded = try load(json, modes: ["json"])
        let source = try #require(loaded.source(withId: "degrade.example"))
        let body = try #require(ELVRawJSON.parse(Data(#"{"name": "Survivor"}"#.utf8)))
        let url = try #require(URL(string: "https://example.com/x/7"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument(json: body)))
        #expect(record.fields["title"] == .text("Survivor"))
        // Each malformed candidate is reported, none is fatal.
        let messages = loaded.diagnostics.map(\.description)
        #expect(messages.count(where: { $0.contains("unsupported selector") }) == 3)
    }

    @Test
    func `A structurally broken source drops with a note; the rest of the pack loads`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [
          {"id": "good.source", "kind": "thing", "match": {"host": ["good.example"]}, "fetch": {"mode": "json"}},
          {"kind": "thing", "match": {"host": ["no-id.example"]}},
          "not even an object",
          {"id": "broken.fetch", "kind": "thing", "fetch": "not-an-object"}
        ]}
        """
        let loaded = try load(json, modes: ["json"])
        #expect(loaded.pack.sources.map(\.id) == ["good.source"])
        let issues = loaded.pack.decodeIssues
        #expect(issues.count == 3)
        #expect(issues[0].contains("sources[1]"))
        #expect(issues[0].contains("missing key \"id\""))
        #expect(issues[2].contains("(id \"broken.fetch\")"))
        // Decode notes surface as pack-level diagnostics.
        #expect(loaded.diagnostics.count(where: { $0.sourceId == nil }) == 3)
    }

    @Test
    func `Duplicate source ids reject the pack whole`() {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [
          {"id": "dup.example", "kind": "thing", "match": {"host": ["a.example"]}},
          {"id": "dup.example", "kind": "thing", "match": {"host": ["b.example"]}}
        ]}
        """
        #expect(throws: ELVPackError.duplicateSourceId("dup.example")) {
            _ = try load(json)
        }
    }

    @Test
    func `Typed cursors keep their forms, the bare-selector shorthand is nextURL, and everything else degrades to single-page`() throws {
        let decoder = JSONDecoder()
        let offset = try decoder.decode(ELVCursor.self, from: Data(#"{"kind": "offset", "param": "offset", "pageSize": 60}"#.utf8))
        #expect(offset == .offset(param: "offset", pageSize: 60))
        let token = try decoder.decode(ELVCursor.self, from: Data(#"{"kind": "cursorToken", "path": "$.cursor", "param": "after"}"#.utf8))
        #expect(token == .cursorToken(path: "$.cursor", param: "after"))
        let shorthand = try decoder.decode(ELVCursor.self, from: Data(#"{"json": "$.next"}"#.utf8))
        #expect(shorthand == .nextURL(.json("$.next")))
        // An unknown cursor kind degrades to single-page, not a dead source.
        let unknown = try decoder.decode(ELVCursor.self, from: Data(#"{"kind": "spiral"}"#.utf8))
        #expect(unknown == .nextURL(.unsupported(key: "cursorKind:spiral")))
        // Neither a `kind: nextURL` tag nor a bare `url` key is grammar: both
        // are unsupported selectors the validator names.
        let tagged = try decoder.decode(ELVCursor.self, from: Data(#"{"kind": "nextURL", "url": {"json": "$.next"}}"#.utf8))
        #expect(tagged == .nextURL(.unsupported(key: "cursorKind:nextURL")))
        let bareURL = try decoder.decode(ELVCursor.self, from: Data(#"{"url": {"json": "$.next"}}"#.utf8))
        #expect(bareURL == .nextURL(.unsupported(key: "url")))
        // A typed cursor missing an argument degrades the same way.
        let missing = try decoder.decode(ELVCursor.self, from: Data(#"{"kind": "offset", "param": "offset"}"#.utf8))
        #expect(missing == .nextURL(.unsupported(key: "offset:(missing param or pageSize)")))
    }

    @Test
    func `An offset cursor's pageSize clamps into range, with a decode note only when it had to`() throws {
        let decoder = JSONDecoder()
        func list(pageSize: Int) throws -> ELVListSpec {
            try decoder.decode(
                ELVListSpec.self,
                from: Data(#"{"seed": "https://example.com/l", "items": {"json": "$.i[*]"}, "next": {"kind": "offset", "param": "o", "pageSize": \#(pageSize)}}"#.utf8)
            )
        }
        let zero = try list(pageSize: 0)
        #expect(zero.next == .offset(param: "o", pageSize: 1))
        #expect(zero.decodeIssues.count == 1)
        let huge = try list(pageSize: 1_000_000)
        #expect(huge.next == .offset(param: "o", pageSize: ELVListSpec.pageSizeRange.upperBound))
        #expect(huge.decodeIssues.count == 1)
        let inRange = try list(pageSize: 60)
        #expect(inRange.next == .offset(param: "o", pageSize: 60))
        #expect(inRange.decodeIssues.isEmpty)
        // The memberwise init clamps the same way (pack numerics clamp in init).
        #expect(ELVListSpec(seed: "s", items: .json("$"), next: .offset(param: "o", pageSize: -4)).next == .offset(param: "o", pageSize: 1))
    }

    @Test
    func `The validator reports every decoded-but-dead construct`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [
          {
            "id": "dead.example", "kind": "thing",
            "match": {"host": ["dead.example"]},
            "fetch": {"mode": "composite", "steps": [
              {"mode": "json", "format": "csv"},
              {"mode": "json", "ua": "crawler", "when": {}},
              {"mode": "json", "referer": "always", "when": {"status": [403]}}
            ]},
            "fields": [
              {"name": "empty", "candidates": []},
              {"name": "badRegex", "candidates": [{"from": {"urlRegex": "(["}}]},
              {"name": "badKind", "candidates": [{"from": {"json": "$.x"}, "as": "quaternion"}]},
              {"name": "badScale", "candidates": [{"from": {"json": "$.y"}, "as": "rating", "scale": {"min": 5, "max": 5}}]},
              {"name": "typoOp", "candidates": [{"from": {"native": "typo.op@9"}, "select": "value"}]}
            ],
            "collections": [
              {"name": "hollow", "from": {"json": "$.items[*]"}}
            ],
            "list": {
              "seed": "https://dead.example/list",
              "items": {"json": "$.items[*]"}
            }
          },
          {
            "id": "redirector.example", "kind": "link",
            "match": {"host": ["short.example"]},
            "resolvesVia": "shortlink.expand",
            "requires": ["native:shortlink.expand"],
            "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
          },
          {
            "id": "pathonly.example", "kind": "thing",
            "match": {"path": "/x/:id"},
            "fetch": {"mode": "json"}
          }
        ]}
        """
        let loaded = try load(json, modes: ["json"])
        let messages = loaded.diagnostics.map(\.description)
        func reported(_ fragment: String) -> Bool {
            messages.contains { $0.contains(fragment) }
        }
        #expect(reported("never fires"))
        #expect(reported("referer \"always\""))
        #expect(reported("has no candidates"))
        #expect(reported("regex does not compile"))
        #expect(reported("unknown coercion kind \"quaternion\""))
        #expect(reported("rating scale 5.0 to 5.0 is empty"))
        #expect(reported("native op \"typo.op@9\" is neither registered nor required"))
        #expect(reported("a redirector resolves via its op"))
        #expect(reported("collection \"hollow\" has no item specs"))
        #expect(reported("a match rule with a path but no host or brand can never match"))
        #expect(reported("declares \"format\", which only archive steps read"))
        // Diagnostics carry the owning source id.
        #expect(loaded.diagnostics.allSatisfy { $0.sourceId != nil })
    }

    @Test
    func `A redirector's op is an implicit requirement even when requires omits it`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [{
          "id": "bare.redirector", "kind": "link",
          "match": {"host": ["short.example"]},
          "resolvesVia": "future.redirect@9"
        }]}
        """
        let loaded = try load(json)
        #expect(loaded.sources.isEmpty)
        #expect(loaded.skipped.first?.id == "bare.redirector")
        #expect(loaded.skipped.first?.reason.contains("future.redirect@9") == true)
    }

    @Test
    func `Strict sub-structs decode leniently: a missing key degrades the construct, never the source`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [{
          "id": "lenient.example", "kind": "thing",
          "match": {"host": ["lenient.example"]},
          "fetch": {"mode": "composite", "steps": [
            {"mode": "json"},
            {"mode": "json", "when": {"status": [403]}, "captureCanonical": {"maxPolls": 3}}
          ]},
          "collections": [
            {"name": "bare", "from": {"json": "$.items[*]"}},
            {"kind": "child"}
          ],
          "identities": [
            {"ns": "lenient.ns"},
            {"from": {"json": "$.id"}}
          ]
        }]}
        """
        let loaded = try load(json, modes: ["json"])
        let source = try #require(loaded.source(withId: "lenient.example"))
        #expect(source.collections.count == 2)
        #expect(source.collections[0].item.isEmpty)
        #expect(source.collections[1].from == .unsupported(key: "(missing from)"))
        #expect(source.identities[0].from == .unsupported(key: "(missing from)"))
        #expect(source.identities[1].namespace.isEmpty)
        // The malformed capture (no until.urlRegex) drops the capture only.
        #expect(source.fetch?.resolvedSteps.last?.captureCanonical == nil)
        // Every degraded construct is reported, none is fatal.
        let messages = loaded.diagnostics.map(\.description)
        #expect(messages.contains { $0.contains("has no item specs") })
        #expect(messages.contains { $0.contains("empty namespace") })
        #expect(messages.contains { $0.contains("(missing from)") })
    }

    @Test
    func `An unknown onPageError degrades to stop, and unknown list keys are ignored`() throws {
        let decoder = JSONDecoder()
        let unknown = try decoder.decode(ELVPageErrorPolicy.self, from: Data(#""quantumHeal""#.utf8))
        #expect(unknown == .stop)
        // Forward compatibility: a newer pack's list vocabulary is
        // ignored, and a policy this binary does not know is the
        // conservative stop.
        let json = """
        {"seed": "https://example.com/list", "items": {"json": "$.items[*]"},
         "prefetch": {"pages": 2},
         "onPageError": "retryForever"}
        """
        let list = try decoder.decode(ELVListSpec.self, from: Data(json.utf8))
        #expect(list.onPageError == .stop)
        #expect(list.maxPages == 100)
        #expect(list.decodeIssues.isEmpty)
    }

    @Test
    func `An async-only native op is live in fields but flagged where only the sync path runs`() throws {
        ELVNativeOps.registerAsync("test.asyncOnly.validator", version: 1) { _, _ in nil }
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [{
          "id": "async.example", "kind": "thing",
          "match": {"host": ["async.example"]},
          "fetch": {"mode": "json"},
          "fields": [{"name": "headline", "candidates": [{"from": {"native": "test.asyncOnly.validator@1"}, "select": "value"}]}],
          "collections": [{"name": "children", "from": {"json": "$.items[*]"}, "item": [
            {"name": "title", "candidates": [{"from": {"native": "test.asyncOnly.validator@1"}, "select": "value"}]}
          ]}]
        }]}
        """
        let loaded = try load(json, modes: ["json"])
        let messages = loaded.diagnostics.map(\.description)
        // Top-level fields run the pipeline's awaited walk, so the
        // async op is LIVE there — no note. Collections (like rows,
        // identities, and list drivers) extract sync, so the same op is a
        // dead candidate there and the note still names it.
        #expect(!messages.contains { $0.contains("field \"headline\"") && $0.contains("only registered async") })
        #expect(messages.contains { $0.contains("collection \"children\"") && $0.contains("only registered async") })
    }

    @Test
    func `A source title decodes when present and stays nil when absent`() throws {
        let json = """
        {
          "schemaVersion": 1, "packVersion": "t",
          "sources": [
            {"id": "named.example", "title": "Named Example", "kind": "thing", "match": {"host": "a.example", "priority": 1}, "fetch": {"mode": "json"}},
            {"id": "bare.example", "kind": "thing", "match": {"host": "b.example", "priority": 1}, "fetch": {"mode": "json"}}
          ]
        }
        """
        let pack = try load(json)
        #expect(pack.source(withId: "named.example")?.title == "Named Example")
        #expect(pack.source(withId: "bare.example")?.title == nil)
    }
}

/// The step-scoped grammar: `maxBytes`, per-step `fields` and
/// `collections`, and per-collection `identities` — decode shapes and
/// clamps.
@Suite("Step-scope grammar decode")
struct ELVStepScopeDecodeTests {
    private func load(_ json: String) throws -> ELVLoadedPack {
        try ELVPackLoader.load(
            embedded: Data(json.utf8),
            capabilities: ELVCapabilities(fetchModes: ["http", "json", "feed", "dom", "archive"], binaryVersion: "0.1")
        )
    }

    @Test
    func `maxBytes clamps to the transport ceiling and degrades non-positive to absent`() throws {
        let pack = try load("""
        {"schemaVersion": 1, "packVersion": "t", "sources": [
          {"id": "a", "kind": "k", "match": {"host": ["a.example"], "path": "/**", "priority": 100},
           "fetch": {"mode": "composite", "steps": [
             {"mode": "http", "maxBytes": 5000000},
             {"mode": "http", "maxBytes": 99000000},
             {"mode": "http", "maxBytes": 0},
             {"mode": "http", "maxBytes": -5}
           ]}, "examples": []},
          {"id": "b", "kind": "k", "match": {"host": ["b.example"], "path": "/**", "priority": 100},
           "fetch": {"mode": "feed", "maxBytes": 10000000}, "examples": []}
        ]}
        """)
        let steps = try #require(pack.source(withId: "a")?.fetch?.resolvedSteps)
        #expect(steps.map(\.maxBytes) == [5_000_000, 10_000_000, nil, nil])
        // The plan-level key lifts into a single-mode plan's one resolved step.
        #expect(pack.source(withId: "b")?.fetch?.resolvedSteps.first?.maxBytes == 10_000_000)
    }

    @Test
    func `Scoped step fields distinguish absent from empty, and step collections decode with identities`() throws {
        let pack = try load("""
        {"schemaVersion": 1, "packVersion": "t", "sources": [
          {"id": "a", "kind": "k", "match": {"host": ["a.example"], "path": "/**", "priority": 100},
           "fetch": {"mode": "composite", "steps": [
             {"mode": "http"},
             {"mode": "json", "url": "https://api.example/x",
              "fields": [{"name": "author", "candidates": [{"from": {"json": "$.a"}}]}],
              "collections": [{"name": "tracks", "from": {"json": "$.t[*]"},
                "item": [{"name": "title", "candidates": [{"from": {"json": "$.n"}}]}],
                "identities": [{"ns": "isrc", "from": {"json": "$.isrc"}}]}]},
             {"mode": "http", "fields": []}
           ]}, "examples": []}
        ]}
        """)
        let steps = try #require(pack.source(withId: "a")?.fetch?.resolvedSteps)
        #expect(steps[0].fields == nil)
        #expect(steps[1].fields?.count == 1)
        #expect(steps[2].fields?.isEmpty == true)
        let collection = try #require(steps[1].collections?.first)
        #expect(collection.name == "tracks")
        #expect(collection.identities == [ELVIdentitySpec(namespace: "isrc", from: .json("$.isrc"))])
    }
}
