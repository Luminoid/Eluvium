import Foundation
import Testing
@testable import EluviumCore

@Suite("OPML subscription lists")
struct ELVOPMLReaderTests {
    private let opml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <opml version="2.0">
      <head><title>Subscriptions</title></head>
      <body>
        <outline text="News &amp; Ideas">
          <outline text="Daring Fireball" title="Daring Fireball" type="rss" xmlUrl="https://daringfireball.net/feeds/main" htmlUrl="https://daringfireball.net/"/>
          <outline text="xkcd" type="rss" xmlURL="https://xkcd.com/rss.xml"/>
        </outline>
        <outline text="Podcasts">
          <outline text="Under the Radar" type="rss" xmlurl="https://www.relay.fm/radar/feed"/>
        </outline>
        <outline text="A note without a feed"/>
      </body>
    </opml>
    """

    private let opmlSource = ELVSource(
        id: "opml.subscriptions",
        kind: "feed",
        match: ELVMatchRule(file: ELVFileMatchRule(name: "*.opml", contains: ["<opml"])),
        fetch: ELVFetchPlan(mode: "archive", format: "opml"),
        rows: [
            ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.feedUrl"))]),
            ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))]),
            ELVFieldSpec(name: "url", candidates: [ELVCandidate(from: .json("$.feedUrl"), coercion: ELVCoercion(kind: "url"))]),
            ELVFieldSpec(name: "site", candidates: [ELVCandidate(from: .json("$.htmlUrl"), coercion: ELVCoercion(kind: "url"))]),
            ELVFieldSpec(name: "group", candidates: [ELVCandidate(from: .json("$.group"))]),
        ]
    )

    @Test
    func `Outlines with xmlUrl in any casing parse; groups nest; notes are skipped`() throws {
        let subscriptions = try #require(ELVOPMLReader.parse(opml))
        #expect(subscriptions.count == 3)
        #expect(subscriptions.map(\.feedURL) == [
            "https://daringfireball.net/feeds/main",
            "https://xkcd.com/rss.xml",
            "https://www.relay.fm/radar/feed",
        ])
        // The entity-bearing group title decodes; the group path follows nesting.
        #expect(subscriptions[0].group == "News & Ideas")
        #expect(subscriptions[2].group == "Podcasts")
        #expect(subscriptions[0].siteURL == "https://daringfireball.net/")
        #expect(subscriptions[1].title == "xkcd")
        // Not OPML at all: nil, distinct from an empty subscription list.
        #expect(ELVOPMLReader.parse("<rss><channel/></rss>") == nil)
        #expect(ELVOPMLReader.parse("<opml version=\"1.0\"><body/></opml>") == [])
    }

    @Test
    func `An OPML file imports one feed record per subscription, chaining by url`() throws {
        let records = try ELVArchiveImporter.importRecords(source: opmlSource, fileName: "Subscriptions.opml", data: Data(opml.utf8))
        #expect(records.count == 3)
        #expect(records.first?.kind == "feed")
        #expect(records.first?.externalId == "https://daringfireball.net/feeds/main")
        #expect(records.first?.fields["title"] == .text("Daring Fireball"))
        // The member url is what lets an entry drill into generic.feed.
        #expect(try records.first?.fields["url"] == .url(#require(URL(string: "https://daringfireball.net/feeds/main"))))
        #expect(records.first?.fields["group"] == .text("News & Ideas"))
    }

    @Test
    func `The contains probe gates recognition and import for non-OPML bytes`() {
        let data = Data(opml.utf8)
        #expect(ELVFileRecognizer.recognize(fileName: "Subscriptions.opml", data: data, sources: [opmlSource])?.id == "opml.subscriptions")
        let notOPML = Data("<html><body>nope</body></html>".utf8)
        #expect(ELVFileRecognizer.recognize(fileName: "Subscriptions.opml", data: notOPML, sources: [opmlSource]) == nil)
        #expect(throws: ELVArchiveImporter.Failure.formatMismatch(expected: "<opml")) {
            try ELVArchiveImporter.importRecords(source: opmlSource, fileName: "Subscriptions.opml", data: notOPML)
        }
    }
}
