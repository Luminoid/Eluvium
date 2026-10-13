import EluviumCore
import EluviumNet
import Foundation
import LumiKitUI
import Testing
import UIKit
@testable import EluviumExample

/// The store's pack loads, the resolve funnel's routing, and the example
/// corpus as the Catalogs and Examples screens present it.
@Suite("Store and corpus")
@MainActor
struct StoreAndCorpusTests {
    @Test
    func `The bundled store loads the starter pack with active and skipped sources`() async {
        await ExampleStore.shared.ready()
        let pack = ExampleStore.shared.loadedPack
        #expect(!ExampleStore.shared.loadFailed)
        #expect(pack.sources.contains { $0.id == "pokeapi.pokemon" })
        #expect(pack.sources.contains { $0.id == "generic.opengraph" })
        #expect(pack.sources.contains { $0.id == "generic.feed" })
        // With the DOM engine injected, the dom-escalating AllTrails source
        // is active, not skipped.
        #expect(pack.sources.contains { $0.id == "alltrails.trail" })
        // Every starter source is active: the app registers both Places ops,
        // and gmaps.place.mapkit runs the live MapKit lookup on a resolve.
        #expect(pack.skipped.isEmpty)
        // The store registered the platform-module ops before loading.
        #expect(ELVNativeOps.isRegistered("shortlink.expand"))
        #expect(ELVNativeOps.isRegistered("trail.statsFromText@3"))
        #expect(ELVNativeOps.isRegistered("geo.anchorLadder@1"))
        #expect(ELVNativeOps.isRegistered("place.mapKitLookup@2"))
    }

    @Test
    func `The empty pack fallback loads under the current loader gates`() {
        // The fallback is force-unwrapped at store init; this pin makes a
        // future loader gate that rejects it fail here, not at app launch.
        #expect(throws: Never.self) { try LoadedPackFallback.load() }
        #expect(LoadedPackFallback.empty.sources.isEmpty)
    }

    @Test
    func `Every active source ships at least two runnable example links`() async {
        await ExampleStore.shared.ready()
        let pack = ExampleStore.shared.loadedPack
        #expect(!pack.sources.isEmpty)
        // Seeded list sources are browse-first: the seed IS the runnable
        // entry (most have no recognizable input URL), so the example floor
        // doesn't apply to them.
        // komoot.route ships an empty corpus by owner ruling (share-token
        // examples exposed third parties; see the package-side floor test).
        // shortlinks.media and xiaohongshu.post are exempt the same way
        // (2026-10-11, 2026-10-12): an xhslink short link resolves to its
        // minter's account, and a note loads only with a share-minted token.
        // flighty.flight keeps one share; its others name their traveler.
        // booking.share expands per-sharer app shares, exempt like xhslink.
        // File sources (the iNaturalist / eBird CSVs, the WeRead notes
        // export) take files, not links; their corpus is fixture text.
        let exempt: Set = ["komoot.route", "shortlinks.media", "xiaohongshu.post", "flighty.flight", "booking.share"]
        for source in pack.sources where source.seed == nil && !exempt.contains(source.id) && source.match?.file == nil {
            #expect(source.examples.count >= 2, "\(source.id) has \(source.examples.count) examples")
            // Web links, or an app-scheme source's own scheme (URL-only, so the
            // pipeline runs them with no network).
            let schemes = Set(source.match?.schemes ?? [])
            for example in source.examples {
                let scheme = URL(string: example.input)?.scheme?.lowercased() ?? ""
                #expect(scheme.hasPrefix("http") || schemes.contains(scheme), "\(source.id): \(example.input)")
            }
        }
    }

    @Test
    func `The bundled Kaya file pack loads and recognizes its share links`() async throws {
        await ExampleStore.shared.ready()
        let filePack = ExampleStore.shared.filePack
        let kaya = try #require(filePack.source(withId: "kaya.climb"))
        #expect(filePack.diagnostics.isEmpty)
        #expect(kaya.examples.count >= 2)
        // The file pack's sources join the browser corpus after the starter's.
        #expect(ExampleStore.shared.allSources.map(\.id).contains("kaya.climb"))

        let registry = ELVSourceRegistry(sources: filePack.sources.compactMap { source in
            source.match.map { ELVMatchableSource(id: source.id, match: $0) }
        })
        for example in kaya.examples {
            let url = try #require(URL(string: example.input))
            #expect(registry.recognize(url)?.sourceId == "kaya.climb", "\(example.input)")
        }
        // The canonical slug shape the SPA redirects to recognizes too.
        let slug = try #require(URL(string: "https://kaya-app.kayaclimb.com/climb/Movement-Sunnyvale-v6-18695239"))
        #expect(registry.recognize(slug)?.sourceId == "kaya.climb")
    }

    @Test
    func `The resolve funnel routes file-pack URLs past the starter's generic floor`() async throws {
        // The corpus log caught the original funnel never firing: the
        // starter's floor answers every URL, so "fall back on .unrecognized"
        // routed Kaya shares to generic.opengraph. File-pack recognition now
        // wins over the floor, and only over the floor.
        await ExampleStore.shared.ready()
        let kaya = try #require(ExampleStore.shared.filePack.source(withId: "kaya.climb"))
        for example in kaya.examples {
            let url = try #require(URL(string: example.input))
            #expect(ExampleStore.shared.usesFilePack(for: url), "\(example.input)")
        }
        // A URL the starter recognizes specifically stays with the starter.
        let starter = try #require(URL(string: "https://x.com/jack/status/20"))
        #expect(!ExampleStore.shared.usesFilePack(for: starter))
        // A URL neither registry recognizes runs the starter pipeline (its
        // generic floor is the "always produce something" contract).
        let unclaimed = try #require(URL(string: "https://example.org/some/page"))
        #expect(!ExampleStore.shared.usesFilePack(for: unclaimed))
    }

    @Test
    func `The pack's seeded lists surface in the Catalogs screen between the roster and the walker`() async {
        await ExampleStore.shared.ready()
        let seeded = ExampleStore.shared.loadedPack.seededSources
        #expect(seeded.contains { $0.id == "lists.oscars.bestpicture" })
        #expect(seeded.contains { $0.id == "lists.ign.tens" })

        let catalogs = CatalogsViewController()
        catalogs.loadViewIfNeeded()
        await catalogs.loadTask?.value
        let table = UITableView()
        #expect(catalogs.numberOfSections(in: table) == 3)
        #expect(catalogs.tableView(table, numberOfRowsInSection: 1) == seeded.count)
        #expect(catalogs.tableView(table, titleForHeaderInSection: 1) == "Lists")
    }

    @Test
    func `The examples browser groups the corpus by family without losing rows`() async {
        let browser = ExamplesViewController()
        browser.loadViewIfNeeded()
        // The corpus fills in once the store's background pack load lands.
        await browser.packLoadTask?.value
        let table = UITableView()

        // Grouping rearranges, never drops: every example survives, the
        // file pack's rows included.
        let sectionCount = browser.numberOfSections(in: table)
        let totalRows = (0 ..< sectionCount).reduce(0) { $0 + browser.tableView(table, numberOfRowsInSection: $1) }
        #expect(totalRows == ExampleStore.shared.allSources.reduce(0) { $0 + $1.examples.count })

        // One section per family, each once (the pack declares Travel in
        // three chunks), travel first, the floors after every catalog
        // family, and the file pack's own section after them.
        let headers = (0 ..< sectionCount).compactMap { browser.tableView(table, titleForHeaderInSection: $0) }
        #expect(Set(headers).count == headers.count)
        #expect(headers.first == "Travel")
        #expect(headers.suffix(2) == ["Generic floors", "Bundled file pack"])
        for family in ["Reference", "Media", "Nature", "Commerce"] {
            #expect(headers.contains(family), "\(family)")
        }
        // The short-link redirector dissolves into its destinations.
        #expect(!headers.contains("Short links"))
    }

    @Test
    func `Rows sort by provider within a family and short links file beside their destination`() async throws {
        await ExampleStore.shared.ready()
        let sections = ExampleCorpus.sections(from: ExampleStore.shared.loadedPack.sources)
        let travel = try #require(sections.first { $0.title == "Travel" })
        let providers = travel.rows.map(\.provider)
        let sorted = zip(providers, providers.dropFirst()).allSatisfy { $0.localizedStandardCompare($1) != .orderedDescending }
        #expect(sorted)
        // Every Google Maps variant sits in one run, the short link with it.
        let google = travel.rows.indices.filter { travel.rows[$0].provider == "Google Maps" }
        #expect(google.count >= 2)
        #expect(google.last.map { $0 - google[0] + 1 } == google.count)
        #expect(google.contains { travel.rows[$0].example.input.contains("maps.app.goo.gl") })
        // Each row carries its own source's kind (directions are routes).
        #expect(travel.rows.contains { $0.provider == "Google Maps" && $0.kind == "route" })
        #expect(travel.rows.contains { $0.provider == "Google Maps" && $0.kind == "place" })
        // Every short-link host in the corpus has a destination mapping, so
        // the explicit fallback section never appears with this pack.
        #expect(!sections.contains { $0.title == "Short links" })
    }

    @Test
    func `Chinese source names carry their pinyin and sort by it`() async throws {
        #expect(ChineseName.annotated("豆瓣") == "豆瓣 (Douban)")
        // A one-character word joins the word before it, as brand names
        // are written.
        #expect(ChineseName.annotated("小红书") == "小红书 (Xiaohongshu)")
        #expect(ChineseName.annotated("小宇宙") == "小宇宙 (Xiaoyuzhou)")
        #expect(ChineseName.annotated("微信读书笔记导出") == "微信读书笔记导出 (Weixin Dushu Biji Daochu)")
        #expect(ChineseName.annotated("小红书 short links") == "小红书 (Xiaohongshu) short links")
        #expect(ChineseName.annotated("Google Maps") == "Google Maps")
        #expect(ChineseName.romanized("豆瓣") == "Douban")

        await ExampleStore.shared.ready()
        let media = try #require(ExampleCorpus.sections(from: ExampleStore.shared.loadedPack.sources).first { $0.title == "Media" })
        let providers = media.rows.map(\.provider)
        // 豆瓣 sorts under D, ahead of IGN, not after every Latin name.
        let douban = try #require(providers.firstIndex(of: "豆瓣 (Douban)"))
        let ign = try #require(providers.firstIndex(of: "IGN"))
        #expect(douban < ign)
    }

    @Test
    func `A source that infers its kind shows each example's kind`() async throws {
        await ExampleStore.shared.ready()
        let douban = try #require(ExampleStore.shared.loadedPack.source(withId: "douban.subject"))
        // Douban authors no kind: it infers one per link.
        #expect(douban.kind.isEmpty)
        #expect(douban.inferredKinds == ["album", "book", "game", "movie"])
        let rows = ExampleCorpus.sections(from: ExampleStore.shared.loadedPack.sources)
            .flatMap(\.rows)
            .filter { $0.provider == douban.displayName }
        #expect(Set(rows.map(\.kind)) == ["album", "book", "game", "movie"])
        #expect(!rows.contains { $0.kind.isEmpty })
    }

    @Test
    func `The examples page is full page with the results panel at the bottom`() throws {
        let page = ExamplesViewController()
        #expect(page.hidesBottomBarWhenPushed)
        let pageView = page.view ?? UIView()
        pageView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        pageView.layoutIfNeeded()
        let table = try #require(pageView.subviews.compactMap { $0 as? UITableView }.first)
        let panel = try #require(pageView.subviews.first { $0 is UIScrollView && !($0 is UITableView) })
        // The list sits above the panel; the panel holds a fixed share of the
        // page and reaches its bottom edge.
        #expect(table.frame.minY > 0)
        #expect(table.frame.maxY <= panel.frame.minY)
        #expect(abs(panel.frame.height - 874 * 0.42) < 1)
        #expect(abs(panel.frame.maxY - 874) < 1)
    }

    @Test
    func `The catalog roster is pack config: every list-spec source is a walkable row, the first active`() async throws {
        await ExampleStore.shared.ready()
        let enumerable = ExampleStore.shared.loadedPack.enumerableSources
        #expect(!enumerable.isEmpty)
        #expect(enumerable.allSatisfy { $0.list != nil })
        #expect(enumerable.contains { $0.id == "pokeapi.dex" })

        let catalogs = CatalogsViewController()
        catalogs.loadViewIfNeeded()
        await catalogs.loadTask?.value
        let table = UITableView()
        table.register(UITableViewCell.self, forCellReuseIdentifier: LMKListTable.cellReuseIdentifier)
        #expect(catalogs.tableView(table, numberOfRowsInSection: 0) == enumerable.count)
        #expect(catalogs.tableView(table, titleForHeaderInSection: 0) == "Catalogs")
        // The roster's first entry is the default walk target: its row wears
        // the checkmark (a list-row trailing, which VoiceOver reads as
        // selected).
        let first = catalogs.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))
        let row = try #require(first.contentConfiguration as? LMKListRowConfiguration)
        let isChecked = if case .checkmark = row.trailing { true } else { false }
        #expect(isChecked)
    }

    @Test
    func `The paste box reads links, share text, bare hosts, and the pack's app links`() async throws {
        await ExampleStore.shared.ready()
        let policy = ExampleStore.shared.pastePolicy
        #expect(InputParser.input(in: "https://pokeapi.co/api/v2/pokemon/25", policy: policy)?.url.host == "pokeapi.co")
        let blurb = try #require(InputParser.input(in: "Check this out https://swift.org/ great", policy: policy))
        #expect(blurb.url.host == "swift.org")
        #expect(blurb.leadingText == "Check this out")
        // A link box reads a bare host the strict TLD list doesn't know.
        #expect(InputParser.input(in: "example.museum/x", policy: policy)?.url.absoluteString == "https://example.museum/x")
        // The starter pack claims the Maps app scheme, so its policy does.
        #expect(InputParser.input(in: "comgooglemaps://?q=Tokyo+Tower", policy: policy) != nil)
        #expect(InputParser.input(in: "just some text", policy: policy) == nil)
        #expect(InputParser.input(in: "ftp://example.com/file", policy: policy) == nil)
    }

    @Test
    func `The paste preview names the record offline and says what Resolve adds`() async throws {
        await ExampleStore.shared.ready()
        let policy = ExampleStore.shared.pastePolicy
        // The share text's name labels the record before any fetch.
        let trail = try #require(InputParser.input(in: "Mist Trail on AllTrails https://www.alltrails.com/trail/us/california/mist-trail", policy: policy))
        let preview = ExampleStore.shared.preview(trail)
        #expect(preview.sourceId == "alltrails.trail")
        #expect(preview.record.displayTitle == "Mist Trail")
        #expect(PreviewCopy.line(for: preview) == "Preview: Mist Trail · alltrails.trail · Resolve will fetch the page")
        // A link no source claims previews as its host, for the floor to read.
        let page = try #require(InputParser.input(in: "https://www.example.org/a", policy: policy))
        #expect(PreviewCopy.line(for: ExampleStore.shared.preview(page)) == "Preview: example.org · no source matched · Resolve will read the page")
    }

    @Test
    func `Value display renders every leaf type without crashing`() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let samples: [ELVValue] = [
            .text("hi"), .number(4), .money(minorUnits: 1299, currencyCode: "USD"),
            .date(Date(timeIntervalSince1970: 0), precision: .day), .duration(5400),
            .url(url), .rating(value: 4.5, scale: 0 ... 5), .tags(["a", "b"]),
            .geo(latitude: 1, longitude: 2),
        ]
        for value in samples {
            #expect(!ELVValueDisplay.string(value).isEmpty)
        }
        #expect(ELVValueDisplay.string(.rating(value: 4.5, scale: 0 ... 5)) == "4.5 / 5")
        #expect(ELVValueDisplay.string(.duration(5400)) == "1h 30m")
    }

    @Test
    func `Failure copy is distinct per typed failure state`() {
        #expect(FailureCopy.message(for: .blocked(status: 403)).contains("403"))
        #expect(FailureCopy.message(for: .offline).contains("offline"))
        #expect(FailureCopy.message(for: .unauthenticated) != FailureCopy.message(for: .timeout))
    }
}
