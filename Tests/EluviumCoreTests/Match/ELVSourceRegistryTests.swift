import Foundation
import Testing
@testable import EluviumCore

@Suite("Source registry recognition")
struct ELVSourceRegistryTests {
    private func makeRegistry() -> ELVSourceRegistry {
        ELVSourceRegistry(sources: [
            ELVMatchableSource(
                id: "alltrails.trail",
                match: ELVMatchRule(hosts: ["alltrails.com"], paths: ["/trail/:country/:region/:slug"], priority: 100)
            ),
            ELVMatchableSource(
                id: "alltrails.any",
                match: ELVMatchRule(hosts: ["alltrails.com"], priority: 10)
            ),
            ELVMatchableSource(
                id: "amazon.product",
                match: ELVMatchRule(brands: ["amazon"], paths: ["/dp/:asin"], priority: 100)
            ),
            ELVMatchableSource(
                id: "imdb.title",
                match: ELVMatchRule(hosts: ["imdb.com"], paths: ["/title/:id/**"], priority: 100)
            ),
        ])
    }

    @Test
    func `A trail URL recognizes the specific source and captures named params`() throws {
        let url = try #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))
        let recognition = try #require(makeRegistry().recognize(url))
        #expect(recognition.sourceId == "alltrails.trail")
        #expect(recognition.params == ["country": "us", "region": "wyoming", "slug": "hidden-falls-trail"])
    }

    @Test
    func `A non-matching path falls to the lower-priority host-wide source`() throws {
        let url = try #require(URL(string: "https://www.alltrails.com/members/lists/favorites"))
        let recognition = try #require(makeRegistry().recognize(url))
        #expect(recognition.sourceId == "alltrails.any")
    }

    @Test
    func `Brand-form sources recognize across storefront TLDs`() throws {
        let com = try #require(URL(string: "https://www.amazon.com/dp/B0018CLTKC"))
        let jp = try #require(URL(string: "https://www.amazon.co.jp/dp/B0018CLTKC"))
        #expect(makeRegistry().recognize(com)?.sourceId == "amazon.product")
        #expect(makeRegistry().recognize(jp)?.params["asin"] == "B0018CLTKC")
    }

    @Test
    func `A hostile lookalike URL recognizes nothing`() throws {
        let url = try #require(URL(string: "https://www.alltrails.com.attacker.net/trail/us/wyoming/hidden-falls-trail"))
        #expect(makeRegistry().recognize(url) == nil)
    }

    @Test
    func `A trailing ** pattern tolerates the URL forms sources actually serve`() throws {
        let bare = try #require(URL(string: "https://www.imdb.com/title/tt0076759"))
        let deep = try #require(URL(string: "https://www.imdb.com/title/tt0076759/reference"))
        #expect(makeRegistry().recognize(bare)?.params["id"] == "tt0076759")
        #expect(makeRegistry().recognize(deep)?.params["id"] == "tt0076759")
    }

    @Test
    func `Percent-encoded path segments decode in captured params`() throws {
        let registry = ELVSourceRegistry(sources: [
            ELVMatchableSource(id: "wiki.article", match: ELVMatchRule(hosts: ["wikipedia.org"], paths: ["/wiki/:title"])),
        ])
        let url = try #require(URL(string: "https://en.wikipedia.org/wiki/List_of_Star_Wars_films%20test"))
        #expect(registry.recognize(url)?.params["title"] == "List_of_Star_Wars_films test")
    }

    @Test
    func `A file rule's csvHeader takes the scalar shorthand and glob matching stays case-insensitive`() throws {
        let rule = try JSONDecoder().decode(
            ELVFileMatchRule.self,
            from: Data(#"{"name": "FlightyExport-*.csv", "probe": {"csvHeader": "Date"}}"#.utf8)
        )
        #expect(rule.csvHeader == ["Date"])
        #expect(rule.matchesName("flightyexport-2026-08.CSV"))
        #expect(rule.matchesName("FlightyExport-.csv"))
        #expect(!rule.matchesName("SomethingElse.csv"))
    }

    @Test
    func `A multi-pattern path list matches in order and the winning pattern supplies the params`() throws {
        let registry = ELVSourceRegistry(sources: [
            ELVMatchableSource(id: "douban.subject", match: ELVMatchRule(hosts: ["douban.com"], paths: ["/subject/:id/**", "/game/:id/**"], priority: 100)),
        ])
        let subject = try #require(URL(string: "https://music.douban.com/subject/1394653/"))
        let game = try #require(URL(string: "https://www.douban.com/game/26362172/"))
        let neither = try #require(URL(string: "https://www.douban.com/people/12345/"))
        #expect(registry.recognize(subject)?.params["id"] == "1394653")
        #expect(registry.recognize(game)?.params["id"] == "26362172")
        #expect(registry.recognize(neither) == nil)
    }

    @Test
    func `Equal priority resolves by declaration order, deterministically`() throws {
        let registry = ELVSourceRegistry(sources: [
            ELVMatchableSource(id: "first", match: ELVMatchRule(hosts: ["example.com"], priority: 50)),
            ELVMatchableSource(id: "second", match: ELVMatchRule(hosts: ["example.com"], priority: 50)),
        ])
        let url = try #require(URL(string: "https://example.com/x"))
        #expect(registry.recognize(url)?.sourceId == "first")
        #expect(registry.candidates(for: url).map(\.sourceId) == ["first", "second"])
    }
}

@Suite("Prefixed path parameters")
struct ELVPrefixedPathParameterTests {
    @Test
    func `A literal-prefix capture matches the handle shape and nothing shorter`() {
        let pattern = ELVPathPattern("/@:handle")
        #expect(pattern.match(path: "/@apple") == ["handle": "apple"])
        // Trailing slash: path segments split, so the spelling covers both.
        #expect(pattern.match(path: "/@apple/") == ["handle": "apple"])
        // A bare prefix captures nothing; an unprefixed segment mismatches.
        #expect(pattern.match(path: "/@") == nil)
        #expect(pattern.match(path: "/apple") == nil)
        #expect(pattern.match(path: "/@apple/videos") == nil)
        // Case-insensitive prefix, value kept verbatim.
        #expect(ELVPathPattern("/U:rest").match(path: "/u12") == ["rest": "12"])
        // The classic forms are untouched: a leading colon is a whole-segment
        // capture, and a literal without a colon stays literal.
        #expect(ELVPathPattern("/r/:name").match(path: "/r/swift") == ["name": "swift"])
        #expect(ELVPathPattern("/about").match(path: "/@about") == nil)
    }
}
