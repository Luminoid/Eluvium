import Foundation
import Testing
@testable import EluviumCore

@Suite("HTML scanning")
struct ELVHTMLScannerTests {
    private let html = """
    <!DOCTYPE html>
    <html><head>
      <title>  Hidden Falls Trail &#8211; AllTrails  </title>
      <meta property="og:title" content="Hidden Falls Trail" />
      <meta property="og:title" content="A Duplicate That Must Not Win" />
      <meta content='USD' property='product:price:currency'/>
      <meta name="description" content="Tom &amp; Jerry&#8217;s trail">
      <link rel="alternate" type="application/rss+xml" href="/feed.xml">
      <script type="application/ld+json">
        {"@context": "https://schema.org", "@graph": [
          {"@type": "BreadcrumbList", "itemListElement": []},
          {"@type": "Product", "name": "Trail Poles", "offers": {"price": "49.99", "priceCurrency": "USD"}}
        ]}
      </script>
      <script type="application/ld+json">not json at all</script>
    </head><body><h1>Hidden Falls</h1></body></html>
    """

    @Test
    func `Metas parse across attribute orders and quote styles, first occurrence wins, entities decode`() {
        let result = ELVHTMLScanner.scan(html)
        #expect(result.metas["og:title"] == "Hidden Falls Trail")
        #expect(result.metas["product:price:currency"] == "USD")
        #expect(result.metas["description"] == "Tom & Jerry\u{2019}s trail")
    }

    @Test
    func `The title decodes entities and collapses whitespace`() {
        #expect(ELVHTMLScanner.scan(html).title == "Hidden Falls Trail \u{2013} AllTrails")
    }

    @Test
    func `JSON-LD islands parse, @graph flattens, and junk islands are skipped`() {
        let nodes = ELVHTMLScanner.scan(html).jsonLDNodes
        #expect(nodes.count == 2)
        #expect(nodes.last?["name"] == .string("Trail Poles"))
    }

    @Test
    func `Feed links surface for autodiscovery`() {
        let links = ELVHTMLScanner.scan(html).links
        #expect(links.contains { $0.rel == "alternate" && $0.href == "/feed.xml" && $0.type == "application/rss+xml" })
    }

    @Test
    func `Pathologically nested JSON-LD stops flattening at the depth cap`() {
        // Attacker-controlled nesting: flattening recursion is capped, so a
        // deep array wrapper surfaces as one (array) node instead of
        // recursing per level.
        let nested = String(repeating: "[", count: 200) + "{\"@type\": \"Product\", \"name\": \"Deep\"}" + String(repeating: "]", count: 200)
        let page = "<html><head><script type=\"application/ld+json\">\(nested)</script></head></html>"
        let nodes = ELVHTMLScanner.scan(page).jsonLDNodes
        #expect(nodes.count == 1)
        #expect(nodes.first?.arrayValue != nil)

        // Within the cap, wrappers still flatten to the member node.
        let shallow = "<html><head><script type=\"application/ld+json\">[[{\"@type\": \"Product\", \"name\": \"Near\"}]]</script></head></html>"
        #expect(ELVHTMLScanner.scan(shallow).jsonLDNodes.first?["name"] == .string("Near"))
    }
}

@Suite("JSON islands")
struct ELVJSONIslandTests {
    @Test
    func `A script island parses by id; absent or malformed islands yield nil`() {
        let html = """
        <html><head>
        <script id="__NEXT_DATA__" type="application/json">{"props": {"n": 7}}</script>
        <script id="broken" type="application/json">{nope</script>
        </head><body></body></html>
        """
        #expect(ELVHTMLScanner.jsonIsland(id: "__NEXT_DATA__", in: html)?["props"]?["n"] == .number(7))
        #expect(ELVHTMLScanner.jsonIsland(id: "missing", in: html) == nil)
        #expect(ELVHTMLScanner.jsonIsland(id: "broken", in: html) == nil)
    }

    @Test
    func `The island id is escaped, never interpreted as a pattern`() {
        let html = #"<script id="data(1)" type="application/json">{"ok": true}</script>"#
        #expect(ELVHTMLScanner.jsonIsland(id: "data(1)", in: html)?["ok"] == .bool(true))
        #expect(ELVHTMLScanner.jsonIsland(id: "data.1.", in: html) == nil)
    }
}

/// Hostile pages: thousands of unclosed opens over megabytes must scan in
/// linear time. Each input here took minutes under the old `[^>]*` and
/// lazy-`.*?` patterns (and still did with only a `{0,4096}` length bound).
@Suite("HTML scanning on hostile input")
struct ELVHTMLScannerHostileInputTests {
    private static let size = 2_000_000

    @Test
    func `Two megabytes of unclosed meta, link, title, and JSON-LD opens scan quickly`() {
        let pages = [
            String(repeating: "<meta ", count: Self.size / 6),
            String(repeating: "<link a=\"", count: Self.size / 9),
            String(repeating: "<title>", count: Self.size / 7),
            String(repeating: "<script type=\"application/ld+json\">", count: Self.size / 35),
            String(repeating: "<script type=\"application/ld+json\"></script", count: Self.size / 43),
            // One closed tag holding a two-megabyte run of name characters:
            // the attribute walk used to retry the name from every letter.
            "<meta " + String(repeating: "a", count: Self.size) + ">",
            "<link rel=\"icon\" " + String(repeating: "data-x", count: Self.size / 6) + ">",
        ]
        for page in pages {
            let elapsed = ContinuousClock().measure { _ = ELVHTMLScanner.scan(page) }
            #expect(elapsed < .seconds(5), "\(page.prefix(12)): \(elapsed)")
        }
    }

    @Test
    func `A title still reads after a page of stray opens, and a missing close yields none`() {
        #expect(ELVHTMLScanner.scan("<title>Falls &amp; Lake</title>").title == "Falls & Lake")
        #expect(ELVHTMLScanner.scan("<head><title>Unclosed").title == nil)
        let meta = String(repeating: "<meta ", count: 1000) + #"<meta property="og:title" content="Kept">"#
        #expect(ELVHTMLScanner.scan(meta).metas["og:title"] == "Kept")
    }
}
