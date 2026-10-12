import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The generic floors' field mappings over engine fixtures: the one place
/// engine-level fixtures meet catalog content. Lives here, not in
/// EluviumCoreTests, so the engine's suite links no sources.
@Suite("Starter floor mappings")
struct ELVStarterFloorMappingTests {
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

    private let rssPodcast = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
      <channel>
        <title>Under the Radar</title>
        <description>A podcast about being an indie developer.</description>
        <link>https://www.relay.fm/radar</link>
        <language>en-us</language>
        <podcast:guid>8e2f0c6a-1111-5b2a-9c33-abcdef012345</podcast:guid>
        <itunes:type>Serial</itunes:type>
        <podcast:funding url="https://support.example/radar">Support the show</podcast:funding>
        <image><url>https://cdn.example/radar.jpg</url></image>
        <item>
          <title>300: Three Hundred</title>
          <description>Milestone episode.</description>
          <content:encoded><![CDATA[<p>Rich <b>HTML</b> body.</p>]]></content:encoded>
          <guid isPermaLink="false">radar-300</guid>
          <pubDate>Mon, 04 Aug 2026 12:00:00 GMT</pubDate>
          <enclosure url="https://cdn.example/300.mp3" type="audio/mpeg" length="42000000"/>
          <podcast:transcript url="https://cdn.example/300.srt" type="application/srt"/>
          <podcast:transcript url="https://cdn.example/300.vtt" type="text/vtt" language="en"/>
          <podcast:chapters url="https://cdn.example/300.chapters.json" type="application/json+chapters"/>
          <itunes:duration>1:02:03</itunes:duration>
          <itunes:episode>300</itunes:episode>
          <itunes:season>1</itunes:season>
          <itunes:explicit>no</itunes:explicit>
        </item>
        <item>
          <title>299: Prior</title>
          <guid isPermaLink="false">radar-299</guid>
          <pubDate>Mon, 21 Jul 2026 12:00:00 GMT</pubDate>
          <enclosure url="https://cdn.example/299.mp3" type="audio/mpeg" length="0"/>
          <itunes:duration>2940</itunes:duration>
        </item>
      </channel>
    </rss>
    """

    @Test
    func `The registered op serves the generic floor's content field, and thin pages skip it`() throws {
        let pack = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom", "composite"], binaryVersion: "0.1"))
        #expect(ELVNativeOps.isRegistered("article.bodyFromPage@1"))
        let source = try #require(pack.source(withId: "generic.opengraph"))
        let url = try #require(URL(string: "https://blog.example/post"))

        let article = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument(html: articlePage)))
        let content = try #require(article.fields["content"])
        #expect(ELVValueDisplay.string(content).contains("First paragraph of the body"))

        let thin = ELVAssembler.assemble(
            source: source,
            context: ELVExtractionContext(url: url, document: ELVDocument(html: "<html><head><meta property=\"og:title\" content=\"Shop\"/></head><body><p>Buy now.</p></body></html>"))
        )
        #expect(thin.fields["content"] == nil)
        #expect(thin.fields["title"] == .text("Shop"))
    }

    @Test
    func `generic.feed maps funding, show type, transcript, and chapters into the record`() throws {
        let pack = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
        let source = try #require(pack.source(withId: "generic.feed"))
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(rssPodcast.utf8)))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(document: ELVDocument(json: envelope.asRawJSON())))

        #expect(try record.fields["funding"] == .url(#require(URL(string: "https://support.example/radar"))))
        #expect(record.fields["fundingLabel"] == .text("Support the show"))
        #expect(record.fields["showType"] == .text("serial"))
        let items = try #require(record.collections["items"])
        let first = try #require(items.first)
        #expect(try first.fields["transcript"] == .url(#require(URL(string: "https://cdn.example/300.vtt"))))
        #expect(try first.fields["chapters"] == .url(#require(URL(string: "https://cdn.example/300.chapters.json"))))
        let second = try #require(items.last)
        #expect(second.fields["transcript"] == nil)
        #expect(second.fields["chapters"] == nil)
    }
}
