import Foundation
import Testing
@testable import EluviumCore

@Suite("Feed normalization")
struct ELVFeedNormalizerTests {
    // MARK: - RSS 2.0

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
    func `RSS 2.0 with itunes and podcast namespaces folds into the envelope`() throws {
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(rssPodcast.utf8)))
        #expect(envelope.title == "Under the Radar")
        #expect(envelope.language == "en-us")
        #expect(envelope.podcastGuid == "8e2f0c6a-1111-5b2a-9c33-abcdef012345")
        #expect(envelope.image == "https://cdn.example/radar.jpg")
        #expect(envelope.items.count == 2)

        let first = try #require(envelope.items.first)
        #expect(first.externalId == "radar-300")
        #expect(first.title == "300: Three Hundred")
        #expect(first.contentHTML == "<p>Rich <b>HTML</b> body.</p>")
        #expect(first.enclosure?.url == "https://cdn.example/300.mp3")
        #expect(first.enclosure?.lengthBytes == 42_000_000)
        #expect(first.durationSeconds == 3723)
        #expect(first.episode == 300)
        #expect(first.season == 1)
        #expect(first.explicit == false)
    }

    @Test
    func `Podcasting 2.0 tags fold in: transcripts by preference, chapters, funding, itunes:type`() throws {
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(rssPodcast.utf8)))
        // Channel level: itunes:type validates and lowercases; funding
        // carries both the URL attribute and the label text.
        #expect(envelope.itunesType == "serial")
        #expect(envelope.fundingURL == "https://support.example/radar")
        #expect(envelope.fundingLabel == "Support the show")

        let first = try #require(envelope.items.first)
        #expect(first.chaptersURL == "https://cdn.example/300.chapters.json")
        // Document order keeps both renditions; preference picks VTT over
        // the SRT that appears first.
        #expect(first.transcripts.map(\.url) == ["https://cdn.example/300.srt", "https://cdn.example/300.vtt"])
        #expect(first.preferredTranscript?.url == "https://cdn.example/300.vtt")
        #expect(first.preferredTranscript?.language == "en")
        // The second item declares none: no keys, no phantom transcript.
        let second = try #require(envelope.items.last)
        #expect(second.transcripts.isEmpty)
        #expect(second.chaptersURL == nil)

        // The envelope seam exposes the typed conveniences packs select on.
        let json = envelope.asRawJSON()
        #expect(json["itunesType"]?.stringValue == "serial")
        #expect(json["fundingURL"]?.stringValue == "https://support.example/radar")
        let firstNode = try #require(json["items"]?.arrayValue?.first)
        #expect(firstNode["transcriptURL"]?.stringValue == "https://cdn.example/300.vtt")
        #expect(firstNode["transcripts"]?.arrayValue?.count == 2)
        #expect(firstNode["chaptersURL"]?.stringValue == "https://cdn.example/300.chapters.json")
    }

    @Test
    func `Both itunes:duration forms parse (HH:MM:SS and bare seconds)`() throws {
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(rssPodcast.utf8)))
        #expect(envelope.items[0].durationSeconds == 3723)
        #expect(envelope.items[1].durationSeconds == 2940)
        #expect(ELVFeedNormalizer.durationSeconds("45:10") == 2710)
        #expect(ELVFeedNormalizer.durationSeconds("bogus") == nil)
    }

    @Test
    func `ISO 8601 itunes:duration forms parse (PT45M)`() throws {
        let feed = """
        <rss version="2.0"><channel><title>ISO Duration</title>
          <item><guid>iso-1</guid><itunes:duration>PT45M</itunes:duration></item>
        </channel></rss>
        """
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(feed.utf8)))
        #expect(envelope.items.first?.durationSeconds == 2700)
        #expect(ELVFeedNormalizer.durationSeconds("PT1H2M3S") == 3723)
        // Hostile clock arithmetic is bounded instead of overflowing.
        #expect(ELVFeedNormalizer.durationSeconds("9223372036854775807:00") == nil)
    }

    @Test
    func `RFC 822 dates normalize to ISO 8601`() throws {
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(rssPodcast.utf8)))
        let published = try #require(envelope.items.first?.published)
        #expect(ISO8601DateFormatter().date(from: published) != nil)
    }

    @Test
    func `RFC 822 and ISO dates both normalize to one canonical ISO form`() {
        #expect(ELVFeedNormalizer.normalizeDate("Mon, 04 Aug 2026 12:00:00 GMT") == "2026-08-04T12:00:00Z")
        #expect(ELVFeedNormalizer.normalizeDate("2026-08-04T12:00:00+00:00") == "2026-08-04T12:00:00Z")
        #expect(ELVFeedNormalizer.normalizeDate("2026-08-04T08:00:00-04:00") == "2026-08-04T12:00:00Z")
        // Unparseable strings pass through verbatim (better than dropping).
        #expect(ELVFeedNormalizer.normalizeDate("sometime last Tuesday") == "sometime last Tuesday")
        #expect(ELVFeedNormalizer.normalizeDate("   ") == nil)
    }

    // MARK: - Atom

    private let atom = """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Daring Fireball</title>
      <subtitle>By John Gruber</subtitle>
      <link href="https://daringfireball.net/" rel="alternate"/>
      <link href="https://daringfireball.net/feeds/main" rel="self"/>
      <entry>
        <title>A Post</title>
        <id>tag:daringfireball.net,2026:/linked//6.42000</id>
        <link href="https://daringfireball.net/linked/2026/08/11/a-post" rel="alternate"/>
        <published>2026-08-11T10:30:00Z</published>
        <updated>2026-08-11T11:00:00Z</updated>
        <author><name>John Gruber</name></author>
        <summary>Short summary.</summary>
      </entry>
    </feed>
    """

    @Test
    func `Atom feeds normalize, using the id when no guid exists`() throws {
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(atom.utf8)))
        #expect(envelope.title == "Daring Fireball")
        #expect(envelope.feedDescription == "By John Gruber")
        #expect(envelope.link == "https://daringfireball.net/")
        let entry = try #require(envelope.items.first)
        #expect(entry.externalId == "tag:daringfireball.net,2026:/linked//6.42000")
        #expect(entry.link == "https://daringfireball.net/linked/2026/08/11/a-post")
        #expect(entry.authors == ["John Gruber"])
        #expect(entry.published == "2026-08-11T10:30:00Z")
    }

    @Test
    func `Atom category terms and RSS category text both become tags`() throws {
        let atomFeed = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Tagged</title>
          <entry>
            <id>tag-1</id>
            <category term="apple" label="Apple"/>
            <category term="ios"/>
          </entry>
        </feed>
        """
        let atomEnvelope = try #require(ELVFeedNormalizer.normalize(Data(atomFeed.utf8)))
        #expect(atomEnvelope.items.first?.tags == ["apple", "ios"])

        let rssFeed = """
        <rss version="2.0"><channel><title>R</title>
          <item><guid>r-1</guid><category>Tech</category><category term="term-wins">Text</category></item>
        </channel></rss>
        """
        let rssEnvelope = try #require(ELVFeedNormalizer.normalize(Data(rssFeed.utf8)))
        #expect(rssEnvelope.items.first?.tags == ["Tech", "term-wins"])
    }

    @Test
    func `Atom logo maps to the envelope image`() {
        let feed = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Logo</title>
          <logo>https://cdn.example/logo.png</logo>
          <entry><id>lg-1</id></entry>
        </feed>
        """
        #expect(ELVFeedNormalizer.normalize(Data(feed.utf8))?.image == "https://cdn.example/logo.png")
    }

    @Test
    func `Root xml:lang backstops a missing language element`() {
        let atomFeed = """
        <feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-GB">
          <title>Lang</title>
          <entry><id>l-1</id></entry>
        </feed>
        """
        #expect(ELVFeedNormalizer.normalize(Data(atomFeed.utf8))?.language == "en-GB")
        // An explicit RSS <language> element still wins over the root attribute.
        let rssFeed = """
        <rss version="2.0" xml:lang="fr"><channel><title>R</title><language>en-us</language></channel></rss>
        """
        #expect(ELVFeedNormalizer.normalize(Data(rssFeed.utf8))?.language == "en-us")
    }

    @Test
    func `A bare name outside an author block does not become an author`() throws {
        let feed = """
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Gated</title>
          <item>
            <guid>g-1</guid>
            <author>real@example.com (Real Author)</author>
            <podcast:person role="host"><name>Leaky Person</name></podcast:person>
          </item>
        </channel></rss>
        """
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(feed.utf8)))
        #expect(envelope.items.first?.authors == ["real@example.com (Real Author)"])
    }

    // MARK: - JSON Feed

    private let jsonFeed = """
    {
      "version": "https://jsonfeed.org/version/1.1",
      "title": "inessential",
      "home_page_url": "https://inessential.com/",
      "feed_url": "https://inessential.com/feed.json",
      "language": "en-US",
      "items": [
        {
          "id": "https://inessential.com/2026/08/11/a",
          "url": "https://inessential.com/2026/08/11/a",
          "title": "A JSON Feed Post",
          "content_html": "<p>Body</p>",
          "date_published": "2026-08-11T09:00:00-04:00",
          "authors": [{"name": "Brent Simmons"}],
          "tags": ["feeds", "json"]
        }
      ]
    }
    """

    @Test
    func `JSON Feed 1.1 normalizes into the same envelope`() throws {
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(jsonFeed.utf8)))
        #expect(envelope.title == "inessential")
        #expect(envelope.link == "https://inessential.com/")
        #expect(envelope.language == "en-US")
        let item = try #require(envelope.items.first)
        #expect(item.externalId == "https://inessential.com/2026/08/11/a")
        #expect(item.title == "A JSON Feed Post")
        #expect(item.contentHTML == "<p>Body</p>")
        #expect(item.authors == ["Brent Simmons"])
        #expect(item.tags == ["feeds", "json"])
    }

    private let jsonFeedLegacy = """
    {
      "version": "https://jsonfeed.org/version/1",
      "title": "Legacy &amp; Modern",
      "items": [
        {
          "id": "legacy-1",
          "title": "Solo&rsquo;s Post",
          "date_published": "Mon, 03 Aug 2026 08:00:00 GMT",
          "date_modified": "2026-08-04T05:00:00-04:00",
          "author": {"name": "Solo Author"},
          "attachments": [{"url": "https://cdn.example/a.mp3", "mime_type": "audio/mpeg", "size_in_bytes": 1e300, "duration_in_seconds": 90}]
        },
        {
          "id": "legacy-2",
          "attachments": [{"duration_in_seconds": 125}]
        }
      ]
    }
    """

    @Test
    func `JSON Feed 1.0 forms map: singular author, date_modified, decoupled duration`() throws {
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(jsonFeedLegacy.utf8)))
        #expect(envelope.title == "Legacy & Modern")
        let first = try #require(envelope.items.first)
        #expect(first.authors == ["Solo Author"])
        #expect(first.title == "Solo\u{2019}s Post")
        #expect(first.published == "2026-08-03T08:00:00Z")
        #expect(first.updated == "2026-08-04T09:00:00Z")
        // The hostile 1e300 size clamps to nil instead of trapping on Int conversion.
        #expect(first.enclosure?.url == "https://cdn.example/a.mp3")
        #expect(first.enclosure?.lengthBytes == nil)
        #expect(first.durationSeconds == 90)
        // Duration no longer requires a mapped enclosure.
        let second = try #require(envelope.items.last)
        #expect(second.enclosure == nil)
        #expect(second.durationSeconds == 125)
    }

    @Test
    func `A hostile attachment duration is bounded like every duration leaf`() throws {
        let json = """
        {"version": "https://jsonfeed.org/version/1.1", "title": "F", "items": [
          {"id": "1", "attachments": [{"url": "https://cdn.example/a.mp3", "duration_in_seconds": 1e300}]},
          {"id": "2", "attachments": [{"url": "https://cdn.example/b.mp3", "duration_in_seconds": -5}]},
          {"id": "3", "attachments": [{"url": "https://cdn.example/c.mp3", "duration_in_seconds": 125}]}
        ]}
        """
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(json.utf8)))
        #expect(envelope.items.map(\.durationSeconds) == [nil, nil, 125])
        // Hosts build enclosures by hand through the public initializer.
        let enclosure = ELVFeedEnvelope.Enclosure(url: "https://cdn.example/x.mp3")
        #expect(enclosure.type == nil && enclosure.lengthBytes == nil)
    }

    // MARK: - Entity decoding

    @Test
    func `Double-escaped entities decode in titles and summaries but never in content HTML`() throws {
        let feed = """
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel>
          <title>News &amp;amp; Views</title>
          <description>All the news that&amp;rsquo;s fit</description>
          <item>
            <guid>e-1</guid>
            <title>Cats &amp;amp; Dogs</title>
            <description>It&amp;#8217;s fine</description>
            <content:encoded>Keep &amp;amp; verbatim</content:encoded>
          </item>
        </channel></rss>
        """
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(feed.utf8)))
        #expect(envelope.title == "News & Views")
        #expect(envelope.feedDescription == "All the news that\u{2019}s fit")
        let item = try #require(envelope.items.first)
        #expect(item.title == "Cats & Dogs")
        #expect(item.summary == "It\u{2019}s fine")
        // contentHTML is HTML by contract: one XML unescape only.
        #expect(item.contentHTML == "Keep &amp; verbatim")
    }

    // MARK: - Item identity ladder

    @Test
    func `The item-identity ladder falls through guid → id → enclosure → link → hash`() {
        #expect(ELVFeedNormalizer.itemIdentity(guid: "g", atomId: "a", jsonId: nil, enclosureURL: "e", link: "l", title: "t", published: "p", ordinal: 0) == "g")
        #expect(ELVFeedNormalizer.itemIdentity(guid: nil, atomId: "a", jsonId: nil, enclosureURL: "e", link: "l", title: "t", published: "p", ordinal: 0) == "a")
        #expect(ELVFeedNormalizer.itemIdentity(guid: nil, atomId: nil, jsonId: nil, enclosureURL: "e", link: "l", title: "t", published: "p", ordinal: 0) == "e")
        #expect(ELVFeedNormalizer.itemIdentity(guid: nil, atomId: nil, jsonId: nil, enclosureURL: nil, link: "l", title: "t", published: "p", ordinal: 0) == "l")
        let hashed = ELVFeedNormalizer.itemIdentity(guid: nil, atomId: nil, jsonId: nil, enclosureURL: nil, link: nil, title: "t", published: "p", ordinal: 0)
        #expect(hashed.hasPrefix("hash:"))
        // Stable across calls (not process-seeded) and across positions: the
        // ordinal never leaks into a well-formed item's identity.
        #expect(hashed == ELVFeedNormalizer.itemIdentity(guid: nil, atomId: nil, jsonId: nil, enclosureURL: nil, link: nil, title: "t", published: "p", ordinal: 9))
    }

    @Test
    func `Fully-empty items key by position instead of collapsing into one hash`() throws {
        let empty0 = ELVFeedNormalizer.itemIdentity(guid: nil, atomId: nil, jsonId: nil, enclosureURL: nil, link: nil, title: nil, published: nil, ordinal: 0)
        let empty1 = ELVFeedNormalizer.itemIdentity(guid: nil, atomId: nil, jsonId: nil, enclosureURL: nil, link: nil, title: nil, published: nil, ordinal: 1)
        #expect(empty0 != empty1)
        #expect(empty0.hasPrefix("hash:") && empty1.hasPrefix("hash:"))

        let degenerate = """
        <rss version="2.0"><channel><title>Degenerate</title>
          <item></item>
          <item></item>
        </channel></rss>
        """
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(degenerate.utf8)))
        #expect(envelope.items.count == 2)
        #expect(envelope.items[0].externalId != envelope.items[1].externalId)

        // Well-formed items keep their ladder identity regardless of position.
        let podcast = try #require(ELVFeedNormalizer.normalize(Data(rssPodcast.utf8)))
        #expect(podcast.items.map(\.externalId) == ["radar-300", "radar-299"])
    }

    // MARK: - Envelope → pack seam

    @Test
    func `The envelope projects to raw JSON that pack json-selectors read`() throws {
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(rssPodcast.utf8)))
        let root = envelope.asRawJSON()
        #expect(ELVJSONPath("$.title").first(root) == .string("Under the Radar"))
        #expect(ELVJSONPath("$.podcastGuid").first(root) == .string("8e2f0c6a-1111-5b2a-9c33-abcdef012345"))
        #expect(ELVJSONPath("$.items[0].externalId").first(root) == .string("radar-300"))
        #expect(ELVJSONPath("$.items[0].durationSeconds").first(root) == .number(3723))
        #expect(ELVJSONPath("$.items[*].title").evaluate(root).count == 2)
    }

    @Test
    func `A podcast source over the envelope assembles a show record with an episode collection`() throws {
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(rssPodcast.utf8)))
        let source = ELVSource(
            id: "podcast.show",
            kind: "podcast",
            fields: [ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))])],
            collections: [
                ELVCollectionSpec(name: "episodes", from: .json("$.items[*]"), item: [
                    ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.externalId"))]),
                    ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))]),
                    ELVFieldSpec(name: "audio", candidates: [ELVCandidate(from: .json("$.enclosure.url"), coercion: ELVCoercion(kind: "url"))]),
                    ELVFieldSpec(name: "duration", candidates: [ELVCandidate(from: .json("$.durationSeconds"), coercion: ELVCoercion(kind: "duration"))]),
                ], kind: "episode"),
            ],
            identities: [ELVIdentitySpec(namespace: "podcast.guid", from: .json("$.podcastGuid"))]
        )
        let context = ELVExtractionContext(document: ELVDocument(json: envelope.asRawJSON()))
        let record = ELVAssembler.assemble(source: source, context: context)
        #expect(record.fields["title"] == .text("Under the Radar"))
        #expect(record.identities.first?.namespace == "podcast.guid")
        let episodes = try #require(record.collections["episodes"])
        #expect(episodes.count == 2)
        #expect(episodes.first?.externalId == "radar-300")
        #expect(episodes.first?.fields["duration"] == .duration(3723))
    }

    // MARK: - Hardening

    @Test
    func `Malformed and non-feed inputs fail gracefully`() {
        #expect(ELVFeedNormalizer.normalize(Data("not xml or json".utf8)) == nil)
        #expect(ELVFeedNormalizer.normalize(Data("".utf8)) == nil)
        // A BOM-prefixed feed still parses — the byte sniff skips BOM + whitespace.
        let bommed = "\u{FEFF}" + rssPodcast
        #expect(ELVFeedNormalizer.normalize(Data(bommed.utf8))?.title == "Under the Radar")
        let bommedJSON = Data([0xEF, 0xBB, 0xBF] + Array("  \n".utf8) + Array(jsonFeed.utf8))
        #expect(ELVFeedNormalizer.normalize(bommedJSON)?.title == "inessential")
    }

    @Test
    func `Undeclared namespace prefixes fall back to local-name matching`() throws {
        let feed = """
        <rss version="2.0">
          <channel>
            <title>Bare</title>
            <item>
              <title>Episode</title>
              <guid>bare-1</guid>
              <itunes:duration>10:00</itunes:duration>
            </item>
          </channel>
        </rss>
        """
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(feed.utf8)))
        #expect(envelope.items.first?.durationSeconds == 600)
    }

    @Test
    func `RFC 5005 rel-next survives in RSS via atom:link and in Atom alike`() throws {
        let rss = """
        <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Paged</title>
        <atom:link rel="self" href="https://example.com/feed"/>
        <atom:link rel="next" href="https://example.com/feed?page=2"/>
        <item><title>One</title></item></channel></rss>
        """
        let rssEnvelope = try #require(ELVFeedNormalizer.normalize(Data(rss.utf8)))
        #expect(rssEnvelope.nextURL == "https://example.com/feed?page=2")

        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Paged</title>
        <link rel="next" href="https://example.com/atom?page=2"/>
        <entry><title>E</title><id>e1</id></entry></feed>
        """
        let atomEnvelope = try #require(ELVFeedNormalizer.normalize(Data(atom.utf8)))
        #expect(atomEnvelope.nextURL == "https://example.com/atom?page=2")
        // rel="next" is pagination, not the feed's alternate link.
        #expect(atomEnvelope.link != "https://example.com/atom?page=2")
    }

    @Test
    func `The show author folds from itunes:author and JSON Feed top-level authors, next_url beside it`() throws {
        let rss = """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
        <title>Show</title><itunes:author>WNYC Studios</itunes:author>
        <item><title>Ep</title><itunes:author>Guest Author</itunes:author></item></channel></rss>
        """
        let envelope = try #require(ELVFeedNormalizer.normalize(Data(rss.utf8)))
        #expect(envelope.author == "WNYC Studios")
        #expect(envelope.items.first?.authors == ["Guest Author"])

        let json = """
        {"version": "https://jsonfeed.org/version/1.1", "title": "F",
         "authors": [{"name": "Brent"}],
         "next_url": "https://example.com/feed.json?page=2",
         "items": [{"id": "1"}]}
        """
        let jsonEnvelope = try #require(ELVFeedNormalizer.normalize(Data(json.utf8)))
        #expect(jsonEnvelope.author == "Brent")
        #expect(jsonEnvelope.nextURL == "https://example.com/feed.json?page=2")
    }

    @Test
    func `The envelope's raw JSON exposes author and nextURL for pack selection`() {
        var envelope = ELVFeedEnvelope(title: "T")
        envelope.author = "A"
        envelope.nextURL = "https://example.com/page2"
        let root = envelope.asRawJSON()
        #expect(root["author"] == .string("A"))
        #expect(root["nextURL"] == .string("https://example.com/page2"))
    }

    @Test
    func `Only audio or typeless enclosures earn the typed enclosureAudioURL`() throws {
        func item(withEnclosureType type: String?) throws -> ELVRawJSON {
            let typeAttr = type.map { " type=\"\($0)\"" } ?? ""
            let rss = """
            <?xml version="1.0"?><rss version="2.0"><channel><title>T</title>
            <item><title>E</title><enclosure url="https://cdn.example/media.bin"\(typeAttr) length="1"/></item>
            </channel></rss>
            """
            let envelope = try #require(ELVFeedNormalizer.normalize(Data(rss.utf8)))
            return try #require(envelope.asRawJSON()["items"]?.arrayValue?.first)
        }
        // audio/* qualifies; typeless qualifies (many podcast feeds omit the
        // MIME); an image enclosure must never grow a Play button (D1b).
        #expect(try item(withEnclosureType: "audio/mpeg")["enclosureAudioURL"] == .string("https://cdn.example/media.bin"))
        #expect(try item(withEnclosureType: nil)["enclosureAudioURL"] == .string("https://cdn.example/media.bin"))
        #expect(try item(withEnclosureType: "image/png")["enclosureAudioURL"] == nil)
        #expect(try item(withEnclosureType: "image/png")["enclosure"]?["url"] == .string("https://cdn.example/media.bin"))
    }
}
