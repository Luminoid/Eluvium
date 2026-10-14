import EluviumCore
import Foundation
import Testing
@testable import EluviumCatalog

/// The offline preview over the starter's travel family: what a host shows
/// the moment a link is pasted (label, kind, URL-borne pin, pending work),
/// pinned against the link shapes a trip planner sees.
@Suite("Starter travel preview")
struct ELVStarterTravelPreviewTests {
    private func pack() throws -> ELVLoadedPack {
        // The redirectors need their op registered to load; a stand-in that
        // never runs is enough for a preview. Registered only when absent:
        // the registry is process-wide, and another suite's stub must win.
        if !ELVNativeOps.isRegistered("shortlink.expand@1") {
            ELVNativeOps.registerAsync("shortlink.expand", version: 1) { _, _ in nil }
        }
        return try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: ELVBinary.version))
    }

    private func preview(_ text: String, in pack: ELVLoadedPack) throws -> ELVPreview {
        try pack.preview(#require(ELVPastedInput.parse(text, policy: pack.pastePolicy), "\(text)"))
    }

    private func label(_ text: String, in pack: ELVLoadedPack) throws -> String? {
        guard case let .text(value)? = try preview(text, in: pack).record.fields["label"] else { return nil }
        return value
    }

    @Test
    func `URL slugs label branded listings, the brand when the link has none`() throws {
        let pack = try pack()
        let cases: [(String, String)] = [
            ("https://www.alltrails.com/trail/us/california/mist-trail", "Mist Trail"),
            ("https://www.getyourguide.com/paris-l16/eiffel-tower-summit-tour-t435659/", "Eiffel Tower Summit Tour"),
            ("https://www.viator.com/tours/Paris/Eiffel-Tower-Priority-Access/d479-3731EIFFEL", "Eiffel Tower Priority Access"),
            ("https://www.viator.com/tours/Paris", "Viator"),
            ("https://www.klook.com/activity/2680-klook-pass-bangkok/", "Klook Pass Bangkok"),
            ("https://www.tripadvisor.com/Tourism-g60763-New_York_City-Vacations.html", "Tripadvisor"),
            ("https://www.yelp.com/biz/gary-danko-san-francisco", "Gary Danko San Francisco"),
            ("https://www.booking.com/hotel/jp/tokyo-bay.zh-cn.html", "Tokyo Bay"),
            ("https://www.booking.com/Share-aBcD12", "Booking.com"),
            ("https://www.airbnb.com/rooms/12345678", "Airbnb"),
            ("https://www.vrbo.com/1234567", "Vrbo"),
            ("https://www.agoda.com/hotel-zephyr/hotel/san-francisco-ca-us.html", "Hotel Zephyr"),
            ("https://www.agoda.com/en-us/hotel/bangkok-th.html", "Agoda"),
            ("https://www.expedia.com/Jackson-Hole-Hotels-Cowboy-Village-Resort.h894154.Hotel-Information", "Cowboy Village Resort"),
            ("https://www.expedia.com/Flights-Search", "Expedia"),
            ("https://www.flightaware.com/live/flight/UAL123", "UAL123"),
            ("https://www.flightradar24.com/data/flights/ua123", "UA123"),
            ("https://www.komoot.com/tour/123456789", "Komoot"),
            ("https://www.hertz.com/rentacar/reservation/", "Hertz"),
            ("https://gyg.me/AbCd123", "GetYourGuide"),
            ("https://yelp.to/AbC123", "Yelp"),
            ("https://expe.onelink.me/hnLd/abc1234x", "Expedia"),
            ("https://maps.app.goo.gl/372N2pn6HcSTEA4w6?g_st=ic", "Google Maps"),
            ("https://www.example.org/hotel/zephyr", "example.org"),
            ("flighty://flight/UA123", "UA123"),
            ("https://flighty.app/flight/aa100", "AA100"),
            ("https://www.flighty.app/share/abc", "Flighty"),
            ("https://live.flighty.app/00000000-0000-4000-8000-000000000001", "Flighty"),
        ]
        for (url, expected) in cases {
            #expect(try label(url, in: pack) == expected, "\(url)")
        }
    }

    @Test
    func `Maps links label from the place, never the brand or the viewport`() throws {
        let pack = try pack()
        #expect(try label("https://maps.apple.com/?q=Ferry+Building&ll=37.7955,-122.3937", in: pack) == "Ferry Building")
        let jenny = try preview("https://www.google.co.jp/maps/place/Jenny+Lake/@43.75,-110.72,14z/data=!8m2!3d43.7904!4d-110.7624", in: pack)
        #expect(jenny.sourceId?.hasPrefix("gmaps.place") == true)
        #expect(jenny.record.fields["label"] == .text("Jenny Lake"))
        #expect(jenny.record.fields["geo"] == .geo(latitude: 43.7904, longitude: -110.7624))
        #expect(jenny.record.fields["viewport"] == .geo(latitude: 43.75, longitude: -110.72))
        // The meta fetch is still pending: it carries type, rating, address.
        #expect(jenny.pending.contains(.fetch))
        let bigEndian = try preview(
            "https://maps.google.com/maps?q=United+States,+California,+Los+Angeles,+S+Western+Ave,+COIN+DE+RUE+bakery+and+cafe", in: pack
        )
        #expect(bigEndian.sourceId == "gmaps.share")
        #expect(bigEndian.record.fields["label"] == .text("COIN DE RUE bakery and cafe"))
        // No pin in the URL: the canonical-URL render is pending.
        #expect(bigEndian.pending == .fetch)
        let directions = try preview("https://www.google.com/maps/dir/SFO/Yosemite", in: pack)
        #expect(directions.sourceId == "gmaps.directions")
        #expect(directions.record.fields["label"] == nil)
        #expect(directions.pending.isEmpty)
    }

    @Test
    func `App-scheme links read their query`() throws {
        let pack = try pack()
        let google = try preview("comgooglemaps://?q=Tokyo+Tower", in: pack)
        #expect(google.sourceId == "gmaps.applink")
        #expect(google.record.fields["label"] == .text("Tokyo Tower"))
        let apple = try preview("maps://?q=Tokyo&ll=35.6586,139.7454", in: pack)
        #expect(apple.sourceId == "applemaps.applink")
        #expect(apple.record.fields["geo"] == .geo(latitude: 35.6586, longitude: 139.7454))
        #expect(apple.pending.isEmpty)
    }

    @Test
    func `A share blurb names the place and carries trail stats offline`() throws {
        let pack = try pack()
        let schwabacher = try preview("""
        Schwabacher's Landing Trail on AllTrails
        https://www.alltrails.com/trail/us/wyoming/schwabachers-landing?sh=7mixyz&utm_source=alltrails_virality
        """, in: pack)
        #expect(schwabacher.record.fields["label"] == .text("Schwabacher's Landing Trail"))
        #expect(schwabacher.record.fields["locality"] == .text("Wyoming, US"))
        #expect(schwabacher.pending.contains(.fetch))

        let mist = try preview("Mist Trail\n3.0 mi · Moderate · 2 h 30 m\nhttps://www.alltrails.com/trail/us/california/mist-trail?sh=abc", in: pack)
        #expect(mist.record.fields["label"] == .text("Mist Trail"))
        #expect(mist.record.fields["distance"] == .text("3.0 mi"))
        #expect(mist.record.fields["difficulty"] == .text("Moderate"))
        #expect(mist.record.fields["duration"] == .text("2 h 30 m"))

        // The share token never reads as a stat.
        let token = try preview("Hidden Falls via Jenny Lake Trail on AllTrails https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail?sh=7mixyz", in: pack)
        #expect(token.record.fields["label"] == .text("Hidden Falls via Jenny Lake Trail"))
        #expect(token.record.fields["distance"] == nil)

        // An arbitrary lead-in keeps the slug label.
        #expect(try label("Check this out https://www.alltrails.com/trail/us/california/mist-trail", in: pack) == "Mist Trail")
    }

    @Test
    func `A social share takes its title from the blurb until the page answers`() throws {
        let pack = try pack()
        let note = try preview("我真的太喜欢huckleberry了🫣 目前为止王者是：Missou... http://xhslink.com/o/exampleId0 \n拷走文字，去【小红书】探索这篇笔记~", in: pack)
        #expect(note.sourceId == "shortlinks.media")
        #expect(note.provisionalSourceId == "xiaohongshu.post")
        #expect(note.record.fields["label"] == .text("我真的太喜欢huckleberry了🫣 目前为止王者是：Missou"))
        #expect(note.pending == .redirect)
    }

    @Test
    func `Lookalike hosts never claim a travel source`() throws {
        let pack = try pack()
        let lookalikes = [
            "https://maps.google.evil.com/maps/place/X", "https://booking.com.evil.net/hotel/us/x.html",
            "https://evil-booking.com/hotel/us/x.html", "https://airbnb.evil.com/rooms/1",
        ]
        for url in lookalikes {
            let preview = try preview(url, in: pack)
            #expect(preview.sourceId == nil, "\(url)")
        }
    }

    @Test
    func `Stay dates lift from a lodging query offline`() throws {
        let pack = try pack()
        let stay = try preview("https://www.booking.com/hotel/us/zephyr.html?checkin=2026-07-04&checkout=2026-07-08", in: pack)
        #expect(stay.record.fields["checkIn"] != nil)
        #expect(stay.record.fields["checkOut"] != nil)
        #expect(stay.record.fields["lodgingType"] == .text("hotel"))
    }
}
