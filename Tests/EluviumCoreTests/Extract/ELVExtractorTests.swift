import Foundation
import Synchronization
import Testing
@testable import EluviumCore

@Suite("Extraction engine")
struct ELVExtractorTests {
    private func makeContext() throws -> ELVExtractionContext {
        let html = """
        <html><head>
          <title>Hidden Falls Trail | AllTrails</title>
          <meta property="og:title" content="Hidden Falls Trail" />
          <meta property="og:image" content="/img/cover.jpg" />
          <script type="application/ld+json">
            {"@type": "TouristAttraction", "name": "Hidden Falls Trail", "geo": {"latitude": 43.7904, "longitude": -110.7624}}
          </script>
        </head></html>
        """
        return ELVExtractionContext(
            url: URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"),
            params: ["slug": "hidden-falls-trail"],
            document: ELVDocument(html: html)
        )
    }

    @Test
    func `The first producing candidate wins and provenance records which one`() throws {
        let fields = [
            ELVFieldSpec(name: "title", candidates: [
                ELVCandidate(from: .css(selector: "h1", attr: nil)),
                ELVCandidate(from: .meta("og:title")),
                ELVCandidate(from: .urlParam("slug"), pipes: [.slugToTitle]),
            ]),
        ]
        let result = try ELVExtractor.extract(fields: fields, context: makeContext())
        #expect(result.values["title"] == .text("Hidden Falls Trail"))
        #expect(result.provenance["title"] == ELVProvenance(origin: "meta:og:title", candidateIndex: 1))
    }

    @Test
    func `A failed coercion falls through to the next candidate instead of poisoning the field`() throws {
        let fields = [
            ELVFieldSpec(name: "distance", candidates: [
                ELVCandidate(from: .meta("og:title"), coercion: ELVCoercion(kind: "double")),
                ELVCandidate(from: .const("7.2"), coercion: ELVCoercion(kind: "double")),
            ]),
        ]
        let result = try ELVExtractor.extract(fields: fields, context: makeContext())
        #expect(result.values["distance"] == .number(7.2))
        #expect(result.provenance["distance"]?.candidateIndex == 1)
    }

    @Test
    func `Unknown selectors and pipes invalidate only their candidate`() throws {
        let wire = """
        [
          {"name": "title", "candidates": [
            {"from": {"quantumScan": "page"}},
            {"from": {"meta": "og:title"}, "pipe": ["overclock"]},
            {"from": {"meta": "og:title"}, "pipe": ["trim"]}
          ]}
        ]
        """
        let fields = try JSONDecoder().decode([ELVFieldSpec].self, from: Data(wire.utf8))
        let result = try ELVExtractor.extract(fields: fields, context: makeContext())
        #expect(result.values["title"] == .text("Hidden Falls Trail"))
        #expect(result.provenance["title"]?.candidateIndex == 2)
    }

    @Test
    func `Later fields reference earlier fields' values in pack order`() throws {
        let fields = [
            ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .meta("og:title"))]),
            ELVFieldSpec(name: "label", candidates: [
                ELVCandidate(from: .field("title"), pipes: [.stripSuffix(" Trail")]),
            ]),
        ]
        let result = try ELVExtractor.extract(fields: fields, context: makeContext())
        #expect(result.values["label"] == .text("Hidden Falls"))
    }

    @Test
    func `JSON-LD selectors filter by @type and walk keypaths, arrays step into their first node`() throws {
        let fields = [
            ELVFieldSpec(name: "name", candidates: [ELVCandidate(from: .jsonld("TouristAttraction.name"))]),
            ELVFieldSpec(name: "lat", candidates: [ELVCandidate(from: .jsonld("touristattraction.geo.latitude"))]),
            ELVFieldSpec(name: "any", candidates: [ELVCandidate(from: .jsonld("*.name"))]),
        ]
        let result = try ELVExtractor.extract(fields: fields, context: makeContext())
        #expect(result.values["name"] == .text("Hidden Falls Trail"))
        #expect(result.values["lat"] == .number(43.7904))
        #expect(result.values["any"] == .text("Hidden Falls Trail"))
    }

    @Test
    func `Relative og:image resolves against the page URL through the url pipe and image coercion`() throws {
        let fields = [
            ELVFieldSpec(name: "image", candidates: [
                ELVCandidate(from: .meta("og:image"), pipes: [.resolveURL], coercion: ELVCoercion(kind: "image")),
            ]),
        ]
        let result = try ELVExtractor.extract(fields: fields, context: makeContext())
        let expected = try #require(URL(string: "https://www.alltrails.com/img/cover.jpg"))
        #expect(result.values["image"] == .media(ELVMediaRef(url: expected, kind: ELVMediaRef.image)))
    }

    @Test
    func `An http og:image coerces to an https media ref, a plain url field keeps its scheme`() throws {
        // Viltrox's Shopify theme publishes `og:image` as plain http (the https
        // twin sits only in og:image:secure_url); ATS refuses the http fetch
        // in the host app, so media refs upgrade at coercion. `url` fields are
        // opened, not fetched, and stay as written.
        let html = """
        <html><head>
          <meta property="og:image" content="http://viltrox.com/cdn/shop/files/9mm.png?v=1" />
          <meta property="og:url" content="http://viltrox.com/products/af-9mm-f2-8-xf" />
        </head></html>
        """
        let context = ELVExtractionContext(
            url: URL(string: "https://viltrox.com/products/af-9mm-f2-8-xf"),
            params: [:],
            document: ELVDocument(html: html)
        )
        let fields = [
            ELVFieldSpec(name: "image", candidates: [
                ELVCandidate(from: .meta("og:image"), pipes: [.resolveURL], coercion: ELVCoercion(kind: "image")),
            ]),
            ELVFieldSpec(name: "link", candidates: [
                ELVCandidate(from: .meta("og:url"), coercion: ELVCoercion(kind: "url")),
            ]),
        ]
        let result = ELVExtractor.extract(fields: fields, context: context)
        let image = try #require(URL(string: "https://viltrox.com/cdn/shop/files/9mm.png?v=1"))
        let link = try #require(URL(string: "http://viltrox.com/products/af-9mm-f2-8-xf"))
        #expect(result.values["image"] == .media(ELVMediaRef(url: image, kind: ELVMediaRef.image)))
        #expect(result.values["link"] == .url(link))
    }

    @Test
    func `The plan's title field decodes from pack JSON and evaluates`() throws {
        let wire = """
        [
          {"name": "title", "candidates": [
            {"from": {"css": "h1"}, "pipe": ["trim", "collapseWhitespace"]},
            {"from": {"jsonld": "TouristAttraction.name"}},
            {"from": {"meta": "og:title"}, "pipe": [{"stripSuffix": " | AllTrails"}]},
            {"from": {"urlParam": "slug"}, "pipe": ["slugToTitle"]}
          ]}
        ]
        """
        let fields = try JSONDecoder().decode([ELVFieldSpec].self, from: Data(wire.utf8))
        #expect(fields.first?.candidates.count == 4)
        let result = try ELVExtractor.extract(fields: fields, context: makeContext())
        #expect(result.values["title"] == .text("Hidden Falls Trail"))

        var noDocument = try makeContext()
        noDocument.document = ELVDocument()
        let slugOnly = ELVExtractor.extract(fields: fields, context: noDocument)
        #expect(slugOnly.values["title"] == .text("Hidden Falls Trail"))
        #expect(slugOnly.provenance["title"]?.origin == "urlParam:slug")
    }

    @Test
    func `URL query and regex selectors read the input URL`() throws {
        var context = try makeContext()
        context.url = URL(string: "https://www.booking.com/hotel/us/zephyr.html?checkin=2026-09-01&checkout=2026-09-04")
        let fields = [
            ELVFieldSpec(name: "checkin", candidates: [
                ELVCandidate(from: .urlQuery("checkin"), coercion: ELVCoercion(kind: "date")),
            ]),
            ELVFieldSpec(name: "country", candidates: [
                ELVCandidate(from: .urlRegex("/hotel/([a-z]{2})/")),
            ]),
        ]
        let result = ELVExtractor.extract(fields: fields, context: context)
        #expect(result.values["checkin"] == .date(Date(timeIntervalSince1970: 1_788_220_800), precision: .day))
        #expect(result.values["country"] == .text("us"))
    }

    @Test
    func `A field missing its candidates key decodes to an empty list instead of killing the source`() throws {
        let wire = """
        [
          {"name": "broken"},
          {"name": "title", "candidates": [{"from": {"meta": "og:title"}}]}
        ]
        """
        let fields = try JSONDecoder().decode([ELVFieldSpec].self, from: Data(wire.utf8))
        #expect(fields.first?.candidates.isEmpty == true)
        let result = try ELVExtractor.extract(fields: fields, context: makeContext())
        #expect(result.values["broken"] == nil)
        #expect(result.values["title"] == .text("Hidden Falls Trail"))
    }

    @Test
    func `matchRegex and regexReplace stay correct and case-insensitive through the regex cache`() throws {
        var context = try makeContext()
        context.url = URL(string: "https://www.imdb.com/title/tt0111161/")
        let fields = [
            ELVFieldSpec(name: "id", candidates: [
                ELVCandidate(from: .urlRegex("tt(\\d+)"), pipes: [.regexReplace(pattern: "^0+", template: "")]),
            ]),
        ]
        // Twice: the second run exercises the cache-hit path.
        for _ in 0 ..< 2 {
            let result = ELVExtractor.extract(fields: fields, context: context)
            #expect(result.values["id"] == .text("111161"))
        }
        // URL/text regex selectors were always `.caseInsensitive`; the cache
        // routing must preserve that.
        let upper = [ELVFieldSpec(name: "id", candidates: [ELVCandidate(from: .urlRegex("TT(\\d+)"))])]
        #expect(ELVExtractor.extract(fields: upper, context: context).values["id"] == .text("0111161"))
    }

    @Test
    func `The resolveURL pipe rejects javascript and data schemes`() throws {
        let context = try makeContext()
        #expect(ELVPipe.resolveURL.apply(.string("javascript:alert(1)"), context: context) == nil)
        #expect(ELVPipe.resolveURL.apply(.string("data:text/html;base64,AAAA"), context: context) == nil)
        #expect(ELVPipe.resolveURL.apply(.string("//cdn.example.com/a.jpg"), context: context) == .string("https://cdn.example.com/a.jpg"))
        #expect(ELVPipe.resolveURL.apply(.string("/img/a.jpg"), context: context) == .string("https://www.alltrails.com/img/a.jpg"))
    }

    @Test
    func `Candidates decode from the pack grammar`() throws {
        // Decode-only by design: the pack grammar flows one way (authored,
        // compiled, decoded here), so there is no encoder to round-trip.
        let wire = #"""
        [
          {"from": {"meta": "og:price"}, "pipe": ["trim"], "as": "money", "currency": "USD", "currencyFrom": {"meta": "product:price:currency"}},
          {"from": {"css": "img.cover", "attr": "@src"}, "as": "image"},
          {"from": {"native": "trail.statsFromText@2", "input": {"text": "$field.headerText"}}},
          {"from": {"urlRegex": "tt(\\d+)"}, "pipe": [{"regexReplace": ["^0+", ""]}, {"take": 3}]},
          {"from": {"jsonld": "Product.aggregateRating.ratingValue"}, "as": "rating", "scale": {"min": 0, "max": 10}}
        ]
        """#
        let decoded = try JSONDecoder().decode([ELVCandidate].self, from: Data(wire.utf8))
        #expect(decoded == [
            ELVCandidate(from: .meta("og:price"), pipes: [.trim], coercion: ELVCoercion(kind: "money", currency: "USD", currencyFrom: .meta("product:price:currency"))),
            ELVCandidate(from: .css(selector: "img.cover", attr: "@src"), coercion: ELVCoercion(kind: "image")),
            ELVCandidate(from: .native(op: "trail.statsFromText@2", input: ["text": "$field.headerText"])),
            ELVCandidate(from: .urlRegex("tt(\\d+)"), pipes: [.regexReplace(pattern: "^0+", template: ""), .take(3)]),
            ELVCandidate(from: .jsonld("Product.aggregateRating.ratingValue"), coercion: ELVCoercion(kind: "rating", scaleMin: 0, scaleMax: 10)),
        ])
    }

    @Test
    func `The regex cache keeps serving matches past its eviction capacity`() {
        // FIFO eviction smoke: overflow the pattern capacity and confirm
        // every pattern still compiles and matches (evicted ones recompile).
        for index in 0 ..< 300 {
            #expect(ELVRegexCache.matches("needle\(index)", in: "prefix needle\(index) suffix"))
        }
        #expect(ELVRegexCache.matches("needle0", in: "needle0 again"))
    }

    @Test
    func `The regex input cap still matches within the bound on large bodies`() {
        let body = "hay " + String(repeating: "x", count: ELVRegexCache.inputCap + 40000) + " needle"
        #expect(ELVRegexCache.matches("hay", in: body))
        #expect(!ELVRegexCache.matches("needle", in: body, cap: ELVRegexCache.inputCap))
        #expect(ELVRegexCache.boundedInput(body).count == ELVRegexCache.inputCap)
        #expect(ELVRegexCache.boundedInput("short") == "short")
    }

    @Test
    func `An invalid pack pattern is a cached negative entry`() {
        #expect(ELVRegexCache.regex("([") == nil)
        #expect(ELVRegexCache.regex("([") == nil)
        #expect(!ELVRegexCache.matches("([", in: "(["))
        #expect(ELVRegexCache.regex("a+") != nil)
    }

    @Test
    func `select belongs on the candidate; inside from it makes the selector unsupported`() throws {
        let inFrom = try JSONDecoder().decode(ELVSelector.self, from: Data(#"{"json": "$.x", "select": "y"}"#.utf8))
        #expect(inFrom == .unsupported(key: "json+select"))
        let candidate = try JSONDecoder().decode(ELVCandidate.self, from: Data(#"{"from": {"native": "op@1"}, "select": "y"}"#.utf8))
        #expect(candidate.from == .native(op: "op@1", input: [:]))
        #expect(candidate.select == "y")
    }

    @Test
    func `regexReplace runs over the bounded head and keeps the tail verbatim`() throws {
        let context = try makeContext()
        let pipe = ELVPipe.regexReplace(pattern: "a", template: "b")
        #expect(pipe.apply(.string("banana"), context: context) == .string("bbnbnb"))
        let head = String(repeating: "a", count: ELVRegexCache.inputCap)
        let result = pipe.apply(.string(head + "TAIL-a"), context: context)
        #expect(result == .string(String(repeating: "b", count: ELVRegexCache.inputCap) + "TAIL-a"))
    }

    @Test
    func `The sync and async extraction walks agree on a sync-only fixture`() async throws {
        // The mirrors' drift canary: change both or neither.
        let fields = [
            ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .meta("og:title"))]),
            ELVFieldSpec(name: "echo", candidates: [ELVCandidate(from: .field("title"))]),
            ELVFieldSpec(name: "missing", candidates: [ELVCandidate(from: .meta("nope"))]),
        ]
        let context = ELVExtractionContext(document: ELVDocument(metas: ["og:title": "Same"]))
        let sync = ELVExtractor.extract(fields: fields, context: context)
        let asyncResult = try await ELVExtractor.extractAsync(fields: fields, context: context)
        #expect(sync == asyncResult)
        #expect(sync.values["echo"] == .text("Same"))
    }
}

/// Counts op invocations from inside `@Sendable` op closures.
private final class CallCounter: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

/// A multi-output native op runs once per extraction for each distinct input
/// set, however many fields `select` from it.
@Suite("Native op memo")
struct ELVNativeOpMemoTests {
    private static func selecting(_ op: String, _ outputs: [String], input: [String: String] = [:]) -> [ELVFieldSpec] {
        outputs.map { ELVFieldSpec(name: $0, candidates: [ELVCandidate(from: .native(op: op, input: input), select: $0)]) }
    }

    @Test
    func `A sync op selected by several fields runs once per input set`() {
        let calls = CallCounter()
        ELVNativeOps.register("test.memo.sync", version: 1) { input, _ in
            calls.increment()
            return ["a": .text("A" + (input["k"] ?? "")), "b": .text("B"), "c": .number(3)]
        }
        // A bare reference and its explicit @1 are one op to the memo.
        let fields = Self.selecting("test.memo.sync@1", ["a", "b"]) + Self.selecting("test.memo.sync", ["c"])
        let result = ELVExtractor.extract(fields: fields, context: ELVExtractionContext())
        #expect(result.values == ["a": .text("A"), "b": .text("B"), "c": .number(3)])
        #expect(calls.value == 1)

        // A different resolved input is a different run.
        let keyed = Self.selecting("test.memo.sync@1", ["a"], input: ["k": "1"]) + Self.selecting("test.memo.sync@1", ["b"], input: ["k": "2"])
        _ = ELVExtractor.extract(fields: keyed, context: ELVExtractionContext())
        #expect(calls.value == 3)
    }

    @Test
    func `An async op selected by several fields runs once, and a thrown failure is recorded once`() async throws {
        let calls = CallCounter()
        ELVNativeOps.registerAsync("test.memo.async", version: 1) { _, _ in
            calls.increment()
            return ["address": .text("1 Trail Rd"), "phone": .text("+1 555")]
        }
        let result = try await ELVExtractor.extractAsync(fields: Self.selecting("test.memo.async@1", ["address", "phone"]), context: ELVExtractionContext())
        #expect(result.values == ["address": .text("1 Trail Rd"), "phone": .text("+1 555")])
        #expect(calls.value == 1)

        let failures = CallCounter()
        ELVNativeOps.registerAsync("test.memo.throwing", version: 1) { _, _ in
            failures.increment()
            throw URLError(.timedOut)
        }
        let failed = try await ELVExtractor.extractAsync(fields: Self.selecting("test.memo.throwing@1", ["address", "phone"]), context: ELVExtractionContext())
        #expect(failed.values.isEmpty)
        #expect(failures.value == 1)
        #expect(failed.nativeOpFailures.map(\.field) == ["address"])
    }
}

@Suite("Document regex input")
struct ELVDocumentRegexInputTests {
    @Test
    func `textRegex reads text before html, and a reassigned text replaces the cached input`() {
        let field = [ELVFieldSpec(name: "v", candidates: [ELVCandidate(from: .textRegex("value=(\\w+)"))])]
        var document = ELVDocument(text: "value=first", html: "<p>value=html</p>")
        #expect(ELVExtractor.extract(fields: field, context: ELVExtractionContext(document: document)).values["v"] == .text("first"))
        document.text = "value=second"
        #expect(ELVExtractor.extract(fields: field, context: ELVExtractionContext(document: document)).values["v"] == .text("second"))
        document.text = nil
        #expect(ELVExtractor.extract(fields: field, context: ELVExtractionContext(document: document)).values["v"] == .text("html"))
        // Equality ignores what a copy happened to cache.
        #expect(ELVDocument(text: "a") == ELVDocument(text: "a"))
    }

    @Test
    func `textRegex scans at most the input cap of a large page`() {
        let page = String(repeating: "x", count: ELVRegexCache.inputCap) + "value=late"
        let field = [ELVFieldSpec(name: "v", candidates: [ELVCandidate(from: .textRegex("value=(\\w+)"))])]
        #expect(ELVExtractor.extract(fields: field, context: ELVExtractionContext(document: ELVDocument(html: page))).values["v"] == nil)
    }

    @Test
    func `A textRegex after anchor starts the capped window at the anchor, past a decoy and past the cap`() {
        // A Six Flags ride page keeps its data blob ~640 KB in, behind a
        // decoy of the same shape (a related ride's card) and the cap.
        let page = "value=decoy " + String(repeating: "x", count: ELVRegexCache.inputCap) + "{blob:value=late}"
        func value(after: String?) -> ELVValue? {
            let field = [ELVFieldSpec(name: "v", candidates: [ELVCandidate(from: .textRegex("value=(\\w+)", after: after))])]
            return ELVExtractor.extract(fields: field, context: ELVExtractionContext(document: ELVDocument(html: page))).values["v"]
        }
        #expect(value(after: nil) == .text("decoy"))
        #expect(value(after: "{blob:") == .text("late"))
        // An anchor that never appears is a miss, not a scan from the top.
        #expect(value(after: "{nowhere:") == nil)
        #expect(value(after: "") == nil)
    }

    @Test
    func `A scanned document carries its link tags`() {
        let html = #"<head><link rel="alternate" type="application/rss+xml" href="/feed.xml"><link rel="canonical" href="https://a.example/x"></head>"#
        #expect(ELVDocument(html: html).links == [
            ELVHTMLLink(rel: "alternate", href: "/feed.xml", type: "application/rss+xml"),
            ELVHTMLLink(rel: "canonical", href: "https://a.example/x"),
        ])
        #expect(ELVDocument(html: html).links == ELVHTMLScanner.scan(html).links)
    }
}
