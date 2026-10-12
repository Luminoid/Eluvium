import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The parity criterion: Petfolio's `LinkAutofill` engine reimplemented
/// as a pack, byte-identical on the full fixture set including the Amazon
/// fallbacks. `Fixtures/` holds byte-identical copies of Petfolio's
/// `PetfolioTests/Fixtures/`, and the assertions mirror Petfolio's
/// `LinkExtractionTests` field for field: parity is on extracted values, not
/// mechanisms (Eluvium's money is minor-units + currency where Petfolio kept
/// a bare Double; provenance tags name Eluvium selectors).
///
/// The one sanctioned diff is substring → anchored host matching: recognition
/// runs through the registry with real product URLs, where Petfolio's
/// substring matcher tolerated shorthands like `chewy.com/dp/54767`.
@Suite("Petfolio fixture parity")
struct ELVPetfolioParityTests {
    private func loaded() throws -> ELVLoadedPack {
        try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
    }

    /// The retailer sources moved to the opt-in commerce pack (LEGAL.md);
    /// the parity criterion loads it directly, since proving field-level
    /// agreement with Petfolio's LinkAutofill is exactly what it is for.
    private func commerce() throws -> ELVLoadedPack {
        try ELVOptInPacks.commerce(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
    }

    private func fixtureHTML(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test
    func `Chewy fixture: ProductGroup title and brand, lowPrice as money, og-first image`() throws {
        let pack = try commerce()
        let source = try #require(pack.source(withId: "chewy.product"))
        let url = try #require(URL(string: "https://www.chewy.com/hills-prescription-diet-id-digestive/dp/54767"))
        let recognition = try #require(pack.registry.recognize(url))
        #expect(recognition.sourceId == "chewy.product")

        let document = try ELVDocument(html: fixtureHTML("chewy_product"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: recognition.params, document: document))

        // Petfolio: the listing is typed ProductGroup, not Product; the title
        // must come from JSON-LD, not og:title.
        #expect(record.externalId == "54767")
        #expect(record.fields["title"] == .text("Hill's Prescription Diet i/d Digestive Care with Chicken Wet Cat Food, 5.5-oz, case of 24"))
        #expect(record.provenance["title"]?.origin == "native:jsonld.bestPlaceNode@1")
        #expect(record.fields["brand"] == .text("Hill's Prescription Diet"))
        // AggregateOffer range: the coercion lands lowPrice (12.99 USD).
        #expect(record.fields["price"] == .money(minorUnits: 1299, currencyCode: "USD"))
        // The JSON-LD image is the site logo; og:image is the product shot.
        let expectedImage = try #require(URL(string: "https://image.chewy.com/catalog/general/images/moe/0682f18b-cfb1-79f0-8000-8b048e886f15._AC_SX500_SY400_QL75_V1_.jpg"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: expectedImage, kind: ELVMediaRef.image)))
        #expect(record.provenance["image"]?.origin == "meta:og:image")
        #expect(record.identities == [ELVIdentity(namespace: "chewy.product", value: "54767", origin: .declared)])
    }

    @Test
    func `Amazon fixture: markup fallbacks land the span title, byline brand, hiRes image, and no price`() throws {
        let pack = try commerce()
        let source = try #require(pack.source(withId: "amazon.product"))
        let url = try #require(URL(string: "https://www.amazon.com/dp/B0018CLTKC"))
        #expect(pack.registry.recognize(url)?.sourceId == "amazon.product")

        let document = try ELVDocument(html: fixtureHTML("amazon_product"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: document))

        // Amazon publishes neither OG nor JSON-LD Product; the markup
        // candidates carry the record.
        #expect(record.externalId == "B0018CLTKC")
        #expect(record.fields["title"] == .text("Blue Buffalo Life Protection Formula Adult Chicken & Brown Rice Recipe Dry Dog Food, 30-lb bag"))
        #expect(record.provenance["title"]?.origin == "textRegex")
        // "Visit the Blue Buffalo Store" byline collapses to the brand.
        #expect(record.fields["brand"] == .text("Blue Buffalo"))
        // First hiRes URL from the image-gallery JSON.
        let expectedImage = try #require(URL(string: "https://m.media-amazon.com/images/I/81abcDEFghL._AC_SL1500_.jpg"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: expectedImage, kind: ELVMediaRef.image)))
        // The fixture has no price surface, and the source declares none.
        #expect(record.fields["price"] == nil)
        #expect(record.identities == [ELVIdentity(namespace: "amazon.asin", value: "B0018CLTKC", origin: .declared)])
    }

    @Test
    func `Generic fixture: the floor walks @graph, decodes entities, types the string price, prefers the image array`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "generic.opengraph"))
        let url = try #require(URL(string: "https://pawsomeprovisions.example/p/1"))
        // No exact source claims the host; the floor is the extraction path.
        #expect(pack.registry.recognize(url) == nil)

        let document = try ELVDocument(html: fixtureHTML("generic_product"))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: document))

        // The Product node sits second in the @graph behind an Organization;
        // the product-typed candidates must not title the page after it.
        #expect(record.fields["title"] == .text("Salmon & Sweet Potato Grain-Free Kibble"))
        #expect(record.fields["brand"] == .text("Pawsome Provisions"))
        // Offer price arrives as a JSON string, currency from priceCurrency.
        #expect(record.fields["price"] == .money(minorUnits: 5499, currencyCode: "USD"))
        // JSON-LD image is an array; the first entry wins over og:image.
        let expectedImage = try #require(URL(string: "https://cdn.pawsomeprovisions.example/products/salmon-kibble-1.jpg"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: expectedImage, kind: ELVMediaRef.image)))
        #expect(record.fields["siteName"] == .text("Pawsome Provisions"))
    }

    @Test
    func `The title floor reads the html title when nothing structured exists`() throws {
        // Petfolio's `<title>` floor case. Its og:site_name suffix strip is
        // deliberately absent here: a dynamic strip keyed on another field is
        // not expressible in the pack schema, and on the fixture set it is
        // never load-bearing (JSON-LD wins every fixture title first).
        let pack = try loaded()
        let source = try #require(pack.source(withId: "generic.opengraph"))
        let document = ELVDocument(html: "<html><head><title>  Fancy Feast &amp; Friends  </title></head></html>")
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: URL(string: "https://store.example"), document: document))
        #expect(record.fields["title"] == .text("Fancy Feast & Friends"))
        #expect(record.provenance["title"]?.origin == "textRegex")
    }

    @Test
    func `Floor price metas are currency-honest: the pair lands, a bare amount stays empty`() throws {
        // Petfolio coerced `product:price:amount` to a bare Double; Eluvium's
        // money requires a currency, so the meta pair must both be present —
        // an unlabeled amount falls through rather than mislabeling.
        let pack = try loaded()
        let source = try #require(pack.source(withId: "generic.opengraph"))
        let url = URL(string: "https://acme.example")

        let paired = ELVDocument(metas: ["product:price:amount": "19.99", "product:price:currency": "usd"])
        let pairedRecord = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: paired))
        #expect(pairedRecord.fields["price"] == .money(minorUnits: 1999, currencyCode: "USD"))

        let bare = ELVDocument(metas: ["product:price:amount": "19.99"])
        let bareRecord = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: bare))
        #expect(bareRecord.fields["price"] == nil)
    }
}
