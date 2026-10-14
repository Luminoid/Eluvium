import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The TripDays provider-table block added 2026-08-21: recognition (hostile
/// lookalikes included), URL-only label parity pinned to TripDays'
/// `TravelLinkParserTests` expectations, stay-date extraction, lodging
/// types, and the Tripadvisor inference tables.
@Suite("Starter pack travel sources")
struct ELVStarterTravelSourcesTests {
    private func loaded() throws -> ELVLoadedPack {
        try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
    }

    /// The declared match surface, capability gate aside: redirector-priority
    /// assertions must hold even though this test binary lacks the shortlink
    /// op (which skips `shortlinks.travel` out of the loaded registry).
    private func declaredRegistry() throws -> ELVSourceRegistry {
        let pack = try loaded().pack
        return ELVSourceRegistry(sources: pack.sources.compactMap { source in
            source.match.map { ELVMatchableSource(id: source.id, match: $0) }
        })
    }

    /// Recognizes `url` in the loaded registry and assembles the URL-only
    /// record (empty document): exactly what a paste yields offline.
    private func assemble(_ url: String) throws -> ELVRecord {
        let pack = try loaded()
        let target = try #require(URL(string: url))
        let recognition = try #require(pack.registry.recognize(target), "\(url) did not recognize")
        let source = try #require(pack.source(withId: recognition.sourceId))
        return ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: target, params: recognition.params, document: ELVDocument()))
    }

    private func utcDay(_ value: ELVValue?) -> DateComponents? {
        guard case let .date(date, precision)? = value, precision == .day else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    // MARK: - Recognition

    @Test
    func `Every travel provider URL recognizes to its source`() throws {
        let cases: [(url: String, sourceId: String)] = [
            ("https://maps.apple.com/?q=Ferry+Building&ll=37.7955,-122.3937", "applemaps.place"),
            ("https://www.komoot.com/tour/123456789?share_token=aExample01", "komoot.route"),
            ("https://www.komoot.de/tour/987654321", "komoot.route"),
            ("https://www.booking.com/hotel/us/hotel-zephyr-san-francisco.html", "booking.lodging"),
            ("https://www.airbnb.com/rooms/12345678", "airbnb.lodging"),
            ("https://www.airbnb.co.uk/rooms/53019308", "airbnb.lodging"),
            ("https://www.vrbo.com/1234567", "vrbo.lodging"),
            ("https://www.agoda.com/hotel-zephyr/hotel/san-francisco-ca-us.html", "agoda.lodging"),
            ("https://www.expedia.co.uk/London-Hotels-The-Savoy.h11689.Hotel-Information", "expedia.lodging"),
            ("https://www.hostelworld.com/st/hostels/p/277953/the-yellow-rome/", "hostelworld.lodging"),
            ("https://uk.hotels.com/ho228907/", "hotels.lodging"),
            ("https://www.tripadvisor.com/Restaurant_Review-g60713-d3539600-Reviews-Gary_Danko-San_Francisco.html", "tripadvisor.review"),
            ("https://www.yelp.com/biz/gary-danko-san-francisco", "yelp.review"),
            ("https://www.getyourguide.com/paris-l16/eiffel-tower-summit-tour-t435659/", "gyg.tour"),
            ("https://www.viator.com/en-GB/tours/Rome/Colosseum-Tour/d511-1234ROME", "viator.tour"),
            ("https://www.klook.com/activity/2680-klook-pass-bangkok/", "klook.tour"),
            ("https://www.hertz.com/rentacar/reservation/", "carrental.brands"),
            ("https://www.sixt.de/mietwagen/", "carrental.brands"),
            ("https://www.flightaware.com/live/flight/UAL123", "flighttracker.flight"),
            ("https://fr24.com/UA123", "flighttracker.flight"),
            ("https://www.xiaohongshu.com/explore/64f1c2e3000000001e02a1b5", "xiaohongshu.post"),
        ]
        let registry = try loaded().registry
        for (url, sourceId) in cases {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target)?.sourceId == sourceId, "\(url)")
        }
    }

    @Test
    func `Hostile lookalikes and userinfo spoofs never match any travel source`() throws {
        // Anchored host + TLD-constrained brand matching: hyphenated,
        // suffixed, punycode, and userinfo spoofs all fall to the floor.
        let registry = try declaredRegistry()
        for url in [
            "https://airbnb.evil.com/rooms/1",
            "https://sixt.de.evil.io/mietwagen/",
            "https://booking.com.evil.com/hotel/us/x.html",
            "https://evil-booking.com/hotel/us/x.html",
            "https://xn--bookng-3ta.com/hotel/us/x.html",
            "https://yelp.com.attacker.net/biz/x",
            "https://tripadvisor.com.attacker.net/Hotel_Review-g1-d2-Reviews-X.html",
            "https://booking.com@evil.com/hotel/us/x.html",
            "https://hotels.com.evil.net/ho1/",
            "https://fr24.com.evil.io/UA123",
            "https://xiaohongshu.com.evil.cn/explore/64f1c2e3000000001e02a1b5",
            "https://maps.apple.com.evil.dev/?q=X",
        ] {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target) == nil, "\(url)")
        }
        // The brands' own international registrable domains still match
        // (TripDays `hostMatchesBrand` parity).
        let international = try #require(URL(string: "https://www.airbnb.com.au/rooms/33571268"))
        #expect(registry.recognize(international)?.sourceId == "airbnb.lodging")
        // Expedia matches by brand too, so storefronts beyond the four TLDs
        // it once listed recognize, and lookalikes still do not.
        for url in ["https://www.expedia.de/Berlin-Hotels-Adlon.h12345.Hotel-Information", "https://www.expedia.co.jp/Tokyo-Hotels-X.h678.Hotel-Information"] {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target)?.sourceId == "expedia.lodging", "\(url)")
        }
        for url in ["https://expedia.com.evil.io/X.h1.Hotel-Information", "https://evil-expedia.com/X.h1.Hotel-Information"] {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target) == nil, "\(url)")
        }
        let agoda = try #require(URL(string: "https://www.agoda.co.th/x/hotel/bangkok-th.html"))
        #expect(registry.recognize(agoda)?.sourceId == "agoda.lodging")
    }

    @Test
    func `Short share hosts stay with the redirector; the full hosts are the sources'`() throws {
        // Equal priority 90, declaration order breaks the tie: the bare
        // maps.apple short host expands via shortlinks.travel, while
        // maps.apple.com is applemaps.place's alone. Same split for yelp.to
        // vs yelp.com, and for xhslink.com (the media redirector, declared
        // after xiaohongshu.post) vs xiaohongshu.com.
        let registry = try declaredRegistry()
        func recognized(_ url: String) throws -> String? {
            try registry.recognize(#require(URL(string: url)))?.sourceId
        }
        #expect(try recognized("https://maps.apple/p/4yzVtPGTAYBHbCf") == "shortlinks.travel")
        // maps.apple.com is the Apple sources' (the MapKit shadow outranks
        // the URL-only source when both are declared).
        #expect(try recognized("https://maps.apple.com/?q=Ferry+Building") == "applemaps.place.mapkit")
        #expect(try recognized("http://xhslink.com/o/exampleId0") == "shortlinks.media")
        #expect(try recognized("https://www.xiaohongshu.com/explore/64f1c2e3000000001e02a1b5") == "xiaohongshu.post")
        #expect(try recognized("https://yelp.to/AbC123") == "shortlinks.travel")
        #expect(try recognized("https://abnb.me/AbCd1234") == "shortlinks.travel")
    }

    // MARK: - Google Maps

    @Test
    func `The Google place sources read metas in a scoped step; the share source keeps the fragment`() throws {
        // The shadow needs EluviumPlaces' ops, so it is skipped here: read the
        // resolved declarations off the pack, not the active roster.
        let pack = try loaded()
        func declared(_ id: String) throws -> ELVSource {
            try #require(pack.pack.sources.first { $0.id == id }, "\(id)")
        }
        // gmaps.place and its MapKit shadow fetch the place page as an
        // enrichment step scoped to the meta fields, so the MapKit lookup in
        // the URL step never runs twice.
        for id in ["gmaps.place", "gmaps.place.mapkit"] {
            let source = try declared(id)
            #expect(!source.use.contains("gmapsMetas"), "\(id)")
            let metaStep = try #require(source.fetch?.resolvedSteps.last, "\(id)")
            let names = try #require(metaStep.fields, "\(id)").map(\.name)
            #expect(names == ["metaNameRaw", "metaName", "address", "locality", "placeType", "category", "rating"], "\(id)")
            #expect(source.label == ["title", "metaName"], "\(id)")
        }
        // The share source renders, so its metas ride the flat ladder.
        #expect(try declared("gmaps.share").use.contains("gmapsMetas"))
        // The shadow: every field whose MapKit input reads `$field.title` is
        // declared after title, and every MapKit candidate shares one input
        // map, so the walk runs one search.
        let mapkit = try declared("gmaps.place.mapkit")
        let names = mapkit.fields.map(\.name)
        let title = try #require(names.firstIndex(of: "title"))
        var inputs = Set<[String: String]>()
        for field in mapkit.fields {
            for candidate in field.candidates {
                guard case let .native(op, input) = candidate.from, op == "place.mapKitLookup@2" else { continue }
                #expect(try #require(names.firstIndex(of: field.name)) > title, "\(field.name)")
                inputs.insert(input)
            }
        }
        #expect(inputs.count == 1)
    }

    @Test
    func `A Google place keys on its feature id, so zooming the same place keeps one record`() throws {
        // `/maps/place/` URLs rarely carry `ftid`; the `data=` blob's
        // `!1s0x…:0x…` token is the same feature id. Without it the record
        // keyed on a URL hash that changed with every `@lat,lng,zoom`.
        let feature = "0x89c25855c6480299:0x55194ec5a1ae072e"
        let urls = [
            "https://www.google.com/maps/place/Empire+State+Building/@40.7484405,-73.9878531,17z/data=!3m1!4b1!4m6!3m5!1s\(feature)!8m2!3d40.7484405!4d-73.9856644",
            "https://www.google.com/maps/place/Empire+State+Building/@40.7480,-73.9862,15z/data=!4m6!3m5!1s\(feature)!8m2!3d40.7484405!4d-73.9856644",
        ]
        for url in urls {
            let record = try assemble(url)
            #expect(record.sourceId == "gmaps.place", "\(url)")
            #expect(record.externalId == feature, "\(url)")
            #expect(record.identities == [ELVIdentity(namespace: "gmaps.feature", value: feature, origin: .declared)], "\(url)")
        }
        // `ftid` still answers where the data blob is absent, in the same namespace.
        let legacy = try assemble("https://maps.google.com/maps?q=Grand+Prismatic&ftid=0x5351eb9454af1c5d:0x1e0d0a7c3e5e5a5f")
        #expect(legacy.identities == [ELVIdentity(namespace: "gmaps.feature", value: "0x5351eb9454af1c5d:0x1e0d0a7c3e5e5a5f", origin: .declared)])
        // A URL with neither declares no identity (and keeps the hash id).
        let bare = try assemble("https://www.google.com/maps/place/Jenny+Lake/@43.7904,-110.7624,15z/data=!8m2!3d43.7904!4d-110.7624")
        #expect(bare.identities.isEmpty)
        // The MapKit shadow and the share rescue declare the same namespace.
        let pack = try loaded()
        for id in ["gmaps.place.mapkit", "gmaps.share"] {
            let source = try #require(pack.pack.sources.first { $0.id == id })
            #expect(source.identities.map(\.namespace).allSatisfy { $0 == "gmaps.feature" } && !source.identities.isEmpty, "\(id)")
        }
    }

    @Test
    func `The Maps sources require the renamed maps ops, every requirement versioned`() throws {
        let pack = try loaded()
        for source in pack.pack.sources {
            for requirement in source.requires {
                #expect(!requirement.hasPrefix("fetch:"), "\(source.id): \(requirement) is implied by a step mode")
                #expect(requirement.contains("@"), "\(source.id): \(requirement) is unversioned")
                #expect(!requirement.hasPrefix("native:gmaps."), "\(source.id): \(requirement)")
            }
        }
        let place = try #require(pack.source(withId: "gmaps.place"))
        #expect(place.requires.contains("native:maps.pinCoordinate@1"))
        #expect(place.requires.contains("native:maps.splitPlaceLabel@1"))
    }

    // MARK: - Apple Maps

    @Test
    func `Apple Maps reads the query label and ll coordinate, URL-only`() throws {
        let record = try assemble("https://maps.apple.com/?q=Ferry+Building&ll=37.7955,-122.3937")
        #expect(record.kind == "place")
        #expect(record.fields["title"] == .text("Ferry Building"))
        // Apple's `ll` IS the place on a share link (TripDays parity), so it
        // lands in `geo` through the viewport-named output.
        #expect(record.fields["geo"] == .geo(latitude: 37.7955, longitude: -122.3937))
    }

    @Test
    func `Apple Maps splits an address label, pins a coordinate-shaped q, and drops out-of-range pairs`() throws {
        let address = try assemble("https://maps.apple.com/?q=Jenny+Lake,+Wyoming&sll=43.75,-110.72")
        #expect(address.fields["title"] == .text("Jenny Lake"))
        #expect(address.fields["locality"] == .text("Wyoming"))

        let dropped = try assemble("https://maps.apple.com/?q=48.858,2.294")
        #expect(dropped.fields["geo"] == .geo(latitude: 48.858, longitude: 2.294))
        #expect(dropped.fields["title"] == nil)

        let outOfRange = try assemble("https://maps.apple.com/?ll=999,999")
        #expect(outOfRange.fields["geo"] == nil)

        let placeId = try assemble("https://maps.apple.com/place?place-id=IA1E29CEB4CDB2CADF&_provider=9902")
        #expect(placeId.externalId == "IA1E29CEB4CDB2CADF")
        #expect(placeId.identities == [ELVIdentity(namespace: "applemaps.place", value: "IA1E29CEB4CDB2CADF", origin: .declared)])
    }

    // MARK: - Lodging

    @Test
    func `Booking derives the property label, locale infix cut at the first dot`() throws {
        let record = try assemble("https://www.booking.com/hotel/us/hotel-zephyr-san-francisco.html")
        #expect(record.kind == "lodging")
        #expect(record.fields["title"] == .text("Hotel Zephyr San Francisco"))
        #expect(record.externalId == "hotel-zephyr-san-francisco")
        let localized = try assemble("https://www.booking.com/hotel/jp/tokyo-bay.zh-cn.html")
        #expect(localized.fields["title"] == .text("Tokyo Bay"))
    }

    @Test
    func `The Booking Share- short path is the redirector's, previewed as the lodging source`() throws {
        // A glued-prefix capture scopes the redirector to `/Share-…` alone;
        // real property pages stay booking.lodging's.
        let registry = try declaredRegistry()
        let share = try #require(URL(string: "https://www.booking.com/Share-aBcD12"))
        #expect(registry.recognize(share)?.sourceId == "booking.share")
        #expect(registry.recognize(share)?.params["token"] == "aBcD12")
        let page = try #require(URL(string: "https://www.booking.com/hotel/us/zephyr.html"))
        #expect(registry.recognize(page)?.sourceId == "booking.lodging")
        let pack = try loaded()
        let redirector = try #require(pack.pack.sources.first { $0.id == "booking.share" })
        #expect(redirector.previewAs == ["booking.com": "booking.lodging"])
    }

    @Test
    func `Stay dates lift from the query, aliases and Agoda's camel case included, yyyy-MM-dd only`() throws {
        let record = try assemble("https://www.booking.com/hotel/us/zephyr.html?checkin=2026-07-04&checkout=2026-07-08")
        #expect(utcDay(record.fields["checkIn"]) == DateComponents(year: 2026, month: 7, day: 4))
        #expect(utcDay(record.fields["checkOut"]) == DateComponents(year: 2026, month: 7, day: 8))

        let aliased = try assemble("https://www.booking.com/hotel/us/zephyr.html?ci=2026-07-04&co=2026-07-08")
        #expect(utcDay(aliased.fields["checkIn"]) == DateComponents(year: 2026, month: 7, day: 4))
        #expect(utcDay(aliased.fields["checkOut"]) == DateComponents(year: 2026, month: 7, day: 8))

        let agoda = try assemble("https://www.agoda.com/the-okura-tokyo/hotel/tokyo-jp.html?checkIn=2026-09-12&checkOut=2026-09-14")
        #expect(utcDay(agoda.fields["checkIn"]) == DateComponents(year: 2026, month: 9, day: 12))
        #expect(utcDay(agoda.fields["checkOut"]) == DateComponents(year: 2026, month: 9, day: 14))

        // Hotels.com spells the pair chkin/chkout (in the shared fragment);
        // Hostelworld spells it from/to (kept on that source alone, so the
        // shared ladder never learns names that mean other things elsewhere).
        let hotels = try assemble("https://www.hotels.com/ho276485/hotel-zephyr-san-francisco/?chkin=2026-07-04&chkout=2026-07-08")
        #expect(utcDay(hotels.fields["checkIn"]) == DateComponents(year: 2026, month: 7, day: 4))
        #expect(utcDay(hotels.fields["checkOut"]) == DateComponents(year: 2026, month: 7, day: 8))
        let hostel = try assemble("https://www.hostelworld.com/pwa/hosteldetails.php/Generator-Amsterdam/Amsterdam/265063?from=2026-07-04&to=2026-07-08")
        #expect(utcDay(hostel.fields["checkIn"]) == DateComponents(year: 2026, month: 7, day: 4))
        #expect(utcDay(hostel.fields["checkOut"]) == DateComponents(year: 2026, month: 7, day: 8))

        // Only yyyy-MM-dd-shaped values parse (TripDays parity); junk and
        // other date orders fall through to an absent field.
        let junk = try assemble("https://www.booking.com/hotel/us/zephyr.html?checkin=tomorrow&checkout=07/08/2026")
        #expect(junk.fields["checkIn"] == nil)
        #expect(junk.fields["checkOut"] == nil)
        let none = try assemble("https://www.airbnb.com/rooms/12345678")
        #expect(none.fields["checkIn"] == nil)
        #expect(none.fields["checkOut"] == nil)
    }

    @Test
    func `The lodging type rides the source's host brand`() throws {
        // TripDays `inferredLodgingType` parity, one deliberate departure:
        // airbnb → rental (a TYPE, like vrbo's; the brand already rides the
        // source id), vrbo → rental, hostelworld → hostel, every other
        // lodging host → hotel.
        let cases: [(url: String, type: String)] = [
            ("https://www.airbnb.com/rooms/12345678", "rental"),
            ("https://www.airbnb.co.uk/rooms/53019308", "rental"),
            ("https://www.vrbo.com/1234567", "rental"),
            ("https://www.hostelworld.com/st/hostels/p/277953/the-yellow-rome/", "hostel"),
            ("https://www.booking.com/hotel/us/hotel-zephyr-san-francisco.html", "hotel"),
            ("https://www.hotels.com/ho276485/hotel-zephyr-san-francisco-san-francisco-united-states-of-america/", "hotel"),
            ("https://www.expedia.com/Cowboy-Village-Resort.h894154.Hotel-Information", "hotel"),
            ("https://www.agoda.com/hotel-zephyr/hotel/san-francisco-ca-us.html", "hotel"),
        ]
        for (url, type) in cases {
            let record = try assemble(url)
            #expect(record.kind == "lodging", "\(url)")
            #expect(record.fields["lodgingType"] == .text(type), "\(url)")
        }
    }

    @Test
    func `Lodging, tour, and review sources declare identities that mirror their external ids`() throws {
        let cases: [(url: String, namespace: String, value: String)] = [
            ("https://www.booking.com/hotel/jp/tokyo-bay.zh-cn.html", "booking.hotel", "tokyo-bay"),
            ("https://www.airbnb.com/rooms/12345678", "airbnb.listing", "12345678"),
            ("https://www.vrbo.com/1234567", "vrbo.property", "1234567"),
            ("https://www.expedia.com/Cowboy-Village-Resort.h894154.Hotel-Information", "expedia.hotel", "894154"),
            ("https://www.hostelworld.com/st/hostels/p/277953/the-yellow-rome/", "hostelworld.property", "277953"),
            ("https://www.hostelworld.com/pwa/hosteldetails.php/Colonnato-di-San-Pietro-B-B/Rome/3552", "hostelworld.property", "3552"),
            ("https://uk.hotels.com/ho228907/", "hotels.hotel", "228907"),
            ("https://www.getyourguide.com/paris-l16/eiffel-tower-summit-tour-t435659/", "gyg.tour", "435659"),
            ("https://www.viator.com/tours/Paris/Eiffel-Tower-Priority-Access/d479-3731EIFFEL", "viator.product", "479-3731EIFFEL"),
            ("https://www.klook.com/activity/2680-klook-pass-bangkok/", "klook.activity", "2680"),
            ("https://www.tripadvisor.com/Restaurant_Review-g60713-d3539600-Reviews-Gary_Danko-San_Francisco.html", "tripadvisor.location", "3539600"),
            ("https://www.yelp.com/biz/ippudo-ny-new-york-4", "yelp.business", "ippudo-ny-new-york-4"),
        ]
        for (url, namespace, value) in cases {
            let record = try assemble(url)
            // The identity IS the external id, in the source's own namespace
            // (Booking's locale infix is cut the same way on both).
            #expect(record.externalId == value, "\(url)")
            #expect(record.identities == [ELVIdentity(namespace: namespace, value: value, origin: .declared)], "\(url)")
        }
        // An Airbnb /properties/ id is a different id space from /rooms/ (the
        // page 302s to another /rooms/ id), so it keys the record but never
        // joins the strong airbnb.listing namespace.
        let property = try assemble("https://www.airbnb.com/properties/1608222261053394311")
        #expect(property.externalId == "1608222261053394311")
        #expect(property.identities.isEmpty)
        // Agoda's hotel paths carry no id, so it declares no identity: a spec
        // that never produces would be dead pack weight.
        let agoda = try assemble("https://www.agoda.com/hotel-zephyr/hotel/san-francisco-ca-us.html")
        #expect(agoda.identities.isEmpty)
        // No id in the URL means no identity, never a URL-hash stand-in.
        let cityOnly = try assemble("https://www.viator.com/tours/Paris")
        #expect(cityOnly.identities.isEmpty)
    }

    @Test
    func `Agoda's label is the segment before hotel, locale prefixes guarded`() throws {
        let record = try assemble("https://www.agoda.com/hotel-zephyr/hotel/san-francisco-ca-us.html")
        #expect(record.fields["title"] == .text("Hotel Zephyr"))
        // A locale-shaped segment ("en-us", "zh-cn") is not the property.
        let locale = try assemble("https://www.agoda.com/en-us/hotel/bangkok-th.html")
        #expect(locale.fields["title"] == nil)
        let cn = try assemble("https://www.agoda.com/zh-cn/hotel/singapore-sg.html")
        #expect(cn.fields["title"] == nil)
    }

    @Test
    func `Expedia's label follows the Hotels split and the h-id marker`() throws {
        let split = try assemble("https://www.expedia.com/Jackson-Hole-Hotels-Cowboy-Village-Resort.h894154.Hotel-Information")
        #expect(split.fields["title"] == .text("Cowboy Village Resort"))
        #expect(split.externalId == "894154")
        // No destination prefix: the whole slug before .h<id> is the property.
        let bare = try assemble("https://www.expedia.com/Cowboy-Village-Resort.h894154.Hotel-Information")
        #expect(bare.fields["title"] == .text("Cowboy Village Resort"))
        // A non-property path (no .h<id>) yields no title (brand fallback).
        let flights = try assemble("https://www.expedia.com/Flights-Search")
        #expect(flights.fields["title"] == nil)
    }

    // MARK: - Reviews

    @Test
    func `Tripadvisor kinds infer from the path marker, attraction as the host prior`() throws {
        let attraction = try assemble("https://www.tripadvisor.com/Attraction_Review-g60763-d104365-Reviews-Central_Park-New_York_City_New_York.html")
        #expect(attraction.kind == "attraction")
        #expect(attraction.fields["title"] == .text("Central Park"))
        #expect(attraction.externalId == "104365")

        let hotel = try assemble("https://www.tripadvisor.com/Hotel_Review-g60713-d224953-Reviews-Hotel_Zephyr_San_Francisco-San_Francisco_California.html")
        #expect(hotel.kind == "lodging")
        #expect(hotel.fields["title"] == .text("Hotel Zephyr San Francisco"))

        let restaurant = try assemble("https://www.tripadvisor.com/Restaurant_Review-g60713-d3539600-Reviews-Gary_Danko-San_Francisco.html")
        #expect(restaurant.kind == "food")
        #expect(restaurant.fields["title"] == .text("Gary Danko"))

        // Non-review pages fall to the host prior with no label.
        let tourism = try assemble("https://www.tripadvisor.com/Tourism-g60763-New_York_City-Vacations.html")
        #expect(tourism.kind == "attraction")
        #expect(tourism.fields["title"] == nil)
    }

    @Test
    func `Tripadvisor pagination is skipped and a query param cannot flip the kind`() throws {
        let paged = try assemble("https://www.tripadvisor.com/Attraction_Review-g60763-d104365-Reviews-or15-Central_Park-New_York_City_New_York.html")
        #expect(paged.fields["title"] == .text("Central Park"))
        #expect(paged.kind == "attraction")
        // The marker is read from the path only: an echoing query param must
        // not turn a Tourism page into lodging (TripDays regression).
        let spoofed = try assemble("https://www.tripadvisor.com/Tourism-g60763-New_York_City-Vacations.html?ref=Hotel_Review")
        #expect(spoofed.kind == "attraction")
        #expect(spoofed.fields["category"] == nil)
    }

    @Test
    func `Yelp authors the food kind and strips the slug disambiguator`() throws {
        let record = try assemble("https://www.yelp.com/biz/gary-danko-san-francisco")
        #expect(record.kind == "food")
        #expect(record.fields["title"] == .text("Gary Danko San Francisco"))
        let disambiguated = try assemble("https://www.yelp.com/biz/ippudo-ny-new-york-4")
        #expect(disambiguated.fields["title"] == .text("Ippudo Ny New York"))
        #expect(disambiguated.externalId == "ippudo-ny-new-york-4")
    }

    // MARK: - Tours

    @Test
    func `Tour labels: GYG t-id strip, Viator tours anchor, Klook prefix strip`() throws {
        let gyg = try assemble("https://www.getyourguide.com/paris-l16/eiffel-tower-summit-tour-t435659/")
        #expect(gyg.kind == "activity")
        #expect(gyg.fields["title"] == .text("Eiffel Tower Summit Tour"))
        #expect(gyg.externalId == "435659")

        let viator = try assemble("https://www.viator.com/tours/Paris/Eiffel-Tower-Priority-Access/d479-3731EIFFEL")
        #expect(viator.fields["title"] == .text("Eiffel Tower Priority Access"))
        // A locale prefix shifts segments but not the label; a missing
        // activity segment yields no title, never the d-product code.
        let localized = try assemble("https://www.viator.com/en-GB/tours/Rome/Colosseum-Tour/d511-1234ROME")
        #expect(localized.fields["title"] == .text("Colosseum Tour"))
        let cityOnly = try assemble("https://www.viator.com/tours/Paris")
        #expect(cityOnly.fields["title"] == nil)

        let klook = try assemble("https://www.klook.com/activity/2680-klook-pass-bangkok/")
        #expect(klook.fields["title"] == .text("Klook Pass Bangkok"))
        #expect(klook.externalId == "2680")
    }

    // MARK: - Car rental

    @Test
    func `Car rental URLs label as their brand from the matched host`() throws {
        let cases: [(url: String, brand: String)] = [
            ("https://www.hertz.com/rentacar/reservation/", "Hertz"),
            ("https://www.avis.com/en/locations/us/ca/los-angeles", "Avis"),
            ("https://www.sixt.de/mietwagen/", "Sixt"),
            ("https://turo.com/us/en/car-rental/united-states/los-angeles-ca/123", "Turo"),
            ("https://www.discovercars.com/united-states-los-angeles", "Discover Cars"),
            ("https://www.nationalcar.com/en/car-rental/locations.html", "National"),
            ("https://www.rentalcars.com/us/city/los-angeles/", "Rentalcars.com"),
            ("https://www.enterprise.co.uk/en/car-hire/locations/uk.html", "Enterprise"),
            ("https://www.zipcar.com/boston", "Zipcar"),
        ]
        for (url, brand) in cases {
            let record = try assemble(url)
            #expect(record.kind == "transport", "\(url)")
            #expect(record.fields["title"] == .text(brand), "\(url)")
        }
    }

    // MARK: - Flight trackers

    @Test
    func `Flight trackers derive the designator from the URL and never fetch`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "flighttracker.flight"))
        #expect(source.fetch?.mode == "none")

        let icao = try assemble("https://www.flightaware.com/live/flight/UAL123")
        #expect(icao.kind == "flight")
        #expect(icao.fields["title"] == .text("UAL123"))
        #expect(icao.externalId == "UAL123")
        let lowercased = try assemble("https://www.flightradar24.com/data/flights/ua123")
        #expect(lowercased.fields["title"] == .text("UA123"))
        let short = try assemble("https://fr24.com/UA123")
        #expect(short.fields["title"] == .text("UA123"))
    }

    // MARK: - Komoot

    @Test
    func `Komoot keeps its share token through canonicalization and mirrors the AllTrails plan`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "komoot.route"))
        // `trail`, like AllTrails: a Komoot tour is a route, and `hike` was a
        // TripDays-era label no other source authored.
        #expect(source.kind == "trail")
        // The dom rung implies its own capability; `requires` lists only
        // the op no step mode implies.
        #expect(source.fetch?.requiredModes.contains("dom") == true)
        #expect(source.requires == ["native:trail.statsFromText@3"])
        #expect(source.fetch?.resolvedSteps.last?.regions == ["h1", "header", "body"])

        // `keep` (not `strip`): the share_token gates access to a private
        // tour, so canonicalization must never shed it.
        let canonicalize = try #require(source.canonicalize)
        let shared = try #require(URL(string: "https://www.komoot.com/tour/555044066?share_token=aExampleToken0&utm_source=share&ref=wtd"))
        let canonical = canonicalize.apply(to: shared)
        let items = URLComponents(url: canonical, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items == [URLQueryItem(name: "share_token", value: "aExampleToken0")])

        // http(crawler) first, dom escalation on block or empty extraction.
        let steps = try #require(source.fetch?.resolvedSteps)
        #expect(steps.map(\.mode) == ["http", "dom"])
        #expect(steps.first?.ua == "crawler")
        let trigger = try #require(steps.last?.when)
        #expect(trigger.fires(status: 403, extractedFields: ["title": .text("x")]))
        #expect(trigger.fires(status: 200, extractedFields: [:]))
    }

    @Test
    func `Komoot extracts the tour id offline and the stats op serves its fields`() throws {
        let record = try assemble("https://www.komoot.de/tour/987654321")
        #expect(record.kind == "trail")
        #expect(record.externalId == "987654321")
        #expect(record.identities == [ELVIdentity(namespace: "komoot.tour", value: "987654321", origin: .declared)])
        // Page prose feeds the same stats op AllTrails uses, through the
        // shared `trailStats` fragment.
        let pack = try loaded()
        let source = try #require(pack.source(withId: "komoot.route"))
        let document = ELVDocument(metas: [
            "og:title": "Hidden Falls Loop | Komoot",
            "og:description": "Try this 5.2-mile loop trail. Generally considered a moderate route, it takes an average of 2 h 30 m to complete.",
        ])
        let url = try #require(URL(string: "https://www.komoot.com/tour/123456789"))
        let fetched = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: document))
        #expect(fetched.fields["title"] == .text("Hidden Falls Loop"))
        #expect(fetched.fields["distance"] == .text("5.2 mi"))
        #expect(fetched.fields["difficulty"] == .text("Moderate"))
    }

    @Test
    func `AllTrails reads its LocalBusiness place node for the pin, address, and rating`() throws {
        // AllTrails types its trail node LocalBusiness, so the inline
        // TouristAttraction rating rung misses and the place node fills in.
        let pack = try loaded()
        let source = try #require(pack.source(withId: "alltrails.trail"))
        let html = """
        <html><head><meta property="og:title" content="Hidden Falls Trail | AllTrails">
        <script type="application/ld+json">{"@context":"https://schema.org","@type":"LocalBusiness","name":"Hidden Falls Trail",
        "address":{"@type":"PostalAddress","addressLocality":"Moose","addressRegion":"Wyoming","addressCountry":"United States"},
        "geo":{"@type":"GeoCoordinates","latitude":43.7598,"longitude":-110.7318},
        "aggregateRating":{"@type":"AggregateRating","ratingValue":4.7,"reviewCount":1200}}</script>
        </head><body></body></html>
        """
        let url = try #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))
        let recognition = try #require(pack.registry.recognize(url))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: recognition.params, document: ELVDocument(html: html)))
        #expect(record.fields["title"] == .text("Hidden Falls Trail"))
        #expect(record.fields["address"] == .text("Moose, Wyoming, United States"))
        #expect(record.fields["geo"] == .geo(latitude: 43.7598, longitude: -110.7318))
        #expect(record.fields["rating"] == .rating(value: 4.7, scale: 0 ... 5))
    }

    // MARK: - Xiaohongshu

    @Test
    func `Xiaohongshu reads og:title over the mobile fetch and escalates to dom on the bot wall`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "xiaohongshu.post"))
        let steps = try #require(source.fetch?.resolvedSteps)
        #expect(steps.map(\.mode) == ["http", "dom"])
        // The bot wall serves a 200 challenge shell with zero metadata, so
        // the escalation keys on empty extraction as well as blocked status.
        let trigger = try #require(steps.last?.when)
        #expect(trigger.fires(status: 200, extractedFields: [:]))

        let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/64f1c2e3000000001e02a1b5"))
        let document = ELVDocument(metas: ["og:title": "我真的太喜欢huckleberry了 目前为止王者是Missou - 小红书"])
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: document))
        #expect(record.kind == "post")
        #expect(record.fields["title"] == .text("我真的太喜欢huckleberry了 目前为止王者是Missou - 小红书"))
        #expect(record.externalId == "64f1c2e3000000001e02a1b5")
    }

    @Test
    func `Xiaohongshu reads the note from the page state and blanks wall titles so dead fetches fail`() throws {
        let pack = try loaded()
        let source = try #require(pack.source(withId: "xiaohongshu.post"))
        #expect(source.fetch?.resolvedSteps.first?.ua == "mobileSafari")
        let url = try #require(URL(string: "https://www.xiaohongshu.com/discovery/item/696365aa000000000a02eeeb?xsec_token=t"))
        // The mobile page ships no OG tags; the note rides its state JSON.
        let state = #"""
        <html><head><title>小红书</title></head><body><script>window.__INITIAL_STATE__={"data":{"noteData":{"noteId":"696365aa000000000a02eeeb",\#
        "title":"💥响盒子标本爆炸啦！！","desc":"#vlog[话题]#\n第二行","imageList":[{"height":1440,"width":1080,\#
        "url":"http:\u002F\u002Fsns-webpic-qc.xhscdn.com\u002Fa\u002Fb!h5_1080jpg"}]}}}</script></body></html>
        """#
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument(html: state)))
        #expect(record.fields["title"] == .text("💥响盒子标本爆炸啦！！"))
        #expect(record.fields["summary"] == .text("#vlog[话题]# 第二行"))
        let image = try #require(URL(string: "https://sns-webpic-qc.xhscdn.com/a/b!h5_1080jpg"))
        #expect(record.fields["image"] == .media(ELVMediaRef(url: image, kind: ELVMediaRef.image)))
        #expect(record.externalId == "696365aa000000000a02eeeb")

        // The login, 404, and security shells all print a real-looking
        // title; none may satisfy the source, so the dom rung gets its turn.
        for shell in ["小红书 - 你的生活兴趣社区", "你访问的页面不见了", "安全限制"] {
            let walled = ELVAssembler.assemble(source: source, context: ELVExtractionContext(
                url: url, document: ELVDocument(html: "<html><head><title>\(shell)</title><meta property=\"og:title\" content=\"\(shell)\"></head></html>")
            ))
            #expect(walled.fields["title"] == nil, "\(shell)")
        }
    }

    @Test
    func `Xiaohongshu reads the note whatever order the state lists its keys, and an empty title falls to the desc`() throws {
        // Three live notes (2026-10-11) opened their state with imageList,
        // with tagList and desc, and with noteId: the island candidates
        // anchor on the state's open and take the first key of each name.
        let pack = try loaded()
        let source = try #require(pack.source(withId: "xiaohongshu.post"))
        let url = try #require(URL(string: "https://www.xiaohongshu.com/discovery/item/68f28404000000000301b4f5?xsec_token=t&xsec_source=app_share&type=normal"))
        let reordered = #"""
        <html><head><meta name="og:title" content=" - rednote"><title>小红书</title></head><body><script>window.__INITIAL_STATE__=\#
        {"noteData":{"routeQuery":{"xsec_token":"t"},"data":{"noteData":{"tagList":[{"id":"1","name":"vlog","type":"topic"}],\#
        "desc":"准备了很久的弦乐特别现场\n第二行","imageList":[{"width":1080,"url":"http:\u002F\u002Fsns-webpic-qc.xhscdn.com\u002Fc\u002Fd"}],\#
        "noteId":"68f28404000000000301b4f5","type":"normal","title":"美妙难忘的夜晚，谢谢CAN！","user":{"nickname":"x"}}}}}</script></body></html>
        """#
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument(html: reordered)))
        #expect(record.fields["title"] == .text("美妙难忘的夜晚，谢谢CAN！"))
        #expect(record.fields["summary"] == .text("准备了很久的弦乐特别现场 第二行"))
        #expect(record.externalId == "68f28404000000000301b4f5")
        // A note may carry no title; the shells then print an empty
        // og:title (" - rednote"), which is a wall, so the desc's first
        // line stands in rather than a junk title passing the corpus.
        let untitled = reordered.replacingOccurrences(of: "\"title\":\"美妙难忘的夜晚，谢谢CAN！\"", with: "\"title\":\"\"")
        let fallback = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, document: ELVDocument(html: untitled)))
        #expect(fallback.fields["title"] == .text("准备了很久的弦乐特别现场"))
        for shell in [" - 小红书", " - rednote", "rednote"] {
            let walled = ELVAssembler.assemble(source: source, context: ELVExtractionContext(
                url: url, document: ELVDocument(html: "<html><head><title>\(shell)</title><meta property=\"og:title\" content=\"\(shell)\"></head></html>")
            ))
            #expect(walled.fields["title"] == nil, "\(shell)")
        }
    }

    @Test
    func `Xiaohongshu keeps only what the note page needs from an expanded share, never the sharer`() throws {
        // xhslink shares expand to a URL stamped with the minter's ids; the
        // keep-list leaves the note id, the token that gates the page, its
        // source, and the note type, so the sharer never reaches a record.
        let source = try #require(try loaded().source(withId: "xiaohongshu.post"))
        let expanded = try #require(URL(string: "https://www.xiaohongshu.com/discovery/item/64e6af220000000003023514?app_platform=ios&app_version=9.44.1"
                + "&share_from_user_hidden=true&xsec_source=app_share&type=video&xsec_token=CBk%3D&author_share=1&xhsshare=CopyLink"
                + "&shareRedId=FAKERED0&apptime=1700000000&share_id=00000000000000000000000000000000"))
        let canonical = try #require(source.canonicalize).apply(to: expanded)
        let items = URLComponents(url: canonical, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(Set(items.map(\.name)) == ["xsec_token", "xsec_source", "type"])
        #expect(canonical.path == "/discovery/item/64e6af220000000003023514")
        // The media redirector claims the short hosts and ships no corpus of
        // its own; it is a media-family source, so a media-only curation
        // keeps the expander.
        let redirector = try #require(try loaded().pack.sources.first { $0.id == "shortlinks.media" })
        #expect(redirector.resolvesVia == "shortlink.expand")
        #expect(redirector.examples.isEmpty)
        #expect(ELVCatalogFamilies.families["media"]?.contains("shortlinks.media") == true)
        #expect(ELVCatalogFamilies.families["travel"]?.contains("shortlinks.media") == false)
    }
}
