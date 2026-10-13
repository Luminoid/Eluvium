import EluviumCore
import Foundation
import LumiKitUI
import Testing
import UIKit
import WebKit
@testable import EluviumExample

/// The pure affordance reading over record shapes, the item window, and
/// the item browser's use of both.
@Suite("Record browsing")
@MainActor
struct RecordBrowsingTests {
    @Test
    func `The record window reveals in pages and extends for fetched next pages`() {
        var window = RecordWindow(total: 45, pageSize: 20)
        let items = Array(1 ... 45)
        #expect(Array(window.visible(of: items)) == Array(1 ... 20))
        #expect(window.hasMore)
        window.revealMore()
        #expect(window.visible(of: items).count == 40)
        window.revealMore()
        #expect(window.visible(of: items).count == 45)
        #expect(!window.hasMore)
        // A fetched next page appended 30 more: the reveal point holds and
        // the new items sit behind one more tap.
        window.extend(total: 75)
        #expect(window.hasMore)
        #expect(window.visible(of: Array(1 ... 75)).count == 45)

        let tiny = RecordWindow(total: 3, pageSize: 20)
        #expect(!tiny.hasMore)
        #expect(Array(tiny.visible(of: [1, 2, 3])) == [1, 2, 3])
    }

    @Test
    func `The feed items screen windows its rows twenty at a time`() {
        var parent = ELVRecord(sourceId: "s", kind: "feed")
        parent.fields["title"] = .text("Feed")
        let items = (1 ... 48).map { index -> ELVRecord in
            var item = ELVRecord(sourceId: "s", kind: "post")
            item.fields["title"] = .text("Item \(index)")
            return item
        }
        let screen = FeedItemsViewController(parent: parent, collectionName: "items", items: items)
        screen.loadViewIfNeeded()
        #expect(screen.tableView(UITableView(), numberOfRowsInSection: 0) == 20)
    }

    @Test
    func `Feed rows without a body or member link report no selection affordance`() throws {
        var parent = ELVRecord(sourceId: "s", kind: "feed")
        parent.fields["title"] = .text("Feed")
        var dead = ELVRecord(sourceId: "s", kind: "post")
        dead.fields["title"] = .text("Dead end")
        var linked = ELVRecord(sourceId: "s", kind: "post")
        linked.fields["title"] = .text("Linked")
        linked.fields["url"] = try .url(#require(URL(string: "https://example.com/entry")))

        let screen = FeedItemsViewController(parent: parent, collectionName: "items", items: [dead, linked])
        screen.loadViewIfNeeded()
        let table = UITableView()
        table.register(UITableViewCell.self, forCellReuseIdentifier: LMKListTable.cellReuseIdentifier)
        table.registerStaticRows()
        let deadCell = screen.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))
        #expect(deadCell.selectionStyle == .none)
        // Static rows come from their own pool and never get the hover.
        #expect(deadCell.reuseIdentifier == UITableView.staticRowReuseIdentifier)
        #expect(!deadCell.lmk_hasRowPointerInteraction)
        let linkedCell = screen.tableView(table, cellForRowAt: IndexPath(row: 1, section: 0))
        #expect(linkedCell.selectionStyle == .default)
        #expect(linkedCell.reuseIdentifier == LMKListTable.cellReuseIdentifier)
    }

    @Test
    func `Audio rows keep the play accessory in the cell's trailing slot`() throws {
        var album = ELVRecord(sourceId: "s", kind: "album")
        album.fields["title"] = .text("OK Computer")
        let tracks = (1 ... 3).map { index -> ELVRecord in
            var track = ELVRecord(sourceId: "s", kind: "song")
            track.fields["title"] = .text("Track \(index)")
            track.fields["artist"] = .text("Radiohead")
            if let url = URL(string: "https://media.example/preview-\(index).mp3") {
                track.fields["audio"] = .media(ELVMediaRef(url: url, kind: ELVMediaRef.audio))
            }
            return track
        }
        let screen = FeedItemsViewController(parent: album, collectionName: "tracks", items: tracks)
        screen.loadViewIfNeeded()

        // The cell frame-lays its accessory out, so the accessory must keep
        // its autoresizing translation. The app's theme floors every button
        // with a constraint on the button itself, which turns that
        // translation off: a bare button as the accessory drifted to the
        // cell's top-left and re-dirtied the cell's layout on every pass.
        // `#require`, not `#expect`: laying such a cell out spins forever,
        // so a regression must end the test here, not hang the suite.
        let probe = UITableView()
        probe.register(UITableViewCell.self, forCellReuseIdentifier: LMKListTable.cellReuseIdentifier)
        probe.registerStaticRows()
        let probeCell = screen.tableView(probe, cellForRowAt: IndexPath(row: 1, section: 0))
        let probeAccessory = try #require(probeCell.accessoryView)
        try #require(probeAccessory.translatesAutoresizingMaskIntoConstraints)
        let host = try #require(probeAccessory as? AccessoryButtonStack)
        try #require(host.buttons.allSatisfy { $0.superview === host })

        // Laid out at phone width, the accessory sits in the trailing slot,
        // vertically centered, at the 44pt touch target.
        let pageView = screen.view ?? UIView()
        pageView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        pageView.layoutIfNeeded()
        let table = try #require(pageView.subviews.compactMap { $0 as? UITableView }.first)
        let cell = try #require(table.cellForRow(at: IndexPath(row: 1, section: 0)))
        let accessory = try #require(cell.accessoryView as? AccessoryButtonStack)
        #expect(accessory.frame.minX > cell.bounds.midX, "\(accessory.frame)")
        #expect(accessory.frame.maxX <= cell.bounds.maxX, "\(accessory.frame)")
        #expect(abs(accessory.frame.midY - cell.bounds.midY) < 1, "\(accessory.frame) in \(cell.bounds)")
        #expect(accessory.frame.width >= LMKLayout.minimumTouchTarget)
        #expect(accessory.frame.height >= LMKLayout.minimumTouchTarget)
        let button = try #require(accessory.buttons.first)
        #expect(button.accessibilityLabel == "Play Track 2")
        #expect(button.tag == 1)
    }

    @Test
    func `Hostile numbers never trap the integer displays`() {
        // 1e300 is ordinary JSON; NaN and infinity reach a record through
        // hand-built values. Each must skip its part, not trap `Int(_:)`.
        for hostile in [1e300, -1e300, .infinity, -.infinity, .nan, 9.2e18] {
            #expect(RecordBrowsing.displayInteger(hostile) == nil, "\(hostile)")
            var entry = ELVRecord(sourceId: "s", kind: "movie")
            entry.fields["rank"] = .number(hostile)
            entry.fields["year"] = .number(hostile)
            entry.fields["artist"] = .text("Artist")
            #expect(RecordBrowsing.rowSecondary(for: entry) == "Artist")
        }
        #expect(RecordBrowsing.displayInteger(2024) == 2024)
        #expect(RecordBrowsing.displayInteger(-3.9) == -3)

        // The item browser's header and cap note read `episodeCount`.
        var show = ELVRecord(sourceId: "s", kind: "podcast")
        show.fields["title"] = .text("Show")
        show.fields["episodeCount"] = .number(1e300)
        let screen = FeedItemsViewController(parent: show, collectionName: "items", items: [ELVRecord(sourceId: "s", kind: "episode")])
        screen.loadViewIfNeeded()
        #expect(screen.tableView(UITableView(), numberOfRowsInSection: 0) == 1)
    }

    @Test
    func `Record browsing reads typed audio, feed chains, member links, and detail bodies`() throws {
        let audioURL = try #require(URL(string: "https://media.example/e1.m4a"))
        let feedURL = try #require(URL(string: "https://feeds.example/rss"))
        let memberURL = try #require(URL(string: "https://www.imdb.com/title/tt15398776/"))

        var episode = ELVRecord(sourceId: "s", kind: "episode")
        episode.fields["audio"] = .media(ELVMediaRef(url: audioURL, kind: ELVMediaRef.audio))
        episode.fields["summary"] = .text("<p>Show   notes</p>")
        #expect(RecordBrowsing.audioURL(of: episode) == audioURL)
        #expect(RecordBrowsing.hasDetailBody(episode))
        #expect(RecordBrowsing.rowSecondary(for: episode) == "Show notes")

        var show = ELVRecord(sourceId: "s", kind: "podcast")
        show.fields["feedUrl"] = .url(feedURL)
        #expect(RecordBrowsing.feedURL(of: show) == feedURL)
        #expect(RecordBrowsing.audioURL(of: show) == nil)

        var entry = ELVRecord(sourceId: "s", kind: "movie")
        entry.fields["url"] = .url(memberURL)
        entry.fields["year"] = .number(2024)
        entry.fields["rank"] = .number(3)
        #expect(RecordBrowsing.memberURL(of: entry) == memberURL)
        #expect(!RecordBrowsing.hasDetailBody(entry))
        #expect(RecordBrowsing.rowSecondary(for: entry) == "No. 3\(Separator.dot)2024")

        // Durations render through the package's one spelling.
        var timed = ELVRecord(sourceId: "s", kind: "episode")
        timed.fields["duration"] = .duration(3725)
        #expect(RecordBrowsing.rowSecondary(for: timed) == ELVValueDisplay.duration(3725))
        #expect(ELVValueDisplay.duration(65) == "1m 5s")
        #expect(RecordBrowsing.snippet("plain words only", limit: 5) == "plain…")
    }

    @Test
    func `Next-page pointers and dedup keys read the strongest handle a row offers`() throws {
        let next = try #require(URL(string: "https://feeds.example/rss?page=2"))
        var feed = ELVRecord(sourceId: "s", kind: "feed")
        #expect(RecordBrowsing.nextPage(of: feed) == nil)
        feed.fields["nextPage"] = .url(next)
        #expect(RecordBrowsing.nextPage(of: feed) == next)

        let audioURL = try #require(URL(string: "https://media.example/e1.m4a"))
        let memberURL = try #require(URL(string: "https://example.com/post"))
        var item = ELVRecord(sourceId: "s", kind: "post")
        #expect(RecordBrowsing.dedupKey(item) == nil)
        item.fields["title"] = .text("Hello")
        #expect(RecordBrowsing.dedupKey(item) == "title:Hello")
        item.fields["link"] = .url(memberURL)
        #expect(RecordBrowsing.dedupKey(item) == "url:\(memberURL.absoluteString)")
        item.fields["audio"] = .media(ELVMediaRef(url: audioURL, kind: ELVMediaRef.audio))
        #expect(RecordBrowsing.dedupKey(item) == "audio:\(audioURL.absoluteString)")
        item.externalId = "e1"
        #expect(RecordBrowsing.dedupKey(item) == "id:e1")
    }

    @Test
    func `Display title prefers the label, then the title, and stays nil without either`() {
        var record = ELVRecord(sourceId: "s", kind: "post")
        #expect(record.displayTitle == nil)
        record.fields["title"] = .text("Grand Prismatic")
        #expect(record.displayTitle == "Grand Prismatic")
        record.fields["label"] = .text("Grand Prismatic Spring")
        #expect(record.displayTitle == "Grand Prismatic Spring")
    }

    @Test
    func `Detail body HTML prefers content and accepts markup-bearing summaries`() {
        var post = ELVRecord(sourceId: "s", kind: "post")
        post.fields["content"] = .text("<p>Full post</p>")
        post.fields["summary"] = .text("short")
        #expect(RecordBrowsing.detailHTML(of: post) == "<p>Full post</p>")

        // The xkcd shape: no content:encoded, the whole comic rides in
        // description as one img tag — it must render, not tag-strip away.
        let comicBody = #"<img src="https://imgs.xkcd.com/comics/x.png" alt="Alt text" />"#
        var comic = ELVRecord(sourceId: "s", kind: "post")
        comic.fields["summary"] = .text(comicBody)
        #expect(RecordBrowsing.detailHTML(of: comic) == comicBody)

        var plain = ELVRecord(sourceId: "s", kind: "post")
        plain.fields["summary"] = .text("No markup here, and 5 < 10 is not a tag.")
        #expect(RecordBrowsing.detailHTML(of: plain) == nil)
        #expect(RecordBrowsing.detailHTML(of: ELVRecord(sourceId: "s", kind: "post")) == nil)

        #expect(RecordBrowsing.snippet("Fish &amp; Chips&nbsp;&#39;shop&#39;", limit: 120) == "Fish & Chips 'shop'")
    }

    @Test
    func `The feed reader renders only its own body and sends other loads through the egress policy`() throws {
        let base = try #require(URL(string: "https://example.com/post/1"))
        typealias Reader = FeedItemDetailViewController
        // The reader's own loadHTMLString: its base URL, or about:blank.
        #expect(Reader.readerDecision(for: base, type: .other, isMainFrame: true, bodyBaseURL: base) == .allow)
        #expect(Reader.readerDecision(for: URL(string: "about:blank"), type: .other, isMainFrame: true, bodyBaseURL: nil) == .allow)
        // A meta refresh never takes the main frame anywhere else.
        #expect(Reader.readerDecision(for: URL(string: "https://elsewhere.example/"), type: .other, isMainFrame: true, bodyBaseURL: base) == .cancel)
        // Subframes (an embedded player) load only what the policy allows.
        #expect(Reader.readerDecision(for: URL(string: "https://www.youtube.com/embed/x"), type: .other, isMainFrame: false, bodyBaseURL: base) == .allow)
        #expect(Reader.readerDecision(for: URL(string: "http://192.168.0.1/admin"), type: .other, isMainFrame: false, bodyBaseURL: base) == .cancel)
        #expect(Reader.readerDecision(for: URL(string: "https://localhost/x"), type: .other, isMainFrame: false, bodyBaseURL: base) == .cancel)
        // Tapped links: web links leave for the browser; other schemes go nowhere.
        let link = try #require(URL(string: "https://example.com/next"))
        #expect(Reader.readerDecision(for: link, type: .linkActivated, isMainFrame: true, bodyBaseURL: base) == .openExternally(link))
        #expect(Reader.readerDecision(for: URL(string: "tel:5551234"), type: .linkActivated, isMainFrame: true, bodyBaseURL: base) == .cancel)
        #expect(Reader.readerDecision(for: URL(string: "javascript:alert(1)"), type: .linkActivated, isMainFrame: true, bodyBaseURL: base) == .cancel)
        // Form posts, reloads, and history moves are refused.
        #expect(Reader.readerDecision(for: base, type: .formSubmitted, isMainFrame: true, bodyBaseURL: base) == .cancel)
        #expect(Reader.readerDecision(for: base, type: .reload, isMainFrame: true, bodyBaseURL: base) == .cancel)
    }
}
