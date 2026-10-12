import Foundation
import Testing
@testable import EluviumCore

@Suite("Pack loading")
struct ELVPackLoaderTests {
    private let packJSON = """
    {
      "schemaVersion": 1,
      "schemaMinor": 4,
      "packVersion": "2026.08.11-1",
      "futureTopLevelKey": {"ignored": true},
      "sources": [
        {
          "id": "alltrails.trail",
          "kind": "trail",
          "match": {"host": ["alltrails.com"], "path": "/trail/:country/:region/:slug", "priority": 100},
          "canonicalize": {"strip": ["utm_*", "sh"]},
          "fetch": {"mode": "composite", "steps": [
            {"mode": "http", "ua": "mobileSafari"},
            {"mode": "dom", "when": {"anyOf": [
              {"status": [403, 429, 503]},
              {"emptyRecord": true},
              {"missingAny": ["distance"]}
            ]}}
          ]},
          "fields": [
            {"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}
          ]
        },
        {
          "id": "komoot.tour",
          "kind": "trail",
          "match": {"host": ["komoot.com"]},
          "canonicalize": {"keep": ["share_token"]},
          "fetch": {"mode": "http"}
        },
        {
          "id": "future.source",
          "kind": "thing",
          "match": {"host": ["future.example"]},
          "requires": ["native:quantum.scan@7"]
        },
        {
          "id": "too.new",
          "kind": "thing",
          "match": {"host": ["new.example"]},
          "minBinary": "99.0"
        }
      ]
    }
    """

    @Test
    func `A pack loads: capable sources active, incapable ones skipped with reasons`() throws {
        let capabilities = ELVCapabilities(fetchModes: ["http", "json", "archive", "composite"], binaryVersion: "0.1")
        let loaded = try ELVPackLoader.load(embedded: Data(packJSON.utf8), capabilities: capabilities)
        #expect(loaded.pack.schemaMinor == 4)
        #expect(loaded.sources.map(\.id) == ["komoot.tour"])
        #expect(loaded.skipped.map(\.id).sorted() == ["alltrails.trail", "future.source", "too.new"])
        #expect(loaded.skipped.first { $0.id == "alltrails.trail" }?.reason.contains("dom") == true)
        #expect(loaded.skipped.first { $0.id == "too.new" }?.reason.contains("99.0") == true)
    }

    @Test
    func `A dom-capable binary activates the composite source and its registry recognizes URLs`() throws {
        let capabilities = ELVCapabilities(fetchModes: ["http", "dom", "composite"], binaryVersion: "0.1")
        let loaded = try ELVPackLoader.load(embedded: Data(packJSON.utf8), capabilities: capabilities)
        #expect(loaded.sources.map(\.id).contains("alltrails.trail"))
        let url = try #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))
        #expect(loaded.registry.recognize(url)?.sourceId == "alltrails.trail")
        #expect(loaded.source(withId: "alltrails.trail")?.fetch?.resolvedSteps.count == 2)
    }

    @Test
    func `A schemaVersion outside 1...supported is rejected wholesale; a newer schemaMinor loads with one note`() throws {
        for version in [2, 0, -1] {
            let bad = packJSON.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": \(version)")
            #expect(throws: ELVPackError.unsupportedSchemaVersion(version)) {
                _ = try ELVPackLoader.load(embedded: Data(bad.utf8))
            }
        }
        // A pack one minor past what the binary knows loads (forward
        // compatibility) and says so exactly once, at the pack level.
        let newer = ELVPackLoader.supportedSchemaMinor + 1
        let ahead = packJSON.replacingOccurrences(of: "\"schemaMinor\": 4", with: "\"schemaMinor\": \(newer)")
        let loaded = try ELVPackLoader.load(embedded: Data(ahead.utf8))
        let notes = loaded.diagnostics.filter { $0.message.contains("schemaMinor") }
        #expect(notes.count == 1)
        #expect(notes.first?.sourceId == nil)
        #expect(notes.first?.message == "pack declares schemaMinor \(newer); this binary knows \(ELVPackLoader.supportedSchemaMinor); unknown vocabulary degrades per source")
        let current = packJSON.replacingOccurrences(of: "\"schemaMinor\": 4", with: "\"schemaMinor\": \(ELVPackLoader.supportedSchemaMinor)")
        #expect(try ELVPackLoader.load(embedded: Data(current.utf8)).diagnostics.allSatisfy { !$0.message.contains("schemaMinor") })
    }

    @Test
    func `Malformed pack bytes and a pack without packVersion throw a typed error`() {
        #expect(throws: ELVPackError.self) {
            _ = try ELVPackLoader.load(embedded: Data("<html>not a pack</html>".utf8))
        }
        #expect(throws: ELVPackError.self) {
            _ = try ELVPackLoader.load(embedded: Data(#"{"schemaVersion": 1, "sources": []}"#.utf8))
        }
    }

    @Test
    func `A fetch plan without a mode skips its source with a reason and a validator note`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [
          {"id": "modeless.plan", "kind": "k", "match": {"host": ["a.example"]}, "fetch": {"url": "https://a.example/api"}},
          {"id": "modeless.step", "kind": "k", "match": {"host": ["b.example"]},
           "fetch": {"mode": "composite", "steps": [{"mode": "http"}, {"ua": "crawler", "when": {"status": [403]}}]}},
          {"id": "fine", "kind": "k", "match": {"host": ["c.example"]}, "fetch": {"mode": "http"}}
        ]}
        """
        let loaded = try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: ["http", "json"], binaryVersion: "0.1"))
        #expect(loaded.sources.map(\.id) == ["fine"])
        #expect(loaded.skipped.map(\.reason) == ["fetch plan declares no mode", "fetch plan declares no mode"])
        #expect(loaded.diagnostics.count(where: { $0.message == "a fetch step declares no mode; the source is skipped" }) == 2)
    }

    @Test
    func `Canonicalization strips tracking params but never a declared keep token`() throws {
        let strip = ELVCanonicalizeRule(strip: ["utm_*", "sh"])
        let stripped = try strip.apply(to: #require(URL(string: "https://www.alltrails.com/trail/x?utm_source=share&utm_medium=ios&sh=abc&p=1")))
        #expect(stripped.absoluteString == "https://www.alltrails.com/trail/x?p=1")

        let keep = ELVCanonicalizeRule(keep: ["share_token"])
        let kept = try keep.apply(to: #require(URL(string: "https://www.komoot.com/tour/123?share_token=aToken&ref=share")))
        #expect(kept.absoluteString == "https://www.komoot.com/tour/123?share_token=aToken")
    }

    @Test
    func `Escalation triggers fire on status, empty record, and missing fields`() {
        let trigger = ELVEscalationTrigger(anyOf: [
            ELVEscalationTrigger(status: [403, 429, 503]),
            ELVEscalationTrigger(emptyRecord: true),
            ELVEscalationTrigger(missingAny: ["distance", "difficulty"]),
        ])
        #expect(trigger.fires(status: 403, extractedFields: ["title": .text("x")]))
        #expect(trigger.fires(status: 200, extractedFields: [:]))
        #expect(trigger.fires(status: 200, extractedFields: ["title": .text("x")]))
        let complete: [String: ELVValue] = ["title": .text("x"), "distance": .number(1), "difficulty": .text("easy")]
        #expect(!trigger.fires(status: 200, extractedFields: complete))
    }

    @Test
    func `The enumerable roster holds the list-spec sources in pack order, disjoint from seeds`() throws {
        let json = """
        {
          "schemaVersion": 1,
          "packVersion": "t",
          "sources": [
            {"id": "plain.page", "kind": "page", "match": {"host": ["a.example"]}, "fetch": {"mode": "http"}},
            {"id": "walk.later", "kind": "page", "match": {"host": ["c.example"], "path": "/items"}, "fetch": {"mode": "json"},
             "list": {"seed": "https://c.example/items", "items": {"json": "$.results[*]"}}},
            {"id": "seeded.list", "kind": "list", "seed": "https://b.example/top", "fetch": {"mode": "http"}},
            {"id": "walk.dex", "kind": "page", "match": {"host": ["b.example"], "path": "/all"}, "fetch": {"mode": "json"},
             "list": {"seed": "https://b.example/all", "items": {"json": "$.rows[*]"}}}
          ]
        }
        """
        let capabilities = ELVCapabilities(fetchModes: ["http", "json"], binaryVersion: "0.1")
        let loaded = try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: capabilities)
        #expect(loaded.enumerableSources.map(\.id) == ["walk.later", "walk.dex"])
        #expect(loaded.seededSources.map(\.id) == ["seeded.list"])
    }

    @Test
    func `Binary version comparison is numeric, not lexicographic`() {
        #expect(ELVBinary.isAtLeast("1.10", required: "1.3"))
        #expect(!ELVBinary.isAtLeast("1.3", required: "1.10"))
        #expect(ELVBinary.isAtLeast("1.3", required: "1.3"))
        #expect(ELVBinary.isAtLeast("2", required: "1.9.9"))
    }
}

/// The refactor's validator additions: every new decode surface gets a note
/// where misuse is possible (decode surface = executed surface).
@Suite("Refactor validator notes")
struct ELVRefactorDiagnosticsTests {
    private func diagnostics(_ json: String) throws -> [String] {
        try ELVPackLoader.load(
            embedded: Data(json.utf8),
            capabilities: ELVCapabilities(fetchModes: ["http", "json", "feed", "dom", "archive"], binaryVersion: "0.1")
        ).diagnostics.map(\.description)
    }

    private func source(_ body: String, fragments: String = "") -> String {
        """
        {"schemaVersion": 1, "packVersion": "t",\(fragments)
         "sources": [{"id": "s", "kind": "k", "match": {"host": ["s.example"], "path": "/**", "priority": 100},\(body) "examples": []}]}
        """
    }

    @Test
    func `An unknown imageReferer policy is noted and ignored`() throws {
        let noted = try diagnostics(source(#""imageReferer": "self", "fetch": {"mode": "http"},"#))
        #expect(noted.contains { $0.contains("imageReferer") && $0.contains("self") })
        let clean = try diagnostics(source(#""imageReferer": "page", "fetch": {"mode": "http"},"#))
        #expect(!clean.contains { $0.contains("imageReferer") })
    }

    @Test
    func `A composite plan's discarded top-level keys are named`() throws {
        let notes = try diagnostics(source(#""fetch": {"mode": "composite", "jsonIsland": "__NEXT_DATA__", "maxBytes": 5000000, "steps": [{"mode": "http"}]},"#))
        #expect(notes.contains { $0.contains("top-level jsonIsland, maxBytes are discarded") })
    }

    @Test
    func `maxBytes on a non-transport step is flagged`() throws {
        let notes = try diagnostics(source(#""fetch": {"mode": "composite", "steps": [{"mode": "http"}, {"mode": "dom", "maxBytes": 5000000, "when": {"missingAny": ["title"]}}]},"#))
        #expect(notes.contains { $0.contains("\"dom\" step declares \"maxBytes\"") })
    }

    @Test
    func `regexRows in a value position is a permanently dead candidate`() throws {
        let notes = try diagnostics(source(#""fields": [{"name": "title", "candidates": [{"from": {"regexRows": "x(y)"}}]}],"#))
        #expect(notes.contains { $0.contains("regexRows drives collections only") })
    }

    @Test
    func `A value selector as a collection's from never yields items`() throws {
        let notes = try diagnostics(source(#""collections": [{"name": "c", "from": {"css": ".row"}, "item": [{"name": "t", "candidates": [{"from": {"json": "$.t"}}]}]}],"#))
        #expect(notes.contains { $0.contains("is not a rows driver") })
    }

    @Test
    func `An unparseable seed is named instead of failing at runSeed`() throws {
        let notes = try diagnostics(source(#""seed": "not a url","#))
        #expect(notes.contains { $0.contains("does not parse as a URL") })
    }

    @Test
    func `A step with empty fields and no collections is dead weight; a name collision names the winner`() throws {
        let notes = try diagnostics(source("""
         "fetch": {"mode": "composite", "steps": [
           {"mode": "http"},
           {"mode": "json", "url": "https://api.example/x", "fields": [],
            "collections": []},
           {"mode": "json", "url": "https://api.example/y",
            "collections": [{"name": "tracks", "from": {"json": "$.t[*]"}, "item": [{"name": "t", "candidates": [{"from": {"json": "$.t"}}]}]}]}
         ]},
         "collections": [{"name": "tracks", "from": {"json": "$.z[*]"}, "item": [{"name": "t", "candidates": [{"from": {"json": "$.t"}}]}]}],
        """))
        #expect(notes.contains { $0.contains("fields: [] and no collections") })
        #expect(notes.contains { $0.contains("declared on both the source and step 2") })
    }

    @Test
    func `A named trigger resolves onto its steps; dangling and unused names are diagnosed`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t",
         "triggers": {
           "blockedOrThin": { "anyOf": [{ "status": [403, 429, 503] }, { "emptyRecord": true }, { "missingAny": ["title"] }] },
           "lonely": { "emptyRecord": true }
         },
         "sources": [{"id": "s", "kind": "k", "match": {"host": ["s.example"], "path": "/**", "priority": 100},
           "fetch": {"mode": "composite", "steps": [
             {"mode": "http"},
             {"mode": "http", "ua": "crawler", "when": "blockedOrThin"},
             {"mode": "http", "when": "nope"}
           ]}, "examples": []}]}
        """
        let pack = try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: ["http"], binaryVersion: "0.1"))
        let steps = try #require(pack.source(withId: "s")?.fetch?.resolvedSteps)
        // Whole-trigger replacement: the resolved step carries the table
        // entry, ref cleared.
        #expect(steps[1].when?.ref == nil)
        #expect(steps[1].when?.anyOf.count == 3)
        // The dangling name stays set (never admits) and is diagnosed.
        #expect(steps[2].when?.ref == "nope")
        let notes = pack.diagnostics.map(\.description)
        #expect(notes.contains { $0.contains("when references trigger \"nope\"") })
        #expect(notes.contains { $0.contains("trigger \"lonely\" is declared but no step references it") })
    }

    @Test
    func `A use entry that can contribute nothing is named at resolution time`() throws {
        let fragments = #" "fragments": {"escalate": {"fetch": {"mode": "composite", "steps": [{"mode": "http"}]}}},"#
        let notes = try diagnostics(source(#""use": ["escalate"], "fetch": {"mode": "http"},"#, fragments: fragments))
        #expect(notes.contains { $0.contains("use \"escalate\" contributes nothing") })
    }

    @Test
    func `A json path that does not parse is named`() throws {
        let notes = try diagnostics(source(#""fetch": {"mode": "json"}, "fields": [{"name": "t", "candidates": [{"from": {"json": "$.items["}}]}],"#))
        #expect(notes.contains { $0.contains("field \"t\": json path does not parse: $.items[") })
        let clean = try diagnostics(source(#""fetch": {"mode": "json"}, "fields": [{"name": "t", "candidates": [{"from": {"json": "$.items[0].name"}}]}],"#))
        #expect(!clean.contains { $0.contains("json path") })
    }

    @Test
    func `A jsonld selector with an empty type filter is named`() throws {
        let notes = try diagnostics(source(#""fetch": {"mode": "http"}, "fields": [{"name": "t", "candidates": [{"from": {"jsonld": ".name"}}]}],"#))
        #expect(notes.contains { $0.contains("jsonld selector \".name\" has an empty type filter") })
        let clean = try diagnostics(source(#""fetch": {"mode": "http"}, "fields": [{"name": "t", "candidates": [{"from": {"jsonld": "*.name"}}]}],"#))
        #expect(!clean.contains { $0.contains("empty type filter") })
    }

    @Test
    func `A non-positive take and an out-of-range offset pageSize are named`() throws {
        let take = try diagnostics(source(#""fetch": {"mode": "json"}, "fields": [{"name": "t", "candidates": [{"from": {"json": "$.tags[*]"}, "pipe": [{"take": 0}]}]}],"#))
        #expect(take.contains { $0.contains("take 0 yields nothing") })
        let list =
            try diagnostics(source(#""fetch": {"mode": "json"}, "list": {"seed": "https://s.example/l", "items": {"json": "$.i[*]"}, "next": {"kind": "offset", "param": "o", "pageSize": 0}},"#))
        #expect(list.contains { $0.contains("list.next: offset pageSize 0 is outside 1...1000") })
    }

    @Test
    func `An unknown persona is named at the plan level and at the step level`() throws {
        let plan = try diagnostics(source(#""fetch": {"mode": "http", "ua": "netscape"},"#))
        #expect(plan.contains { $0.contains("persona \"netscape\" is not one this binary knows; mobileSafari is used") })
        let step = try diagnostics(source(#""fetch": {"mode": "composite", "steps": [{"mode": "http", "ua": "mobileSafari"}, {"mode": "http", "ua": "lynx", "when": {"status": [403]}}]},"#))
        #expect(step.count(where: { $0.contains("persona \"lynx\"") }) == 1)
        #expect(!step.contains { $0.contains("persona \"mobileSafari\"") })
    }

    @Test
    func `Off-vocabulary source and collection kinds are noted, never rejected`() throws {
        let json = """
        {"schemaVersion": 1, "packVersion": "t", "sources": [
          {"id": "s", "kind": "Trail", "match": {"host": ["s.example"]}, "fetch": {"mode": "json"},
           "collections": [{"name": "episodes", "kind": "podcastEpisode", "from": {"json": "$.e[*]"}, "item": [{"name": "t", "candidates": [{"from": {"json": "$.t"}}]}]}]}
        ]}
        """
        let loaded = try ELVPackLoader.load(embedded: Data(json.utf8), capabilities: ELVCapabilities(fetchModes: ["json"], binaryVersion: "0.1"))
        #expect(loaded.sources.map(\.id) == ["s"])
        let notes = loaded.diagnostics.map(\.description)
        #expect(notes.contains { $0.contains("kind \"Trail\" is not a lowercase kind token") })
        #expect(notes.contains { $0.contains("collection \"episodes\": kind \"podcastEpisode\" is not a lowercase kind token") })
        let clean =
            try diagnostics(
                source(
                    #""fetch": {"mode": "json"}, "collections": [{"name": "e", "kind": "feed.item", "from": {"json": "$.e[*]"}, "item": [{"name": "t", "candidates": [{"from": {"json": "$.t"}}]}]}],"#
                )
            )
        #expect(!clean.contains { $0.contains("kind token") })
    }

    @Test
    func `A fetch requirement the steps already imply is redundant`() throws {
        let plan = #""fetch": {"mode": "composite", "steps": [{"mode": "http"}, {"mode": "dom", "when": {"missingAny": ["title"]}}]},"#
        let notes = try diagnostics(source(plan + #" "requires": ["fetch:dom", "fetch:feed"],"#))
        #expect(notes.contains("s: requires \"fetch:dom\" is redundant: the plan's steps already require it"))
        #expect(!notes.contains { $0.contains("\"fetch:feed\" is redundant") })
    }

    @Test
    func `A native requirement without a version is noted`() throws {
        let notes = try diagnostics(source(#""fetch": {"mode": "http"}, "requires": ["native:text.digits", "native:text.join@1"],"#))
        #expect(notes.contains { $0.contains("\"native:text.digits\" names no version") })
        #expect(!notes.contains { $0.contains("\"native:text.join@1\"") })
    }

    @Test
    func `Pack strong namespaces load as a set, blanks dropped and noted`() throws {
        let json = #"{"schemaVersion": 1, "packVersion": "t", "strongNamespaces": ["goodreads.book", "", "goodreads.book"], "sources": []}"#
        let pack = try ELVPackLoader.load(embedded: Data(json.utf8))
        #expect(pack.strongNamespaces == ["goodreads.book"])
        #expect(pack.diagnostics.map(\.description).contains("strongNamespaces lists an empty namespace; it is ignored"))
        // A scalar is the one-element list (the grammar's string-list
        // leniency); a malformed value costs the list, never the pack.
        let scalar = try ELVPackLoader.load(embedded: Data(#"{"schemaVersion": 1, "packVersion": "t", "strongNamespaces": "isbn13", "sources": []}"#.utf8))
        #expect(scalar.strongNamespaces == ["isbn13"])
        let malformed = try ELVPackLoader.load(embedded: Data(#"{"schemaVersion": 1, "packVersion": "t", "strongNamespaces": {"x": 1}, "sources": []}"#.utf8))
        #expect(malformed.strongNamespaces.isEmpty)
        #expect(malformed.diagnostics.contains { $0.message.hasPrefix("strongNamespaces dropped") })
    }
}
