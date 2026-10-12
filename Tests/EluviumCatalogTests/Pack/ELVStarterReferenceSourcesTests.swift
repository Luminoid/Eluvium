import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The reference chunk's 2026-10-11 sources: Wikipedia over the page-summary
/// REST endpoint and Six Flags ride pages. Recognition across language and
/// mobile hosts and every park, hostile lookalikes, the `{host}` step
/// template, assembly from trimmed live captures (the Six Flags one with a
/// decoy block ahead of the `RidePage` anchor, since the real blob sits
/// past the regex input cap), and the Wikidata identity that links an
/// article to the list entries keyed on the same item.
@Suite("Starter pack reference sources")
struct ELVStarterReferenceSourcesTests {
    private func loaded() throws -> ELVLoadedPack {
        try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
    }

    private func assemble(_ url: String, document: ELVDocument) throws -> ELVRecord {
        let pack = try loaded()
        let target = try #require(URL(string: url))
        let recognition = try #require(pack.registry.recognize(target), "\(url) did not recognize")
        let source = try #require(pack.source(withId: recognition.sourceId))
        return ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: target, params: recognition.params, document: document))
    }

    private func json(_ text: String) throws -> ELVDocument {
        let node: ELVRawJSON = try #require(ELVRawJSON.parse(Data(text.utf8)))
        return ELVDocument(json: node)
    }

    // MARK: - Recognition

    @Test
    func `Every Wikipedia host and every Six Flags park recognizes to its source`() throws {
        let cases: [(url: String, sourceId: String)] = [
            ("https://en.wikipedia.org/wiki/Jenny_Lake", "wikipedia.article"),
            ("https://zh.wikipedia.org/wiki/%E4%B8%8A%E6%B5%B7%E5%B8%82", "wikipedia.article"),
            ("https://ja.wikipedia.org/wiki/%E6%9D%B1%E4%BA%AC%E3%82%BF%E3%83%AF%E3%83%BC", "wikipedia.article"),
            ("https://en.m.wikipedia.org/wiki/Eluvium", "wikipedia.article"),
            ("https://zh.m.wikipedia.org/wiki/%E4%B8%8A%E6%B5%B7%E5%B8%82#%E5%8E%86%E5%8F%B2", "wikipedia.article"),
            ("https://en.wikipedia.org/wiki/The_Three-Body_Problem_(novel)", "wikipedia.article"),
            ("https://www.sixflags.com/magicmountain/attractions/wonder-woman-flight-of-courage", "sixflags.attraction"),
            ("https://www.sixflags.com/cedarpoint/attractions/millennium-force", "sixflags.attraction"),
            ("https://sixflags.com/greatadventure/attractions/nitro/", "sixflags.attraction"),
        ]
        let registry = try loaded().registry
        for (url, sourceId) in cases {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target)?.sourceId == sourceId, "\(url)")
        }
    }

    @Test
    func `Lookalike hosts, non-article paths, and the park grid never match a reference source`() throws {
        let registry = try loaded().registry
        for url in [
            "https://wikipedia.org.evil.com/wiki/Jenny_Lake",
            "https://evil.com@en.wikipedia.org.attacker.io/wiki/Jenny_Lake",
            "https://en.wikipedia.org/w/index.php?title=Jenny_Lake",
            // A slash in the title is a two-segment path: the summary of its
            // first segment would be the wrong article, so it takes the floor.
            "https://en.wikipedia.org/wiki/AC/DC",
            "https://www.sixflags.com/magicmountain/attractions",
            "https://www.sixflags.com/magicmountain/dining/full-throttle-sports-bar",
            "https://sixflags.com.evil.io/magicmountain/attractions/x2",
        ] {
            let target = try #require(URL(string: url))
            let match = registry.recognize(target)?.sourceId
            #expect(match == nil || !["wikipedia.article", "sixflags.attraction"].contains(match ?? ""), "\(url) matched \(match ?? "")")
        }
    }

    // MARK: - Wikipedia

    @Test
    func `The Wikipedia step follows the pasted host through the host placeholder`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "wikipedia.article"))
        let template = try #require(source.fetch?.url)
        #expect(template == "https://{host}/api/rest_v1/page/summary/{param.title}")
        let pasted = try #require(URL(string: "https://zh.m.wikipedia.org/wiki/%E4%B8%8A%E6%B5%B7%E5%B8%82"))
        let recognition = try #require(pack.registry.recognize(pasted))
        let filled = ELVURLTemplate.fillInput(ELVURLTemplate.fill(template, params: recognition.params), from: pasted)
        #expect(filled == "https://zh.m.wikipedia.org/api/rest_v1/page/summary/%E4%B8%8A%E6%B5%B7%E5%B8%82")
    }

    @Test
    func `A page summary assembles into an article keyed on its Wikidata item`() throws {
        let record = try assemble("https://en.wikipedia.org/wiki/Jenny_Lake", document: json("""
        {"type":"standard","title":"Jenny Lake","displaytitle":"<span class=\\"mw-page-title-main\\">Jenny Lake</span>",
         "wikibase_item":"Q743054","lang":"en","pageid":6601189,"timestamp":"2026-07-25T22:06:03Z",
         "description":"Lake in Teton County, Wyoming, United States",
         "extract":"Jenny Lake is located in Grand Teton National Park in the U.S. state of Wyoming.",
         "coordinates":{"lat":43.76388889,"lon":-110.73},
         "thumbnail":{"source":"https://thumb.wikimedia.org/wikipedia/commons/thumb/e/e8/Jenny.jpg/330px-Jenny.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
                      "width":330,"height":208},
         "originalimage":{"source":"https://thumb.wikimedia.org/wikipedia/commons/thumb/e/e8/Jenny.jpg/3840px-Jenny.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
                          "width":5400,"height":3400},
         "content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Jenny_Lake"},"mobile":{"page":"https://en.m.wikipedia.org/wiki/Jenny_Lake"}}}
        """))
        #expect(record.kind == "article")
        #expect(record.externalId == "6601189")
        #expect(record.fields["title"] == .text("Jenny Lake"))
        #expect(record.fields["description"] == .text("Lake in Teton County, Wyoming, United States"))
        #expect(record.fields["summary"] == .text("Jenny Lake is located in Grand Teton National Park in the U.S. state of Wyoming."))
        #expect(record.fields["geo"] == .geo(latitude: 43.76388889, longitude: -110.73))
        #expect(record.fields["language"] == .text("en"))
        #expect(record.fields["pageType"] == .text("standard"))
        #expect(record.fields["wikidata"] == .text("Q743054"))
        #expect(record.fields["modified"] != nil)
        // The API appends tracking to its image URLs; the record carries the
        // bare file, at the original size ahead of the 330px thumbnail.
        let image = try #require(URL(string: "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/e8/Jenny.jpg/3840px-Jenny.jpg"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: image, kind: ELVMediaRef.image)))
        #expect(try record.fields["link"] == .url(#require(URL(string: "https://en.wikipedia.org/wiki/Jenny_Lake"))))
        #expect(record.identities.contains(ELVIdentity(namespace: "wikidata", value: "Q743054", origin: .declared)))

        // The built-in strong `wikidata` namespace links the article to a
        // list entry keyed on the same item (the Liu Cixin / Van Gogh rows).
        var index = ELVEntityIndex()
        try index.register(key: ELVRecordKey(sourceId: record.sourceId, externalId: #require(record.externalId)), identities: record.identities)
        index.register(key: ELVRecordKey(sourceId: "lists.vangogh.paintings", externalId: "Q743054"),
                       identities: [ELVIdentity(namespace: "wikidata", value: "Q743054", origin: .declared)])
        #expect(index.entities().count == 1)
    }

    // MARK: - Six Flags

    // swiftlint:disable line_length
    /// A WONDER WOMAN™ Flight of Courage capture (2026-10-11), trimmed to
    /// the head, the hero heading, and the flight payload's ride object; the
    /// `RidePage` marker that opens the object is preceded by a decoy block
    /// of the same shape (the i18n labels and a related card sit there on
    /// the real page) so the anchored candidates prove they skip it. The
    /// capture stays byte-faithful, so its payload lines are as long as the
    /// page's.
    private static let wonderWomanPage = #"""
    <html><head>
    <meta property="og:title" content="Six Flags Magic Mountain - WONDER WOMAN™ Flight of Courage"/>
    <meta property="og:description" content="Fly high on WONDER WOMAN™ Flight of Courage! A thrilling coaster at Six Flags Magic Mountain."/>
    <meta property="og:image" content="https://cdn.sanity.io/images/bsnrdz4t/production/e8e85b17f040f6b825fb1db9c6675060d01f65e5-1500x1000.jpg?rect=0,108,1500,784&amp;w=1200&amp;h=627&amp;fit=crop&amp;auto=format"/>
    </head><body>
    <h1 class="text-balance text-center type-40-700 md:type-64-700 mb-6 md:mb-0 text-white"><span class="text-balance text-center type-40-700 md:type-64-700 mb-6 md:mb-0 [-webkit-hyphens:auto] [-ms-hyphens:auto] [hyphens:auto]">WONDER WOMAN™ Flight of Courage</span><span class="block [-webkit-hyphens:auto] [-ms-hyphens:auto] [hyphens:auto] text-white/80">A Single-Rail, Double Record Holder</span></h1>
    <script>self.__next_f.push([1,"5:[\"$\",\"$L2\",null,{\"labels\":{\"thrillLevel\":\"Thrill Level\",\"topSpeed\":\"Top Speed\"},\"decoy\":{\"fimsId\":\"RIDE-000-00000\",\"metadata\":{\"manufacturer\":\"Decoy Works\",\"maxHeightAccompanied\":0,\"metricOrImperial\":\"metric\",\"minimumHeight\":36,\"minimumHeightAccompanied\":0,\"specialFeatures\":\"\",\"thrillLevel\":2,\"topSpeed\":10,\"trackLength\":1,\"yearIntroduced\":1999},\"neighborhood\":{\"label\":\"Nowhere\"},\"parkSlug\":\"magicmountain\",\"plainTextTitle\":\"Decoy Ride\"}}]\n"])</script>
    <script>self.__next_f.push([1,"11:[\"/_next/static/immutable/chunks/4078zr-kzgl3p.js\"],\"RidePage\"]\n12:[[\"$\",\"$L39\",null,{\"_id\":\"El5Jl6Xsp55zLA5ODDPGjy4YNbBVRTL4\",\"accessibility\":{\"accessibilityLink\":\"https://qr1.be/BH8H\",\"adaGuidelines\":null,\"description\":\"Attraction Accessibility Information\"},\"attractionType\":{\"description\":\"The entry to this attraction is included with your pass.\",\"ecomLink\":null,\"type\":\"included\"},\"fimsId\":\"RIDE-906-00042\",\"flashPasses\":[{\"_key\":\"auto-generated-0\",\"_type\":\"flashPass\",\"title\":\"Regular\",\"value\":\"regular\"}],\"flexibleBlocks\":[{\"_key\":\"8d67dc31aa18\",\"_type\":\"video\",\"videoType\":\"youtube\",\"youtube\":{\"image\":null,\"url\":\"https://www.youtube.com/watch?v=nLL212yCzC4\"}},{\"_key\":\"8e9c59cdc226\",\"_type\":\"rideStatistics\",\"metadata\":{\"duration\":0,\"elevation\":131,\"goesUpsideDown\":true,\"manufacturer\":\"Rocky Mountain Construction\",\"metricOrImperial\":\"imperial\",\"specialFeatures\":\"\",\"topSpeed\":58,\"trackLength\":3300,\"yearIntroduced\":2022}}],\"image\":{\"imageSource\":\"sanity\",\"isFullBleed\":null,\"sanityImage\":{\"alt\":\"SixFlags Image Placeholder\",\"asset\":{\"_id\":\"image-e8e85b17f040f6b825fb1db9c6675060d01f65e5-1500x1000-jpg\",\"_ref\":null,\"metadata\":{\"lqip\":\"data:image/jpeg;base64,X\"},\"url\":\"https://cdn.sanity.io/images/bsnrdz4t/production/e8e85b17f040f6b825fb1db9c6675060d01f65e5-1500x1000.jpg\"},\"crop\":null,\"hotspot\":null}},\"isPreSelectedRelatedRides\":false,\"longTitle\":\"A Single-Rail, Double Record Holder\",\"metadata\":{\"duration\":0,\"elevation\":131,\"goesUpsideDown\":true,\"heightDescription\":null,\"manufacturer\":\"Rocky Mountain Construction\",\"maxHeightAccompanied\":0,\"maximumHeight\":0,\"metricOrImperial\":\"imperial\",\"minimumHeight\":48,\"minimumHeightAccompanied\":0,\"specialFeatures\":\"\",\"thrillLevel\":4,\"topSpeed\":58,\"trackLength\":3300,\"yearIntroduced\":2022},\"neighborhood\":{\"label\":\"DC UNIVERSE\"},\"parkSlug\":\"magicmountain\",\"plainTextTitle\":\"WONDER WOMAN™ Flight of Courage\",\"preSelectedRelatedRidesCount\":0,\"relatedRides\":[{\"_key\":\"c1\",\"image\":{\"imageSource\":\"sanity\",\"sanityImage\":{\"alt\":\"Riddler\",\"asset\":{\"url\":\"https://cdn.sanity.io/images/bsnrdz4t/production/a.jpg\"}}},\"link\":\"riddlers-revenge\",\"metadata\":{\"metric\":\"”\",\"minimumHeight\":54,\"thrillLevel\":\"high\"},\"plainTextTitle\":\"THE RIDDLER™’s Revenge\",\"title\":[{\"_key\":\"t1\",\"_type\":\"block\",\"children\":[{\"_key\":\"s1\",\"_type\":\"span\",\"text\":\"THE RIDDLER™’s Revenge\"}]}]},{\"_key\":\"c2\",\"image\":{\"imageSource\":\"sanity\",\"sanityImage\":{\"alt\":\"Batman\",\"asset\":{\"url\":\"https://cdn.sanity.io/images/bsnrdz4t/production/b.jpg\"}}},\"link\":\"batman-and-robin\",\"metadata\":{\"metric\":\"”\",\"minimumHeight\":48,\"thrillLevel\":\"aggressive\"},\"plainTextTitle\":\"Batman & Robin\",\"title\":[{\"_key\":\"t2\",\"_type\":\"block\",\"children\":[{\"_key\":\"s2\",\"_type\":\"span\",\"text\":\"Batman & Robin\"}]}]}],\"slug\":\"wonder-woman-flight-of-courage\"}]]\n"])</script>
    </body></html>
    """#
    // swiftlint:enable line_length

    @Test
    func `A ride page assembles its thrill level and statistics from the anchored blob, not the decoy`() throws {
        let record = try assemble("https://www.sixflags.com/magicmountain/attractions/wonder-woman-flight-of-courage", document: ELVDocument(html: Self.wonderWomanPage))
        #expect(record.kind == "attraction")
        #expect(record.externalId == "RIDE-906-00042")
        #expect(record.fields["title"] == .text("WONDER WOMAN™ Flight of Courage"))
        #expect(record.fields["park"] == .text("magicmountain"))
        #expect(record.fields["parkName"] == .text("Six Flags Magic Mountain"))
        #expect(record.fields["area"] == .text("DC UNIVERSE"))
        #expect(record.fields["thrillLevel"] == .number(4))
        #expect(record.fields["minimumHeight"] == .number(48))
        // Zero means "no accompanied minimum"; the field stays absent.
        #expect(record.fields["minimumHeightAccompanied"] == nil)
        #expect(record.fields["heightUnits"] == .text("imperial"))
        #expect(record.fields["height"] == .number(131))
        #expect(record.fields["topSpeed"] == .number(58))
        #expect(record.fields["trackLength"] == .number(3300))
        #expect(record.fields["yearIntroduced"] == .number(2022))
        #expect(record.fields["manufacturer"] == .text("Rocky Mountain Construction"))
        #expect(record.fields["specialFeatures"] == nil)
        #expect(record.fields["summary"] == .text("Fly high on WONDER WOMAN™ Flight of Courage! A thrilling coaster at Six Flags Magic Mountain."))
        if case let .media(image)? = record.fields["image"] {
            #expect(image.url.absoluteString.hasPrefix("https://cdn.sanity.io/images/bsnrdz4t/production/e8e85b17"))
        } else {
            Issue.record("image did not assemble from og:image")
        }
        #expect(record.identities.contains(ELVIdentity(namespace: "sixflags.attraction", value: "RIDE-906-00042", origin: .declared)))

        let related = try #require(record.collections["relatedRides"])
        #expect(related.map(\.externalId) == ["riddlers-revenge", "batman-and-robin"])
        #expect(related.map { $0.fields["title"] } == [.text("THE RIDDLER™’s Revenge"), .text("Batman & Robin")])
        #expect(related.map { $0.fields["thrillTier"] } == [.text("high"), .text("aggressive")])
        #expect(related.map { $0.fields["minimumHeight"] } == [.number(54), .number(48)])
        #expect(try related[0].fields["url"] == .url(#require(URL(string: "https://www.sixflags.com/magicmountain/attractions/riddlers-revenge"))))
        #expect(related[0].kind == "attraction")
    }

    @Test
    func `Without the ride object the anchored fields miss instead of reading a decoy`() throws {
        // The decoy block alone: the page's own ride object never arrived.
        let shell = Self.wonderWomanPage.components(separatedBy: "\\\"RidePage\\\"]").first ?? ""
        let record = try assemble("https://www.sixflags.com/magicmountain/attractions/wonder-woman-flight-of-courage", document: ELVDocument(html: shell + "</body></html>"))
        #expect(record.fields["title"] == .text("WONDER WOMAN™ Flight of Courage"))
        #expect(record.fields["thrillLevel"] == nil)
        #expect(record.fields["manufacturer"] == nil)
        #expect(record.fields["area"] == nil)
        #expect(record.collections["relatedRides"]?.isEmpty ?? true)
        // The decoy's id never becomes the record's.
        #expect(record.externalId != "RIDE-000-00000")
    }

    @Test
    func `The title falls back to the social title stripped of the park, in both park naming styles`() throws {
        let cedar = try assemble("https://www.sixflags.com/cedarpoint/attractions/millennium-force",
                                 document: ELVDocument(metas: ["og:title": "Cedar Point | Millennium Force | Best Steel Roller Coasters"]))
        #expect(cedar.fields["title"] == .text("Millennium Force"))
        #expect(cedar.fields["parkName"] == .text("Cedar Point"))
        let nitro = try assemble("https://www.sixflags.com/greatadventure/attractions/nitro",
                                 document: ELVDocument(metas: ["og:title": "Six Flags Great Adventure - Nitro"]))
        #expect(nitro.fields["title"] == .text("Nitro"))
        #expect(nitro.fields["parkName"] == .text("Six Flags Great Adventure"))
    }
}
