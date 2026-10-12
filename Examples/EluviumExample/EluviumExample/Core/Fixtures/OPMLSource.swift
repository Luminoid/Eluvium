import EluviumCore
import Foundation

/// The OPML subscription-list source: the universal export every
/// feed reader and podcast app speaks. App-local like the other archive
/// sources — file-input config is consumer-authored; the reader, the
/// `opml` format, and the `contains` content probe live in the framework.
/// Each row is a `feed` record whose `url` field is the subscription's
/// feed URL, so an entry chains straight into `generic.feed`.
enum OPMLSource {
    static let source = ELVSource(
        id: "opml.subscriptions",
        title: "OPML subscriptions",
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

    /// Real, live feeds (the same ones the starter pack's corpus pins), so
    /// an imported row's `url` resolves through `generic.feed` when pasted.
    static let sampleOPML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <opml version="2.0">
      <head><title>Subscriptions</title></head>
      <body>
        <outline text="Blogs">
          <outline text="Daring Fireball" type="rss" xmlUrl="https://daringfireball.net/feeds/main" htmlUrl="https://daringfireball.net/"/>
          <outline text="xkcd" type="rss" xmlUrl="https://xkcd.com/rss.xml" htmlUrl="https://xkcd.com/"/>
          <outline text="Swift.org" type="rss" xmlUrl="https://www.swift.org/atom.xml" htmlUrl="https://www.swift.org/"/>
        </outline>
        <outline text="Podcasts">
          <outline text="This American Life" type="rss" xmlUrl="https://www.thisamericanlife.org/podcast/rss.xml"/>
        </outline>
      </body>
    </opml>
    """
}
