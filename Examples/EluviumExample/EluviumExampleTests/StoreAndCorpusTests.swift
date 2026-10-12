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
        #expect(ELVNativeOps.isRegistered("trail.statsFromText@2"))
        #expect(ELVNativeOps.isRegistered("geo.anchorLadder@1"))
        #expect(ELVNativeOps.isRegistered("place.mapKitLookup@1"))
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
        // File sources (the iNaturalist / eBird CSVs, the WeRead notes
        // export) take files, not links; their corpus is fixture text.
        let exempt: Set = ["komoot.route", "shortlinks.media", "xiaohongshu.post", "flighty.flight"]
        for source in pack.sources where source.seed == nil && !exempt.contains(source.id) && source.match?.file == nil {
            #expect(source.examples.count >= 2, "\(source.id) has \(source.examples.count) examples")
            for example in source.examples {
                #expect(URL(string: example.input)?.scheme?.hasPrefix("http") == true, "\(source.id): \(example.input)")
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
    func `The examples browser groups the corpus by provider without losing rows`() async {
        let browser = ExamplesViewController()
        browser.loadViewIfNeeded()
        // The corpus fills in once the store's background pack load lands.
        await browser.packLoadTask?.value
        let table = UITableView()

        // Grouping rearranges, never drops: every example survives — the
        // file pack's rows included.
        let sectionCount = browser.numberOfSections(in: table)
        let totalRows = (0 ..< sectionCount).reduce(0) { $0 + browser.tableView(table, numberOfRowsInSection: $1) }
        #expect(totalRows == ExampleStore.shared.allSources.reduce(0) { $0 + $1.examples.count })

        let headers = (0 ..< sectionCount).compactMap { browser.tableView(table, titleForHeaderInSection: $0) }
        // The three Google Maps variants read as ONE provider section, and
        // the header joins title and kind with the app's one separator.
        #expect(headers.count(where: { $0.hasPrefix("Google Maps\(Separator.dot)") }) == 1)
        // The short-link redirector dissolves into destination sections.
        #expect(!headers.contains { $0.localizedCaseInsensitiveContains("short link") })
        // Flighty carries one share by owner ruling (the others name their
        // traveler), so its section is the one allowed a single row.
        for section in 0 ..< sectionCount where browser.tableView(table, titleForHeaderInSection: section)?.hasPrefix("Flighty") != true {
            #expect(browser.tableView(table, numberOfRowsInSection: section) >= 2)
        }
    }

    @Test
    func `Short-link examples file under their destination provider's section`() async throws {
        await ExampleStore.shared.ready()
        let sections = ExampleCorpus.sections(from: ExampleStore.shared.loadedPack.sources)
        let google = try #require(sections.first { $0.title == "Google Maps" })
        #expect(google.rows.contains { $0.input.contains("maps.app.goo.gl") })
        // Every short-link host in the corpus has a destination mapping, so
        // the explicit fallback section never appears with this pack.
        #expect(!sections.contains { $0.title == "Short links" })
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
    func `The input parser pulls a URL out of a plain link and a share blurb`() {
        #expect(InputParser.firstURL(in: "https://pokeapi.co/api/v2/pokemon/25")?.host == "pokeapi.co")
        #expect(InputParser.firstURL(in: "Check this out https://swift.org/ great")?.host == "swift.org")
        #expect(InputParser.firstURL(in: "just some text") == nil)
        #expect(InputParser.firstURL(in: "ftp://example.com/file") == nil)
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
