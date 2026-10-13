import EluviumCore
import Foundation
import Testing

@Suite("Pasted input")
struct ELVPastedInputTests {
    @Test
    func `ordinary titles never become links`() {
        let titles = [
            "Dinner at 7", "Mt. Bonnell picnic", "v2.0", "Lunch", "", "Booked Viator tour", "Check tripadvisor reviews",
            "Dinner with the team at 7", "v2.0 planning notes",
        ]
        for title in titles {
            #expect(ELVPastedInput.parse(title) == nil, "\(title)")
        }
    }

    @Test
    func `dotted words with unknown TLDs are titles`() {
        #expect(ELVPastedInput.parse("Dinner.at") == nil)
        #expect(ELVPastedInput.parse("v2.beta") == nil)
        #expect(ELVPastedInput.parse("Ver2.rc") == nil)
        #expect(ELVPastedInput.parse("a..com") == nil)
    }

    @Test
    func `a paste glued to typed text keeps no junk scheme`() {
        #expect(ELVPastedInput.parse("Dinhttps://www.google.com/maps/place/X") == nil)
        #expect(ELVPastedInput.parse("javascript://alert(1)") == nil)
    }

    @Test
    func `bare hosts gain https and keep the rest verbatim`() throws {
        let input = try #require(ELVPastedInput.parse("alltrails.com/trail/us/texas/mt-bonnell-trail"))
        #expect(input.urlText == "https://alltrails.com/trail/us/texas/mt-bonnell-trail")
        #expect(input.url.host == "alltrails.com")
        #expect(input.leadingText == nil)
        #expect(input.blurb == nil)
        for token in ["gyg.me/AbC123", "yelp.to/AbC1", "komoot.de/tour/1234", "expedia.co.uk/Flights-Search", "maps.apple/p/4yzVtPGTAYBHbCf", "flighty.app/flight/UA123"] {
            #expect(ELVPastedInput.parse(token) != nil, "\(token)")
        }
    }

    @Test
    func `known schemes parse and http is never upgraded in the stored text`() throws {
        #expect(try #require(ELVPastedInput.parse("flighty://flight/UA123")).urlText == "flighty://flight/UA123")
        #expect(try #require(ELVPastedInput.parse("comgooglemaps://?q=Tokyo+Tower")).url.scheme == "comgooglemaps")
        let http = try #require(ELVPastedInput.parse("http://xhslink.com/o/AbC"))
        #expect(http.urlText == "http://xhslink.com/o/AbC")
    }

    @Test
    func `a share blurb splits into the link, its lead-in, and the blurb without the link`() throws {
        let raw = "Hidden Falls via Jenny Lake Trail on AllTrails https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail?sh=7mixyz&utm_medium=trail_share"
        let input = try #require(ELVPastedInput.parse(raw))
        #expect(input.urlText == "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail?sh=7mixyz&utm_medium=trail_share")
        #expect(input.leadingText == "Hidden Falls via Jenny Lake Trail on AllTrails")
        // The share token never reaches the blurb, so it can't read as "7 mi".
        let blurb = try #require(input.blurb)
        #expect(!blurb.contains("7mixyz"))
        #expect(blurb.contains("Hidden Falls"))
    }

    @Test
    func `multi-word text needs an explicit scheme`() {
        #expect(ELVPastedInput.parse("see alltrails.com/trail/us/x/y for details") == nil)
    }

    @Test
    func `an oversized paste is rejected before any scan`() {
        let huge = "Check this out https://www.alltrails.com/trail/us/california/mist-trail " + String(repeating: "a", count: 9000)
        #expect(ELVPastedInput.parse(huge) == nil)
    }

    @Test
    func `the link field reading is lenient but single-token`() throws {
        #expect(try #require(ELVPastedInput.link("example.museum/page")).urlText == "https://example.museum/page")
        #expect(ELVPastedInput.link("two words") == nil)
        #expect(ELVPastedInput.link("https://") == nil)
    }

    @Test
    func `a policy can widen the bare-host TLD set`() {
        var policy = ELVPastePolicy.standard
        policy.bareHostTLDs.insert("travel")
        #expect(ELVPastedInput.parse("trip.travel/x", policy: policy) != nil)
        #expect(ELVPastedInput.parse("trip.travel/x") == nil)
    }

    @Test
    func `the share name needs a separator and the brand`() {
        let separators = ELVPastePolicy.standard.labelSeparators
        #expect(ELVShareLabel.suffixed(leading: "Schwabacher's Landing Trail on AllTrails", brand: "AllTrails", separators: separators) == "Schwabacher's Landing Trail")
        #expect(ELVShareLabel.suffixed(leading: "Ippudo - Yelp", brand: "Yelp", separators: separators) == "Ippudo")
        #expect(ELVShareLabel.suffixed(leading: "Line one\nTartine · google maps", brand: "Google Maps", separators: separators) == "Tartine")
        #expect(ELVShareLabel.suffixed(leading: "Check this out", brand: "AllTrails", separators: separators) == nil)
        #expect(ELVShareLabel.suffixed(leading: " on AllTrails", brand: "AllTrails", separators: separators) == nil)
        #expect(ELVShareLabel.suffixed(leading: "X on AllTrails", brand: "", separators: separators) == nil)
    }

    @Test
    func `the whole lead-in drops truncation marks and caps its length`() {
        #expect(ELVShareLabel.whole(leading: "我真的太喜欢huckleberry了🫣 目前为止王者是：Missou...") == "我真的太喜欢huckleberry了🫣 目前为止王者是：Missou")
        #expect(ELVShareLabel.whole(leading: "  …  ") == nil)
        let long = String(repeating: "x", count: 100)
        #expect(ELVShareLabel.whole(leading: long) == String(repeating: "x", count: 80) + "…")
    }

    @Test
    func `a paste context carries the blurb and a typed label`() throws {
        let input = try #require(ELVPastedInput.parse("Mist Trail on AllTrails https://www.alltrails.com/trail/us/california/mist-trail"))
        var context = try #require(ELVPasteContext(input: input, userLabel: "  "))
        #expect(context.userLabel == nil)
        context.brand = "AllTrails"
        #expect(context.leading == "Mist Trail on AllTrails")
        #expect(ELVPasteContext(input: ELVPastedInput(url: input.url)) == nil)
        #expect(ELVPasteContext(input: ELVPastedInput(url: input.url), userLabel: "Mine")?.userLabel == "Mine")
    }
}
