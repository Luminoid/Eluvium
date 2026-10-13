import EluviumCore
import Foundation
import Synchronization
import Testing
@testable import EluviumPlaces

private typealias Point = ELVAnchorLadder.Point

/// A canned geocoder that counts its calls.
private final class StubGeocoder: ELVGeocoding, @unchecked Sendable {
    let forward: ELVGeocodedAddress?
    let reverse: ELVGeocodedAddress?
    private let calls = Mutex<[String]>([])

    init(forward: ELVGeocodedAddress? = nil, reverse: ELVGeocodedAddress? = nil) {
        self.forward = forward
        self.reverse = reverse
    }

    var callLog: [String] { calls.withLock { $0 } }

    func forwardGeocode(_ address: String) async throws -> ELVGeocodedAddress? {
        calls.withLock { $0.append("forward:\(address)") }
        return forward
    }

    func reverseGeocode(latitude _: Double, longitude _: Double) async throws -> ELVGeocodedAddress? {
        calls.withLock { $0.append("reverse") }
        return reverse
    }
}

/// A search stub that records the region it was biased to.
private final class RecordingSearch: ELVPlaceSearching, @unchecked Sendable {
    let results: [ELVGeocodedPlace]
    private let anchors = Mutex<[Point?]>([])

    init(results: [ELVGeocodedPlace]) {
        self.results = results
    }

    var searchedAnchors: [Point?] { anchors.withLock { $0 } }

    func search(_: String, near: Point?, radiusMeters _: Double) async throws -> [ELVGeocodedPlace] {
        anchors.withLock { $0.append(near) }
        return results
    }
}

@Suite("Address-anchored place lookup")
struct ELVAddressAnchorLookupTests {
    private let lima = ELVGeocodedAddress(latitude: -12.0482, longitude: -77.0328, isoCountryCode: "PE", country: "Peru", echoFields: ["Lima", "Peru"])
    private let fremont = ELVGeocodedAddress(latitude: 37.5485, longitude: -121.9886, isoCountryCode: "US", country: "United States", echoFields: ["Fremont", "CA"])
    private let address = "Jr. de la Unión 621, Lima 15001, Peru"

    @Test
    func `a street-address tail is worth anchoring, a bare region is not`() {
        #expect(ELVAddressAnchor.looksLikeStreetAddress(address))
        #expect(ELVAddressAnchor.looksLikeStreetAddress("Moose, Teton County, WY"))
        #expect(!ELVAddressAnchor.looksLikeStreetAddress("Wyoming"))
        #expect(!ELVAddressAnchor.looksLikeStreetAddress("Lima, Peru"))
    }

    @Test
    func `an anchor must sit in the address's own country`() {
        #expect(!ELVAddressAnchor.isPlausible(fremont, for: address))
        #expect(ELVAddressAnchor.isPlausible(lima, for: address))
    }

    @Test
    func `a country-less address anchor must echo an address token`() {
        let moose = ELVGeocodedAddress(latitude: 43.66, longitude: -110.71, isoCountryCode: "US", echoFields: ["Moose", "WY", "United States"])
        let springfield = ELVGeocodedAddress(latitude: 39.8, longitude: -89.6, isoCountryCode: "US", echoFields: ["Springfield", "IL", "United States"])
        #expect(ELVAddressAnchor.isPlausible(moose, for: "12170 Dornans Rd, Moose, WY 83012"))
        #expect(!ELVAddressAnchor.isPlausible(springfield, for: "12170 Dornans Rd, Moose, WY 83012"))
    }

    @Test
    func `the address anchor vouches for a nearby match`() async throws {
        let church = ELVGeocodedPlace(name: "Church of La Merced", latitude: -12.0485, longitude: -77.0330, category: "MKPOICategoryChurch")
        let search = RecordingSearch(results: [church])
        let resolution = try await ELVPlaceResolver(searcher: search).lookup(
            name: "Church of La Merced", locality: address, urlPin: nil, viewport: nil,
            policy: ELVPlaceLookupPolicy(), geocoder: StubGeocoder(forward: lima)
        )
        #expect(resolution?.point == Point(latitude: -12.0485, longitude: -77.0330))
        #expect(resolution?.origin == .geocodeAnchored)
        #expect(resolution?.place == church)
        #expect(search.searchedAnchors == [Point(latitude: -12.0482, longitude: -77.0328)])
    }

    @Test
    func `a same-named match 3 km from the address anchor is refused, and the anchor is the pin`() async throws {
        let elsewhere = ELVGeocodedPlace(name: "Church of La Merced", latitude: -12.0752, longitude: -77.0328)
        let resolution = try await ELVPlaceResolver(searcher: StubSearch(results: [elsewhere])).lookup(
            name: "Church of La Merced", locality: address, urlPin: nil, viewport: nil,
            policy: ELVPlaceLookupPolicy(), geocoder: StubGeocoder(forward: lima)
        )
        #expect(resolution?.place == nil)
        #expect(resolution?.point == Point(latitude: -12.0482, longitude: -77.0328))
        #expect(resolution?.origin == .geocodeAnchored)
    }

    @Test
    func `no valid anchor means no search and no pin`() async throws {
        let search = RecordingSearch(results: [ELVGeocodedPlace(name: "Church of La Merced", latitude: 37.55, longitude: -121.99)])
        let junkAnchor = try await ELVPlaceResolver(searcher: search).lookup(
            name: "Church of La Merced", locality: address, urlPin: nil, viewport: nil,
            policy: ELVPlaceLookupPolicy(), geocoder: StubGeocoder(forward: fremont)
        )
        #expect(junkAnchor == nil)
        let noGeocoder = try await ELVPlaceResolver(searcher: search).lookup(
            name: "Church of La Merced", locality: address, urlPin: nil, viewport: nil,
            policy: ELVPlaceLookupPolicy(), geocoder: nil
        )
        #expect(noGeocoder == nil)
        #expect(search.searchedAnchors.isEmpty)
    }

    @Test
    func `a URL pin trusts a match within the loose radius and skips the geocoder`() async throws {
        let pin = Point(latitude: 43.7650, longitude: -110.7290)
        let lake = ELVGeocodedPlace(name: "Jenny Lake", latitude: 43.7520, longitude: -110.7270, locality: "Moose", region: "WY")
        let geocoder = StubGeocoder(forward: lima)
        let resolution = try await ELVPlaceResolver(searcher: StubSearch(results: [lake])).lookup(
            name: "Jenny Lake", locality: "12170 Dornans Rd, Moose, WY", urlPin: pin, viewport: nil,
            policy: ELVPlaceLookupPolicy(), geocoder: geocoder
        )
        #expect(resolution?.point == Point(latitude: 43.7520, longitude: -110.7270))
        #expect(resolution?.origin == .urlPin)
        #expect(resolution?.place?.localitySubtitle == "Moose, WY")
        #expect(geocoder.callLog.isEmpty)
    }

    @Test
    func `a viewport match fills metadata but never the pin`() async throws {
        let viewport = Point(latitude: 43.75, longitude: -110.72)
        let lake = ELVGeocodedPlace(name: "Jenny Lake", latitude: 43.7520, longitude: -110.7270, category: "MKPOICategoryNationalPark")
        let resolution = try await ELVPlaceResolver(searcher: StubSearch(results: [lake])).lookup(
            name: "Jenny Lake", locality: nil, urlPin: nil, viewport: viewport,
            policy: ELVPlaceLookupPolicy(), geocoder: nil
        )
        #expect(resolution?.point == nil)
        #expect(resolution?.place?.category == "MKPOICategoryNationalPark")
    }

    @Test
    func `a miss reverse-geocodes the anchor for a missing locality`() async throws {
        let pin = Point(latitude: 43.7650, longitude: -110.7290)
        let geocoder = StubGeocoder(reverse: ELVGeocodedAddress(latitude: 43.765, longitude: -110.729, localitySubtitle: "Moose, WY"))
        let resolution = try await ELVPlaceResolver(searcher: StubSearch(results: [])).lookup(
            name: "Signal Mountain Overlook", locality: nil, urlPin: pin, viewport: nil,
            policy: ELVPlaceLookupPolicy(), geocoder: geocoder
        )
        #expect(resolution?.reverseLocality == "Moose, WY")
        #expect(resolution?.point == nil)
        #expect(geocoder.callLog == ["reverse"])
    }

    @Test
    func `policy radii clamp so a pack can tune but never disable the guards`() {
        let wide = ELVPlaceLookupPolicy(pinMeters: 1e9, addressMeters: -5, regionMeters: .nan)
        #expect(wide.pinMeters == 200_000)
        #expect(wide.addressMeters == 1)
        #expect(wide.regionMeters == 20000)
    }
}
