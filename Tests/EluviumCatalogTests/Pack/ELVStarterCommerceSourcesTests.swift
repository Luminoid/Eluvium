import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The commerce chunk: `camera.lens` over the lens-db maker hosts and
/// `camera.lens.sigma` for sigmaphoto. Recognition (excluded hosts and
/// lookalikes included), the host-anchored brand ladder, the title blanking
/// that keeps wall and site-name strings out of a lens title, Sigma's
/// description-first summary, and the kind gate that keeps a shop's flash
/// or filter from becoming a lens.
@Suite("Starter pack commerce sources")
struct ELVStarterCommerceSourcesTests {
    private func loaded() throws -> ELVLoadedPack {
        try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
    }

    /// Recognizes `url` and assembles it against `html` (the fetched page).
    private func assemble(_ url: String, html: String = "") throws -> ELVRecord {
        let pack = try loaded()
        let target = try #require(URL(string: url))
        let recognition = try #require(pack.registry.recognize(target), "\(url) did not recognize")
        let source = try #require(pack.source(withId: recognition.sourceId))
        return ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: target, params: recognition.params, document: ELVDocument(html: html)))
    }

    private func page(ogTitle: String? = nil, title: String? = nil, extra: String = "") -> String {
        var head = ""
        if let ogTitle { head += "<meta property=\"og:title\" content=\"\(ogTitle)\">" }
        if let title { head += "<title>\(title)</title>" }
        return "<html><head>\(head)\(extra)</head><body></body></html>"
    }

    // MARK: - Recognition

    @Test
    func `Lens product pages recognize on every maker host, the bare-slug Sigma host on its own source`() throws {
        let cases: [(url: String, sourceId: String)] = [
            ("https://electronics.sony.com/imaging/lenses/full-frame-e-mount/p/sel2470gm2", "camera.lens"),
            ("https://www.fujifilm-x.com/en-us/products/lenses/xf8-16mmf28-r-lm-wr/", "camera.lens"),
            ("https://leica-camera.com/en-US/photography/lenses/m/summilux-m-50", "camera.lens"),
            ("https://www.zeiss.com/consumer-products/int/photography/otus/otus-1455.html", "camera.lens"),
            ("https://www.sigma-global.com/en/lenses/a019_24_70_28/", "camera.lens"),
            ("https://www.tamron.com/global/consumer/lenses/b060/", "camera.lens"),
            ("https://www.cosina.co.jp/voigtlander/en/nokton-50mm-f1-2/", "camera.lens"),
            ("https://www.tokinalens.com/lenses/atx-m-23mm/", "camera.lens"),
            ("https://www.venuslens.net/product/laowa-9mm-f2-8-zero-d/", "camera.lens"),
            ("https://viltrox.com/products/af-9mm-f2-8-xf", "camera.lens"),
            ("https://7artisans.store/products/35mm-f0-95", "camera.lens"),
            ("https://ttartisan.store/products/50mm-f1-4", "camera.lens"),
            ("https://meikeglobal.com/products/85mm-t2-2", "camera.lens"),
            ("https://www.yongnuo.eu/product/yn50mm-f1-8s/", "camera.lens"),
            ("https://www.lksamyang.com/en/product/product-view.php?seq=531", "camera.lens"),
            ("https://www.sigmaphoto.com/10-18mm-f2-8-dc-dn-c", "camera.lens.sigma"),
        ]
        let registry = try loaded().registry
        for (url, sourceId) in cases {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target)?.sourceId == sourceId, "\(url)")
        }
    }

    @Test
    func `Excluded maker hosts, non-product paths, and lookalikes never match a lens source`() throws {
        let registry = try loaded().registry
        for url in [
            // Camera and lens pages share one path shape on these hosts.
            "https://www.usa.canon.com/shop/p/rf24-70mm-f2-8-l-is-usm",
            "https://www.dpreview.com/products/sony/lenses/sony_fe_24-70_2p8_gm_ii",
            "https://www.bhphotovideo.com/c/product/1700000-REG/sony_sel2470gm2.html",
            // A non-product path on a maker host.
            "https://viltrox.com/pages/about-us",
            "https://www.tamron.com/global/news/",
            // Anchored hosts.
            "https://viltrox.com.evil.io/products/af-9mm-f2-8-xf",
            "https://evil-sigmaphoto.com/10-18mm-f2-8-dc-dn-c",
            "https://www.sigmaphoto.com.attacker.net/10-18mm-f2-8-dc-dn-c",
        ] {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target) == nil, "\(url)")
        }
    }

    // MARK: - Brand

    @Test
    func `The brand ladder labels every maker host from the matched host alone`() throws {
        let cases: [(url: String, brand: String)] = [
            ("https://electronics.sony.com/imaging/lenses/full-frame-e-mount/p/sel2470gm2", "Sony"),
            ("https://www.fujifilm-x.com/en-us/products/lenses/xf8-16mmf28-r-lm-wr/", "Fujifilm"),
            ("https://leica-camera.com/en-US/photography/lenses/m/summilux-m-50", "Leica"),
            ("https://www.zeiss.com/consumer-products/int/photography/otus/otus-1455.html", "Zeiss"),
            ("https://www.sigma-global.com/en/lenses/a019_24_70_28/", "Sigma"),
            ("https://www.tamron.com/global/consumer/lenses/b060/", "Tamron"),
            ("https://www.voigtlaender.de/voigtlander/nokton/", "Voigtländer"),
            ("https://www.cosina.co.jp/voigtlander/en/nokton-50mm-f1-2/", "Voigtländer"),
            ("https://www.tokinalens.com/lenses/atx-m-23mm/", "Tokina"),
            ("https://www.venuslens.net/product/laowa-9mm-f2-8-zero-d/", "Laowa"),
            ("https://viltrox.com/products/af-9mm-f2-8-xf", "Viltrox"),
            ("https://7artisans.store/products/35mm-f0-95", "7Artisans"),
            ("https://ttartisan.store/products/50mm-f1-4", "TTArtisan"),
            ("https://meikeglobal.com/products/85mm-t2-2", "Meike"),
            ("https://www.yongnuo.eu/product/yn50mm-f1-8s/", "Yongnuo"),
            ("https://th.hkyongnuo.com/product/yn50mm-f1-8s/", "Yongnuo"),
            ("https://www.lksamyang.com/en/product/product-view.php?seq=531", "Samyang"),
            ("https://www.sigmaphoto.com/10-18mm-f2-8-dc-dn-c", "Sigma"),
        ]
        for (url, brand) in cases {
            #expect(try assemble(url).fields["brand"] == .text(brand), "\(url)")
        }
    }

    // MARK: - Title

    @Test
    func `Wall, site-name, and not-found titles are blanked on every rung, and the brand still lands`() throws {
        let url = "https://electronics.sony.com/imaging/lenses/full-frame-e-mount/p/sel2470gm2"
        for wall in ["Just a moment...", "Access Denied", "Sony Electronics | Official Site", "Not Found Page | Sony", "LK SAMYANG"] {
            let record = try assemble(url, html: page(ogTitle: wall, title: wall, extra: "<meta name=\"twitter:title\" content=\"\(wall)\">"))
            #expect(record.fields["title"] == nil, "\(wall)")
            #expect(record.fields["brand"] == .text("Sony"), "\(wall)")
        }
        // A blanked og:title falls through to the next rung that names the lens.
        let fallThrough = try assemble(url, html: page(ogTitle: "Just a moment...", title: "FE 24-70mm F2.8 GM II | Sony US"))
        #expect(fallThrough.fields["title"] == .text("FE 24-70mm F2.8 GM II | Sony US"))
    }

    @Test
    func `Samyang's page heading outranks its site-name og:title`() throws {
        let html = page(ogTitle: "LK SAMYANG", extra: "</head><body><h3 class=\"page-h3\">AF 12mm F2 E</h3>")
        let record = try assemble("https://www.lksamyang.com/en/product/product-view.php?seq=531", html: html)
        #expect(record.fields["title"] == .text("AF 12mm F2 E"))
        #expect(record.kind == "lens")
    }

    // MARK: - Summary

    @Test
    func `Sigma reads its meta description before og:description; the other hosts keep OG first`() throws {
        let both = "<meta property=\"og:description\" content=\"24mm F2 copy\"><meta name=\"description\" content=\"16-300mm copy\">"
        let sigma = try assemble("https://www.sigmaphoto.com/16-300mm-f3-5-6-7-dc-os-c", html: page(ogTitle: "Sigma 16-300mm F3.5-6.7 DC OS | Contemporary", extra: both))
        #expect(sigma.fields["summary"] == .text("16-300mm copy"))
        let ogOnly = try assemble("https://www.sigmaphoto.com/10-18mm-f2-8-dc-dn-c", html: page(extra: "<meta property=\"og:description\" content=\"10-18mm copy\">"))
        #expect(ogOnly.fields["summary"] == .text("10-18mm copy"))

        let tamron = try assemble("https://www.tamron.com/global/consumer/lenses/b060/", html: page(extra: both))
        #expect(tamron.fields["summary"] == .text("24mm F2 copy"))
    }

    @Test
    func `Fujifilm's one-letter og:description yields to the meta description, and its attachment-id og:image is refused`() throws {
        // fujifilm-x.com writes "P" and a bare WordPress attachment id where
        // its OG description and image belong on most lens pages (2026-10-12).
        let broken = "<meta property=\"og:description\" content=\"P\"><meta property=\"og:image\" content=\"http://92884\">"
            + "<meta name=\"description\" content=\"Product information for FUJINON XF8-16mmF2.8 R LM WR for FUJIFILM X Series\">"
        let fuji = try assemble("https://www.fujifilm-x.com/en-us/products/lenses/xf8-16mmf28-r-lm-wr/", html: page(ogTitle: "FUJINON XF8-16mmF2.8 R LM WR | Lenses", extra: broken))
        #expect(fuji.fields["summary"] == .text("Product information for FUJINON XF8-16mmF2.8 R LM WR for FUJIFILM X Series"))
        #expect(fuji.fields["image"] == nil)
        #expect(fuji.fields["title"] == .text("FUJINON XF8-16mmF2.8 R LM WR | Lenses"))
        // A real og:description still outranks the meta description there.
        let sane = "<meta property=\"og:description\" content=\"Red Badge zoom\"><meta name=\"description\" content=\"Product information\">"
        let newer = try assemble("https://www.fujifilm-x.com/en-us/products/lenses/xf16-55mmf28-r-lm-wr-ii/", html: page(extra: sane))
        #expect(newer.fields["summary"] == .text("Red Badge zoom"))
    }

    // MARK: - Kind gate

    @Test
    func `Neither lens source authors a kind; the category evidence decides`() throws {
        let pack = try loaded()
        for id in ["camera.lens", "camera.lens.sigma"] {
            let source = try #require(pack.source(withId: id))
            #expect(source.kind.isEmpty, "\(id)")
            #expect(source.inference?.categoryKeyword == ["lens": "lens", "product": "product"], "\(id)")
        }
    }

    @Test
    func `A lens-scoped path is a lens whatever the title says`() throws {
        // Leica and Zeiss write focal lengths without "mm"; the path carries it.
        let leica = try assemble("https://leica-camera.com/en-US/photography/lenses/m/summilux-m-50", html: page(ogTitle: "Summilux-M 50 f/1.4 ASPH."))
        #expect(leica.kind == "lens")
        let zeiss = try assemble("https://www.zeiss.com/consumer-products/int/photography/otus/otus-1455.html", html: page(ogTitle: "ZEISS Otus 1.4/55"))
        #expect(zeiss.kind == "lens")
        // A walled page with its title blanked still knows it is a lens.
        let walled = try assemble("https://electronics.sony.com/imaging/lenses/full-frame-e-mount/p/sel2470gm2", html: page(ogTitle: "Just a moment..."))
        #expect(walled.kind == "lens")
    }

    @Test
    func `On a whole-shop path the title decides: a focal length plus an aperture is a lens, anything else a product`() throws {
        let lenses: [(url: String, title: String)] = [
            ("https://viltrox.com/products/af-9mm-f2-8-xf", "Viltrox AF 9mm F2.8 Air X-Mount | Ultra-Wide APS-C Lens for Fujifilm"),
            ("https://7artisans.store/products/35mm-f0-95", "7Artisans 35mm F0.95 APS-C Lens"),
            ("https://ttartisan.store/products/50mm-f1-4", "TTArtisan 50mm f/1.4 Tilt"),
            ("https://meikeglobal.com/products/85mm-t2-2", "Meike 85mm T2.2 Cine Lens"),
            ("https://www.yongnuo.eu/product/yn50mm-f1-8s/", "YN50mm F1.8S DA DSM"),
            ("https://www.venuslens.net/product/laowa-9mm-f2-8-zero-d/", "Laowa 9mm F/2.8 Zero-D"),
        ]
        for (url, title) in lenses {
            let record = try assemble(url, html: page(ogTitle: title))
            #expect(record.kind == "lens", "\(title)")
            #expect(record.fields["category"] == .text("lens"), "\(title)")
        }
        let products: [(url: String, title: String)] = [
            ("https://www.yongnuo.eu/product/yn560-iv/", "YN560 IV Speedlite"),
            ("https://viltrox.com/products/weeylite-rb08p", "Viltrox Weeylite RB08P RGB Light"),
            ("https://ttartisan.store/products/58mm-uv-filter", "TTArtisan 58mm UV Filter"),
            ("https://meikeglobal.com/products/mk-eftz-b", "Meike MK-EFTZ-B Speed Booster 0.71x"),
        ]
        for (url, title) in products {
            let record = try assemble(url, html: page(ogTitle: title))
            #expect(record.kind == "product", "\(title)")
        }
        // No title (walled and blanked) means no evidence and no kind.
        let blank = try assemble("https://viltrox.com/products/af-9mm-f2-8-xf", html: page(ogTitle: "Just a moment..."))
        #expect(blank.kind.isEmpty)
        #expect(blank.fields["category"] == nil)
    }

    @Test
    func `sigmaphoto's catch-all slug is a lens only when the slug or the title says so`() throws {
        // The lens slug decides offline, before any title.
        #expect(try assemble("https://www.sigmaphoto.com/10-18mm-f2-8-dc-dn-c").kind == "lens")
        let titled = try assemble("https://www.sigmaphoto.com/sigma-24mm-f2-dg-dn-i", html: page(ogTitle: "Sigma 24mm F2 DG DN | Contemporary"))
        #expect(titled.kind == "lens")
        let camera = try assemble("https://www.sigmaphoto.com/sigma-fp-l", html: page(ogTitle: "Sigma fp L Mirrorless Camera"))
        #expect(camera.kind == "product")
        let about = try assemble("https://www.sigmaphoto.com/about-us")
        #expect(about.kind.isEmpty)
    }
}
