import EluviumCore
import Foundation
import Testing

@Suite("Offline preview and label ladder")
struct ELVPreviewTests {
    /// Every shape the preview distinguishes: a URL-only source, a
    /// URL-then-fetch composite gated on a weak label, a fetch-first
    /// source, a redirector with a preview hint, an app-scheme source, and
    /// a generic floor.
    private let packJSON = """
    {
      "schemaVersion": 1, "schemaMinor": 5, "packVersion": "preview-test",
      "sources": [
        {
          "id": "test.redirector", "title": "Short links", "kind": "link",
          "match": {"host": ["sho.rt"], "path": "/**", "priority": 90},
          "resolvesVia": "test.expand",
          "previewAs": {"sho.rt": "test.trail"}
        },
        {
          "id": "test.place", "title": "Test Maps", "kind": "place",
          "match": {"brand": ["maps.testmap"], "path": "/place/:name", "priority": 100},
          "fetch": {"mode": "composite", "steps": [
            {"mode": "none"},
            {"mode": "http", "when": {"weakAny": ["title"]}}
          ]},
          "fields": [
            {"name": "title", "candidates": [
              {"from": {"urlParam": "name"}, "pipe": ["slugToTitle"]},
              {"from": {"paste": "label"}}
            ]},
            {"name": "metaName", "candidates": [{"from": {"meta": "og:title"}}]}
          ],
          "label": ["title", "metaName"]
        },
        {
          "id": "test.trail", "title": "TrailCo", "kind": "trail",
          "match": {"host": ["trailco.com"], "path": "/trail/:slug", "priority": 100},
          "fetch": {"mode": "http"},
          "fields": [
            {"name": "title", "candidates": [
              {"from": {"meta": "og:title"}},
              {"from": {"paste": "label"}},
              {"from": {"urlParam": "slug"}, "pipe": ["slugToTitle"]}
            ]},
            {"name": "shareText", "candidates": [{"from": {"paste": "text"}}]}
          ],
          "label": ["title"]
        },
        {
          "id": "test.applink", "title": "Test Maps", "kind": "place",
          "match": {"scheme": ["testmaps"], "priority": 100},
          "fetch": {"mode": "none"},
          "fields": [{"name": "title", "candidates": [{"from": {"urlQuery": "q"}}]}],
          "label": ["title"]
        },
        {
          "id": "test.floor", "title": "Web pages", "kind": "link",
          "fetch": {"mode": "http"},
          "fields": [{"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}]
        }
      ]
    }
    """

    private func pack() throws -> ELVLoadedPack {
        ELVNativeOps.registerAsync("test.expand", version: 1) { _, _ in nil }
        return try ELVPackLoader.load(embedded: Data(packJSON.utf8), capabilities: ELVCapabilities(fetchModes: ["http"], binaryVersion: ELVBinary.version))
    }

    private func input(_ text: String) throws -> ELVPastedInput {
        try #require(ELVPastedInput.parse(text))
    }

    @Test
    func `the test pack loads clean`() throws {
        #expect(try pack().diagnostics.isEmpty)
    }

    @Test
    func `a URL-borne name is the label and needs no fetch`() throws {
        let preview = try pack().preview(input("https://maps.testmap.co.jp/place/jenny-lake"))
        #expect(preview.sourceId == "test.place")
        #expect(preview.record.fields["label"] == .text("Jenny Lake"))
        #expect(preview.record.provenance["label"]?.origin == "label:title")
        #expect(preview.pending.isEmpty)
        #expect(!preview.needsFullRun)
    }

    @Test
    func `a country-shaped URL label is weak, so the page fetch stays pending`() throws {
        let preview = try pack().preview(input("https://maps.testmap.com/place/japan"))
        #expect(preview.record.fields["label"] == .text("Japan"))
        #expect(preview.pending == .fetch)
    }

    @Test
    func `the share name beats the slug in a fetch-first source's preview`() throws {
        let preview = try pack().preview(input("Hidden Falls on TrailCo\nhttps://trailco.com/trail/hidden-falls-trail?sh=7mixyz"))
        #expect(preview.record.fields["label"] == .text("Hidden Falls"))
        #expect(preview.pending == .fetch)
        let shareText = try #require(preview.record.fields["shareText"])
        #expect(shareText != .text(""))
    }

    @Test
    func `a typed label wins the ladder`() throws {
        let preview = try pack().preview(input("https://maps.testmap.com/place/jenny-lake"), userLabel: "Picnic spot")
        #expect(preview.record.fields["label"] == .text("Picnic spot"))
        #expect(preview.record.provenance["label"]?.origin == "label:user")
    }

    @Test
    func `a redirector previews as its hinted source, pending the chase`() throws {
        let preview = try pack().preview(input("Mist Trail on TrailCo https://sho.rt/AbC"))
        #expect(preview.sourceId == "test.redirector")
        #expect(preview.provisionalSourceId == "test.trail")
        #expect(preview.record.sourceId == "test.trail")
        #expect(preview.record.kind == "trail")
        #expect(preview.record.fields["label"] == .text("Mist Trail"))
        #expect(preview.pending == .redirect)
    }

    @Test
    func `an app-scheme link matches its scheme source and never a web source`() throws {
        let pack = try pack()
        #expect(ELVPastedInput.parse("testmaps://?q=Tokyo%20Tower") == nil)
        #expect(pack.pastePolicy.schemes.contains("testmaps"))
        let input = try #require(ELVPastedInput.parse("testmaps://?q=Tokyo%20Tower", policy: pack.pastePolicy))
        let preview = pack.preview(input)
        #expect(preview.sourceId == "test.applink")
        #expect(preview.record.fields["label"] == .text("Tokyo Tower"))
        #expect(preview.pending.isEmpty)
        #expect(try pack.registry.recognize(#require(URL(string: "https://testmaps.com/?q=x"))) == nil)
    }

    @Test
    func `an unrecognized link is a floor card labeled by its host`() throws {
        let preview = try pack().preview(input("https://www.example.org/menu"))
        #expect(preview.sourceId == nil)
        #expect(preview.record.sourceId == "test.floor")
        #expect(preview.record.fields["label"] == .text("example.org"))
        #expect(preview.pending == .floor)
    }

    @Test
    func `the label ladder skips weak values but keeps a lone country`() {
        let brand = "Test Maps"
        let pickStrong = ELVLabelResolver.resolve(userLabel: nil, ladder: [("title", "Japan"), ("metaName", "Tokyo Tower")], brand: brand)
        #expect(pickStrong == ELVLabelResolver.Resolution(value: "Tokyo Tower", origin: "metaName"))
        let loneCountry = ELVLabelResolver.resolve(userLabel: nil, ladder: [("title", "Japan"), ("metaName", "test maps")], brand: brand)
        #expect(loneCountry?.value == "Japan")
        let brandOnly = ELVLabelResolver.resolve(userLabel: nil, ladder: [("title", " ")], brand: brand)
        #expect(brandOnly == ELVLabelResolver.Resolution(value: "Test Maps", origin: "brand"))
        #expect(ELVLabelResolver.resolve(userLabel: nil, ladder: [], brand: nil) == nil)
        // Two-letter tokens and a city are never country-weak.
        #expect(!ELVLabelResolver.isWeak("LA", brand: brand))
        #expect(!ELVLabelResolver.isWeak("Paris", brand: brand))
        #expect(ELVLabelResolver.isWeak("United States", brand: brand))
    }

    @Test
    func `weakAny fires on a missing, generic, or country field`() {
        let trigger = ELVEscalationTrigger(weakAny: ["title"])
        #expect(trigger.hasResponseConditions)
        #expect(trigger.fires(status: 200, extractedFields: [:], brand: "Test Maps"))
        #expect(trigger.fires(status: 200, extractedFields: ["title": .text("Test Maps")], brand: "Test Maps"))
        #expect(trigger.fires(status: 200, extractedFields: ["title": .text("Japan")], brand: "Test Maps"))
        #expect(!trigger.fires(status: 200, extractedFields: ["title": .text("Jenny Lake")], brand: "Test Maps"))
    }

    @Test
    func `the validator names bad label, preview, and scheme declarations`() throws {
        let bad = """
        {
          "schemaVersion": 1, "schemaMinor": 5, "packVersion": "bad",
          "sources": [
            {"id": "a", "kind": "link", "match": {"host": ["a.com"]}, "fetch": {"mode": "none"},
             "fields": [{"name": "title", "candidates": [{"from": {"paste": "nope"}}]}],
             "label": ["title", "missing"], "previewAs": {"a.com": "b"}},
            {"id": "r", "kind": "link", "match": {"host": ["r.co"]}, "resolvesVia": "test.expand",
             "previewAs": {"other.co": "ghost"}},
            {"id": "s", "kind": "place", "match": {"scheme": ["app"], "host": ["s.com"]}, "fetch": {"mode": "http"}}
          ]
        }
        """
        ELVNativeOps.registerAsync("test.expand", version: 1) { _, _ in nil }
        let loaded = try ELVPackLoader.load(embedded: Data(bad.utf8), capabilities: ELVCapabilities(fetchModes: ["http"], binaryVersion: ELVBinary.version))
        let messages = loaded.diagnostics.map(\.message).joined(separator: "\n")
        #expect(messages.contains("paste key \"nope\""))
        #expect(messages.contains("label names field \"missing\""))
        #expect(messages.contains("previewAs applies to redirectors only"))
        #expect(messages.contains("previewAs names host \"other.co\""))
        #expect(messages.contains("maps \"other.co\" to \"ghost\""))
        #expect(messages.contains("matches only app links"))
        #expect(messages.contains("must be URL-only"))
    }
}
