import Foundation
import Testing
@testable import EluviumCore

/// `trail.statsFromText@3` over a dom step's rendered regions: the anchor
/// ladder that keeps related-trail cards' stats out, and `trail.locality@1`.
@Suite("Trail stats from page regions")
struct ELVTrailRegionsTests {
    /// Registers the ops itself, so the suite passes run alone.
    init() {
        ELVNativeOps.registerBuiltins()
    }

    private func stats(
        h1: String? = nil,
        header: String? = nil,
        body: String? = nil,
        title: String? = nil,
        ogTitle: String? = nil,
        ogDescription: String? = nil,
        share: String? = nil
    ) -> [String: ELVValue]? {
        var document = ELVDocument(title: title)
        document.cssResults["@h1"] = h1
        document.cssResults["@header"] = header
        document.cssResults["@body"] = body
        document.metas["og:title"] = ogTitle
        document.metas["og:description"] = ogDescription
        let input = share.map { ["text": $0] } ?? [:]
        return ELVNativeOps.lookup("trail.statsFromText@3")?(input, ELVExtractionContext(document: document))
    }

    @Test
    func `the rendered header supplies stats when the metas are gone`() throws {
        let outputs = try #require(stats(body: "Schwabacher's Landing Trail\nEasy · 4.4 (1,097 reviews)\nLength 0.5 mi · Est. 12 min", title: "Schwabacher's Landing Trail"))
        #expect(outputs["distance"] == .text("0.5 mi"))
        #expect(outputs["difficulty"] == .text("Easy"))
        #expect(outputs["duration"] == .text("12 min"))
    }

    @Test
    func `a lone distance in body text stays out`() {
        #expect(stats(body: "Palo Alto Duck Pond Trail\nExplore trails within 15 mi of this location and plan your next visit.", title: "Palo Alto Duck Pond Trail") == nil)
    }

    @Test
    func `body stats anchor at the page's own name, skipping earlier junk`() throws {
        let filler = String(repeating: "reviews and photos and more ", count: 5)
        let outputs = try #require(stats(body: "Trails within 15 mi of you\n\(filler)\nPalo Alto Duck Pond Trail\nEasy · Length 0.9 mi · Est. 15 min", title: "Palo Alto Duck Pond Trail"))
        #expect(outputs["distance"] == .text("0.9 mi"))
        #expect(outputs["difficulty"] == .text("Easy"))
        #expect(outputs["sources"] == .text("body"))
    }

    @Test
    func `a related trail card's stats never leak in`() {
        let body = "Popular trails nearby\nMission Peak Loop\nHard · 4.5 (2,001)\nLength 8.2 mi · Est. 4h 30m"
        #expect(stats(body: body, title: "Golden Eagle and Upper Ranch Loop") == nil)
    }

    @Test
    func `the rendered h1 anchors the body when og title names another route`() throws {
        let body = "Popular trails nearby\nMission Peak Loop\nHard · 4.5 (2,001)\nLength 8.2 mi · Est. 4h 30m\n"
            + "Golden Eagle Trail to Upper Ranch Trail\nModerate · 4.7 (312)\nLength 3.9 mi · Est. 1h 45m"
        let outputs = try #require(stats(h1: "Golden Eagle Trail to Upper Ranch Trail", body: body, ogTitle: "Golden Eagle and Upper Ranch Loop"))
        #expect(outputs["distance"] == .text("3.9 mi"))
        #expect(outputs["difficulty"] == .text("Moderate"))
        #expect(outputs["duration"] == .text("1h 45m"))
    }

    @Test
    func `a banner h1 cannot shadow the title anchor`() throws {
        let filler = String(repeating: "manage cookie preferences and privacy choices ", count: 20)
        let body = "Cookie preferences\n\(filler)\nGolden Eagle and Upper Ranch Loop\nModerate · 4.7 (2,747)\nLength 3.9 mi · Est. 1h 39m"
        let outputs = try #require(stats(h1: "Cookie preferences", body: body, ogTitle: "Golden Eagle and Upper Ranch Loop"))
        #expect(outputs["distance"] == .text("3.9 mi"))
        #expect(outputs["duration"] == .text("1h 39m"))
    }

    @Test
    func `the rendered description paragraph supplies stats as prose`() throws {
        let filler = String(repeating: "photo gallery reviews activities weather directions ", count: 18)
        let body = "Golden Eagle and Upper Ranch Loop\n\(filler)\n"
            + "Experience this 3.9-mile loop trail near Fremont, California. "
            + "Generally considered a moderately challenging route, it takes an average of 1 h 39 min to complete."
        let outputs = try #require(stats(h1: "Golden Eagle and Upper Ranch Loop", body: body, ogTitle: "Golden Eagle and Upper Ranch Loop"))
        #expect(outputs["distance"] == .text("3.9 mi"))
        #expect(outputs["difficulty"] == .text("Moderately challenging"))
        #expect(outputs["duration"] == .text("1 h 39 min"))
        #expect(outputs["sources"] == .text("prose"))
    }

    @Test
    func `the label-value block parses with its far-away difficulty`() throws {
        let body = """
        Golden Eagle and Upper Ranch Loop
        4.7
        (2,753 reviews)
        ·
        Moderate
        ·
        Vargas Plateau Regional Park
        3.9mi
        Length
        518ft
        Elevation gain
        1.5–2hr
        Estimated time
        Loop
        """
        let outputs = try #require(stats(h1: "Golden Eagle and Upper Ranch Loop", body: body))
        #expect(outputs["distance"] == .text("3.9 mi"))
        #expect(outputs["difficulty"] == .text("Moderate"))
        #expect(outputs["duration"] == .text("1.5–2hr"))
    }

    @Test
    func `the header region leads and the share text wins per field`() throws {
        let header = "Mist Trail\nHard · 4.8\nLength 6.4 mi · Est. 4h 30m"
        let outputs = try #require(stats(
            h1: "Mist Trail",
            header: header,
            ogDescription: "Experience this 3.0-mile trail. Generally considered an easy route.",
            share: "Mist Trail · Moderate · 3.0 mi https://www.alltrails.com/trail/us/california/mist-trail?sh=7mixyz"
        ))
        #expect(outputs["distance"] == .text("3.0 mi"))
        #expect(outputs["difficulty"] == .text("Moderate"))
        #expect(outputs["duration"] == .text("4h 30m"))
        #expect(outputs["sources"] == .text("share,header"))
    }

    @Test
    func `an http document offers only its metas`() throws {
        var document = ELVDocument(html: "<html><body><p>Mission Peak Loop · Hard · 8.2 mi · Est. 4h 30m</p></body></html>")
        document.text = document.html
        document.metas["og:description"] = "Experience this 0.9-mile out-and-back trail near Palo Alto, California. Generally considered an easy route, it takes an average of 15 min to complete."
        let outputs = try #require(ELVNativeOps.lookup("trail.statsFromText@3")?([:], ELVExtractionContext(document: document)))
        #expect(outputs["distance"] == .text("0.9 mi"))
        #expect(outputs["sources"] == .text("og"))
    }

    @Test
    func `locality comes from a near phrase, then a digit-free address, then the path`() {
        func locality(og: String? = nil, jsonLD: String? = nil, region: String? = nil, country: String? = nil) -> String? {
            var html = "<html><head>"
            if let og { html += "<meta property=\"og:description\" content=\"\(og)\">" }
            if let jsonLD { html += "<script type=\"application/ld+json\">\(jsonLD)</script>" }
            html += "</head></html>"
            var input: [String: String] = [:]
            input["region"] = region
            input["country"] = country
            let outputs = ELVNativeOps.lookup("trail.locality@1")?(input, ELVExtractionContext(document: ELVDocument(html: html)))
            guard case let .text(value)? = outputs?["locality"] else { return nil }
            return value
        }
        #expect(locality(og: "Experience this 0.9-mile trail near Palo Alto, California. Generally easy.") == "Palo Alto, California")
        // Prose after "near" is not a place: the URL seed answers instead.
        #expect(locality(og: "If you explore near the tide pools, regular sneakers are perfect.", region: "california", country: "us") == "California, US")
        let node = #"{"@type": "LocalBusiness", "name": "Hidden Falls", "geo": {"latitude": 43.76, "longitude": -110.73}, "#
            + #""address": {"addressLocality": "Moose", "addressRegion": "Wyoming", "addressCountry": "United States"}}"#
        #expect(locality(jsonLD: node, region: "wyoming", country: "us") == "Moose, Wyoming, United States")
        // The template sentence outranks an editor's earlier "near X.", and
        // the editor's phrase still answers when no template exists.
        let editorial = "This loop takes you to Point Lobos State Natural Reserve near Monterey. A scenic coastal hike."
        let templated = #"{"@type": "LocalBusiness", "name": "Cannery Point Trail", "geo": {"latitude": 36.52, "longitude": -121.94}, "#
            + #""description": "Head out on this 3.2-mile loop trail near Carmel-by-the-Sea, California. Generally considered an easy route."}"#
        #expect(locality(og: editorial, jsonLD: templated) == "Carmel-by-the-Sea, California")
        #expect(locality(og: editorial) == "Monterey")
        let street = #"{"@type": "LocalBusiness", "name": "X", "geo": {"latitude": 43.76, "longitude": -110.73}, "address": {"streetAddress": "12 Main St", "addressLocality": "Moose"}}"#
        #expect(locality(jsonLD: street, region: "new-york", country: "us") == "New York, US")
        #expect(locality(region: "wyoming", country: "usa") == nil)
        #expect(locality() == nil)
    }

    @Test
    func `the compiler reads regions with fixed innerText expressions`() throws {
        let source = ELVSource(id: "t", kind: "trail", fetch: ELVFetchPlan(mode: "dom", regions: ["h1", "header", "body", "bogus"]))
        let queries = try source.cssQueries(for: #require(source.fetch?.resolvedSteps[0]))
        #expect(queries.map(\.key) == ["@h1", "@header", "@body"])
        let program = ELVSelectorJSCompiler.compile(css: queries, maxHTMLBytes: 1000)
        #expect(program.contains("\"innerText:200\""))
        #expect(program.contains("\"ancestorInnerText:3:3000\""))
        #expect(program.contains("\"innerText:12000\""))
        #expect(program.contains("node.parentElement"))
    }
}
