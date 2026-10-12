import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The opt-in commerce pack (Amazon + Chewy), split out of the starter
/// because those targets' terms restrict automated access and the sources
/// escalate past bot protections (LEGAL.md). Field ladders, recognition, and
/// the dom-escalation trigger are pinned here, against the pack a host loads
/// only via `ELVOptInPacks.commerce`.
@Suite("Commerce opt-in pack")
struct ELVCommerceOptInPackTests {
    private func loaded() throws -> ELVLoadedPack {
        try ELVOptInPacks.commerce(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
    }

    @Test
    func `The pack loads clean and is not part of the starter roster`() throws {
        let optIn = try loaded()
        #expect(optIn.diagnostics.isEmpty, "\(optIn.diagnostics)")
        // Chewy's own product id is strong; an ASIN is per marketplace, and
        // the source matches every storefront, so it stays weak.
        #expect(Set(optIn.strongNamespaces) == ["chewy.product"])
        // `requires` lists only what no step mode implies, versioned; the
        // dom rungs carry their own capability on both sources.
        #expect(optIn.source(withId: "chewy.product")?.requires == ["native:jsonld.bestPlaceNode@1"])
        #expect(optIn.source(withId: "amazon.product")?.requires.isEmpty == true)
        #expect(Set(optIn.sources.map(\.id)) == ["chewy.product", "amazon.product"])
        // The starter must not carry them, or the split is decorative.
        let starter = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
        #expect(starter.source(withId: "chewy.product") == nil)
        #expect(starter.source(withId: "amazon.product") == nil)
    }

    @Test
    func `Product URLs recognize their shapes, lookalikes and category pages excluded`() throws {
        let pack = try loaded()

        let chewy = try #require(URL(string: "https://www.chewy.com/hills-prescription-diet-id-digestive/dp/54681"))
        #expect(pack.registry.recognize(chewy)?.sourceId == "chewy.product")
        #expect(pack.registry.recognize(chewy)?.params["id"] == "54681")
        // A category page is not a product; it falls through (to the host's
        // own floor once loaded beside the starter).
        let category = try #require(URL(string: "https://www.chewy.com/b/cat-325"))
        #expect(pack.registry.recognize(category) == nil)

        // The brand form covers Amazon's storefront TLDs, and anchored
        // semantics keep lookalikes out.
        for host in ["www.amazon.com", "www.amazon.co.uk", "www.amazon.de"] {
            let url = try #require(URL(string: "https://\(host)/dp/B0018CLTKC"))
            #expect(pack.registry.recognize(url)?.sourceId == "amazon.product", "\(host)")
        }
        let lookalike = try #require(URL(string: "https://amazon.evil.com/dp/B0018CLTKC"))
        #expect(pack.registry.recognize(lookalike) == nil)
        // The brand matches every amazon.* host, so the paths carry the
        // product scope: the three product shapes, never AWS or a store page.
        for path in ["/gp/product/B0018CLTKC", "/KONG-Classic-Dog-Toy-Large/dp/B0018CLTKC", "/dp/B0018CLTKC/ref=sr_1_1"] {
            let url = try #require(URL(string: "https://www.amazon.com\(path)"))
            #expect(pack.registry.recognize(url)?.sourceId == "amazon.product", "\(path)")
        }
        for url in ["https://aws.amazon.com/s3/", "https://aws.amazon.com/", "https://www.amazon.com/stores/KONG/page/1", "https://www.amazon.com/s?k=kong"] {
            let target = try #require(URL(string: url))
            #expect(pack.registry.recognize(target) == nil, "\(url)")
        }
    }

    @Test
    func `The Chewy source reads a ProductGroup node, lowPrice and og-first image included`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "chewy.product"))
        // The Chewy lesson in one fixture: the listing is typed ProductGroup
        // (not Product), the price range publishes lowPrice (not price), and
        // the JSON-LD image is the site logo while og:image is the real shot.
        let html = """
        <html><head>
          <meta property="og:title" content="Hill's Prescription Diet i/d Digestive Care | Chewy.com" />
          <meta property="og:image" content="https://image.chewy.com/is/image/catalog/47885_MAIN.jpg" />
          <meta property="og:description" content="Vet-recommended digestive care." />
          <script type="application/ld+json">
          {
            "@type": "ProductGroup",
            "name": "Hill's Prescription Diet i/d Digestive Care",
            "brand": {"@type": "Brand", "name": "Hill's Prescription Diet"},
            "image": "https://www.chewy.com/assets/img/logo/chewy-opengraph.20170505.png",
            "offers": {"@type": "AggregateOffer", "lowPrice": "4.79", "highPrice": "112.99", "priceCurrency": "USD"},
            "aggregateRating": {"ratingValue": 4.4, "reviewCount": 2891}
          }
          </script>
        </head></html>
        """
        let url = try #require(URL(string: "https://www.chewy.com/hills-prescription-diet-id-digestive/dp/54681"))
        let context = ELVExtractionContext(url: url, params: ["slug": "hills-prescription-diet-id-digestive", "id": "54681"], document: ELVDocument(html: html))
        let record = ELVAssembler.assemble(source: source, context: context)

        let expectedImage = try #require(URL(string: "https://image.chewy.com/is/image/catalog/47885_MAIN.jpg"))
        #expect(record.externalId == "54681")
        #expect(record.fields["title"] == .text("Hill's Prescription Diet i/d Digestive Care"))
        #expect(record.fields["brand"] == .text("Hill's Prescription Diet"))
        #expect(record.fields["price"] == .money(minorUnits: 479, currencyCode: "USD"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: expectedImage, kind: ELVMediaRef.image)))
        // The typed aggregate rating every source shares, not raw text.
        #expect(record.fields["rating"] == .rating(value: 4.4, scale: 0 ... 5))
        #expect(record.fields["onlineRating"] == nil)
        #expect(record.identities == [ELVIdentity(namespace: "chewy.product", value: "54681", origin: .declared)])
    }

    @Test
    func `The Amazon source extracts from raw markup where no metadata exists`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "amazon.product"))
        // Amazon publishes neither OG nor JSON-LD; the markup candidates
        // (title span, byline link, image-gallery JSON) run over the raw
        // fetched HTML via textRegex.
        let html = """
        <html><head><title>Amazon.com: KONG Classic Dog Toy</title></head><body>
          <span id="productTitle" class="a-size-large">
            KONG &ndash; Classic Dog Toy, Durable Natural Rubber
          </span>
          <a id="bylineInfo" href="/stores/KONG">Visit the KONG Store</a>
          <script>var data = {"colorImages": [{"hiRes":"https://m.media-amazon.com/images/I/71bV0jN0.jpg","large":"https://m.media-amazon.com/images/I/51small.jpg"}]};</script>
        </body></html>
        """
        let url = try #require(URL(string: "https://www.amazon.com/KONG-Classic-Dog-Toy-Large/dp/B0002AR0II"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument(html: html)))

        let expectedImage = try #require(URL(string: "https://m.media-amazon.com/images/I/71bV0jN0.jpg"))
        #expect(record.externalId == "B0002AR0II")
        #expect(record.fields["title"] == .text("KONG – Classic Dog Toy, Durable Natural Rubber"))
        #expect(record.fields["brand"] == .text("KONG"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: expectedImage, kind: ELVMediaRef.image)))
        #expect(record.identities == [ELVIdentity(namespace: "amazon.asin", value: "B0002AR0II", origin: .declared)])
    }

    @Test
    func `The Amazon challenge shell yields no title, so the dom escalation fires`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "amazon.product"))
        // Amazon's bot interstitial ("Click the button below to continue
        // shopping") is HTTP 200 with a bare marketplace <title> and nothing
        // else. The bare title must be rejected, not stored as the product
        // title — a record saying "Amazon.com" is worse than a missing field
        // — and its absence is what the escalation trigger keys on.
        let html = """
        <html><head><title dir="ltr">Amazon.com</title></head><body>
          <h4>Click the button below to continue shopping</h4>
          <form method="get" action="/errors_page/validateCaptcha"></form>
        </body></html>
        """
        let url = try #require(URL(string: "https://www.amazon.com/dp/B0002AR0II"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument(html: html)))

        #expect(record.fields["title"] == nil)
        #expect(record.fields["image"] == nil)
        // The declared externalId still extracts from the URL alone.
        #expect(record.externalId == "B0002AR0II")

        let domStep = try #require(source.fetch?.resolvedSteps.first { $0.mode == "dom" })
        let trigger = try #require(domStep.when)
        #expect(trigger.fires(status: 200, extractedFields: record.fields))
    }
}
