import Foundation
import Testing
@testable import EluviumCore

@Suite("Article body extraction")
struct ELVArticleBodyTests {
    /// A realistic article page: chrome on every side, one real body.
    private let articlePage = """
    <html><head><title>T</title><script>var fake = "<p>fake paragraph that must never leak, ever, at all</p>";</script></head>
    <body>
      <header><p>A header tagline that is long enough to score if it ever counted, which it must not.</p></header>
      <nav><a href="/a">Home</a><a href="/b">Archive</a><a href="/c">About</a></nav>
      <div class="sidebar">
        <p><a href="/1">A related story link with plenty of words in it, padded out</a></p>
        <p><a href="/2">Another related story link with plenty of words in it, padded</a></p>
      </div>
      <article class="post">
        <h2>The heading of the piece, descriptive and reasonably long</h2>
        <p>First paragraph of the body, with commas, clauses, and enough length to score like real prose would in any feed reader worth using.</p>
        <p>Second paragraph continues the argument, adds detail, and keeps the text mass climbing so the container comfortably clears the floor.</p>
        <script>trackPageView("<div>not content</div>");</script>
        <p>Third paragraph closes the piece, ties the threads together, and gives the scorer the comma density real writing always has.</p>
      </article>
      <div class="comments" id="disqus">
        <p>A commenter opines briefly here.</p>
      </div>
      <footer><p>Copyright notice, unsubscribe links, and other chrome that must stay out of the body.</p></footer>
    </body></html>
    """

    @Test
    func `The article container wins and its inner HTML comes back cleaned of scripts`() throws {
        let extraction = try #require(ELVArticleBody.extract(html: articlePage))
        #expect(extraction.html.contains("First paragraph of the body"))
        #expect(extraction.html.contains("Third paragraph closes the piece"))
        #expect(extraction.html.contains("<h2>"))
        // Chrome stays out: header, nav, sidebar, comments, footer.
        #expect(!extraction.html.contains("header tagline"))
        #expect(!extraction.html.contains("related story"))
        #expect(!extraction.html.contains("commenter opines"))
        #expect(!extraction.html.contains("Copyright notice"))
        // The in-article script strips from the output.
        #expect(!extraction.html.contains("trackPageView"))
        #expect(!extraction.html.contains("fake paragraph"))
        #expect(extraction.textLength > 250)
    }

    @Test
    func `Link farms and thin pages yield nothing`() {
        let linkFarm = """
        <body><div class="content">
          <p><a href="/1">Every single word of this paragraph lives inside an anchor tag, so it is navigation, not prose.</a></p>
          <p><a href="/2">The same is true here, a wall of linked text with no running body copy anywhere around it at all.</a></p>
          <p><a href="/3">And again, a third linked row, which a scorer must refuse to mistake for an article body.</a></p>
        </div></body>
        """
        #expect(ELVArticleBody.extract(html: linkFarm) == nil)
        #expect(ELVArticleBody.extract(html: "<body><p>Too short to matter.</p></body>") == nil)
        #expect(ELVArticleBody.extract(html: "") == nil)
    }

    @Test
    func `Script content with fake close tags cannot derail the scan`() throws {
        let page = """
        <body><script>if (a<b) { render("</div></article>"); }</script>
        <article><p>Real prose follows the hostile script, with commas, structure, and the length real paragraphs have when written by people.</p>
        <p>A second paragraph keeps the mass above the floor, because one alone would not reach the threshold the extractor enforces.</p>
        <p>And a third rounds it out, so the article body scores the way ordinary published writing does on any weblog.</p></article></body>
        """
        let extraction = try #require(ELVArticleBody.extract(html: page))
        #expect(extraction.html.contains("Real prose follows"))
        #expect(!extraction.html.contains("render("))
    }

    @Test
    func `Mis-nested containers close down to the matching tag instead of corrupting ranges`() throws {
        let page = """
        <body><div class="post-content"><section><p>Paragraph one of the mis-nested page, long enough to score on its own,
        with commas, clauses, and the ordinary running mass of prose a published article carries in its opening.</p>
        <p>Paragraph two continues at the same length, unbothered by the stray close tag that follows it in the markup
        below this line, and keeps the section's text mass safely above the extractor's floor.</p>
        </div>
        <p>Paragraph three sits outside after the early close, still counted where the stack says it belongs, with commas too.</p></body>
        """
        // The section never closes; the div's close pops both. No crash, a
        // winner still emerges.
        let extraction = try #require(ELVArticleBody.extract(html: page))
        #expect(extraction.html.contains("Paragraph one"))
    }
}

@Suite("HTML content cleanup")
struct ELVHTMLCleanupTests {
    @Test
    func `htmlStrip removes tag, class, id, and tag-class selectors with balanced nesting`() {
        let html = """
        <div class="body"><p>Keep me.</p>
        <div class="ads"><div class="inner">Nested ad copy</div><span>more ad</span></div>
        <aside id="promo"><p>Promo text</p></aside>
        <figure class="share-bar"><a>share</a></figure>
        <p>Also keep me.</p></div>
        """
        let stripped = ELVHTMLCleanup.strip(html, selectors: [".ads", "#promo", "figure.share-bar"])
        #expect(stripped.contains("Keep me."))
        #expect(stripped.contains("Also keep me."))
        // The nested inner div did not fool the balance walk into an early stop.
        #expect(!stripped.contains("Nested ad copy"))
        #expect(!stripped.contains("more ad"))
        #expect(!stripped.contains("Promo text"))
        #expect(!stripped.contains("share"))

        // Bare-tag selectors take whole elements; unparseable ones are no-ops.
        #expect(ELVHTMLCleanup.strip("<p>a</p><iframe src=\"x\">junk</iframe>", selectors: ["iframe"]) == "<p>a</p>")
        let unparseable = ELVHTMLCleanup.strip(html, selectors: ["", "div .x", ".a.b"])
        #expect(unparseable == html)
        // A class token matches word-wise, not by substring.
        #expect(ELVHTMLCleanup.strip("<div class=\"adsense\">keep</div>", selectors: [".ads"]).contains("keep"))
    }

    @Test
    func `rewriteLazyImages promotes data-src over placeholders and fills missing srcset`() {
        let lazy = "<img class=\"lazy\" src=\"data:image/gif;base64,R0lGOD\" data-src=\"https://cdn.example/real.jpg\">"
        #expect(ELVHTMLCleanup.rewriteLazyImages(lazy).contains("src=\"https://cdn.example/real.jpg\""))

        let missing = "<p>text</p><img data-original=\"https://cdn.example/orig.jpg\" alt=\"x\">"
        #expect(ELVHTMLCleanup.rewriteLazyImages(missing).contains("<img src=\"https://cdn.example/orig.jpg\""))

        let real = "<img src=\"https://cdn.example/already.jpg\" data-src=\"https://cdn.example/other.jpg\">"
        #expect(ELVHTMLCleanup.rewriteLazyImages(real) == real)

        let srcset = "<img src=\"https://cdn.example/a.jpg\" data-srcset=\"https://cdn.example/a-2x.jpg 2x\">"
        #expect(ELVHTMLCleanup.rewriteLazyImages(srcset).contains("srcset=\"https://cdn.example/a-2x.jpg 2x\""))
    }

    @Test
    func `The cleanup pipes decode and apply`() throws {
        let strip = try JSONDecoder().decode(ELVPipe.self, from: Data(#"{"htmlStrip": [".ads", "iframe"]}"#.utf8))
        #expect(strip == .htmlStrip([".ads", "iframe"]))
        let lazy = try JSONDecoder().decode(ELVPipe.self, from: Data(#""rewriteLazyImages""#.utf8))
        #expect(lazy == .rewriteLazyImages)

        let context = ELVExtractionContext()
        let cleaned = strip.apply(.string("<p>keep</p><div class=\"ads\">x</div>"), context: context)
        #expect(cleaned == .string("<p>keep</p>"))

        // Both forms decode side by side in one pipe list.
        let list = try JSONDecoder().decode([ELVPipe].self, from: Data(#"[{"htmlStrip": [".ads", "iframe"]}, "rewriteLazyImages"]"#.utf8))
        #expect(list == [.htmlStrip([".ads", "iframe"]), .rewriteLazyImages])
    }
}

/// Hostile pages for the cleanup pipes and the article scan: unclosed tags,
/// quotes, and comments by the hundred thousand finish in linear time.
@Suite("Content cleanup on hostile input")
struct ELVContentCleanupHostileInputTests {
    private static let size = 2_000_000

    @Test
    func `htmlStrip and rewriteLazyImages stay linear over unclosed tags and quotes`() {
        // A `>` first, so the engine cannot rule the pattern out up front;
        // the possessive-only cleanup pattern took ~100 s on 200 KB of this.
        let quotes = ">" + String(repeating: "<a '", count: Self.size / 4)
        let images = ">" + String(repeating: "<img '", count: Self.size / 6)
        for page in [quotes, images] {
            let elapsed = ContinuousClock().measure {
                _ = ELVHTMLCleanup.strip(page, selectors: [".ads", "div"])
                _ = ELVHTMLCleanup.rewriteLazyImages(page)
            }
            #expect(elapsed < .seconds(5), "\(page.prefix(8)): \(elapsed)")
        }
    }

    @Test
    func `The cleanup pipes rewrite the bounded head and keep the tail verbatim`() {
        let head = "<div class=\"ads\">x</div>" + String(repeating: "a", count: ELVRegexCache.inputCap)
        let tail = "<div class=\"ads\">kept past the cap</div>"
        let stripped = ELVHTMLCleanup.strip(head + tail, selectors: [".ads"])
        #expect(stripped.hasPrefix("aaa"))
        #expect(stripped.hasSuffix(tail))
        #expect(stripped.count == head.count + tail.count - "<div class=\"ads\">x</div>".count)
        let lazy = ELVHTMLCleanup.rewriteLazyImages(String(repeating: "b", count: ELVRegexCache.inputCap) + "<img data-src=\"/late.jpg\">")
        #expect(lazy.hasSuffix("<img data-src=\"/late.jpg\">"))
    }

    @Test
    func `The article scan stays linear over unclosed comments, tags, and deep nesting`() {
        let prose = "<p>" + String(repeating: "A long sentence of article prose, with commas, that scores. ", count: 8) + "</p>"
        let pages = [
            String(repeating: "<!--", count: Self.size / 4) + "<article>" + prose + "</article>",
            String(repeating: "<div ", count: Self.size / 5),
            String(repeating: "<div>", count: 300_000) + prose,
            "<article>" + prose + String(repeating: "<script>", count: 100_000) + "</article>",
        ]
        for page in pages {
            let elapsed = ContinuousClock().measure { _ = ELVArticleBody.extract(html: page) }
            #expect(elapsed < .seconds(10), "\(page.prefix(8)): \(elapsed)")
        }
    }

    @Test
    func `Comments are skipped whole, an unclosed comment is not one, and nesting past the cap still extracts`() throws {
        let prose = "<p>" + String(repeating: "A long sentence of article prose, with commas, that scores. ", count: 8) + "</p>"
        let commented = try #require(ELVArticleBody.extract(html: "<article><!-- <p>" + String(repeating: "hidden, ", count: 50) + "</p> -->" + prose + "</article>"))
        #expect(!commented.html.contains("hidden"))
        #expect(commented.textLength == ELVArticleBody.extract(html: "<article>" + prose + "</article>")?.textLength)

        let strayOpen = try #require(ELVArticleBody.extract(html: "<!-- stray <article>" + prose + "</article>"))
        #expect(strayOpen.html.contains("A long sentence"))

        let deep = String(repeating: "<div>", count: 600) + prose + String(repeating: "</div>", count: 600)
        let nested = try #require(ELVArticleBody.extract(html: deep))
        #expect(nested.html.contains("A long sentence"))
    }
}
