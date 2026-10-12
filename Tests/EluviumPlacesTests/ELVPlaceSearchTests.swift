import Foundation
import Testing
@testable import EluviumPlaces

private typealias Point = ELVAnchorLadder.Point

@Suite("Place lookup guards")
struct ELVPlaceLookupGuardsTests {
    @Test
    func `A result echoing no query token is a junk match`() {
        #expect(!ELVPlaceLookupGuards.echoes(
            query: "Shinjuku Gyoen National Garden 新宿御苑",
            fields: ["Tateyama", "Chiba Prefecture, Japan"]
        ))
        #expect(ELVPlaceLookupGuards.echoes(query: "Kamakura", fields: ["Kamakura-shi"]))
        // Diacritic-insensitive containment either way.
        #expect(ELVPlaceLookupGuards.echoes(query: "Café du Monde", fields: ["Cafe Du Monde", nil]))
        // A query with no usable tokens passes as unjudgeable.
        #expect(ELVPlaceLookupGuards.echoes(query: "!!", fields: ["Anything"]))
    }

    @Test
    func `firstTrusted rejects far matches and non-echoing matches`() {
        let anchor = Point(latitude: 37.7854, longitude: -122.3993)
        let far = ELVGeocodedPlace(name: "Benu", latitude: 37.55, longitude: -121.98) // ~45 km
        let junk = ELVGeocodedPlace(name: "Totally Different", latitude: 37.7855, longitude: -122.3994)
        let good = ELVGeocodedPlace(name: "Benu Restaurant", latitude: 37.7855, longitude: -122.3994)
        let trusted = ELVPlaceLookupGuards.firstTrusted(query: "Benu", results: [far, junk, good], anchor: anchor, maxMeters: 2000)
        #expect(trusted == good)
    }
}

@Suite("Place resolver")
struct ELVPlaceResolverTests {
    private let pin = Point(latitude: 37.7854, longitude: -122.3993)

    @Test
    func `An anchored match adopts the match's exact coordinate`() async throws {
        let match = ELVGeocodedPlace(name: "Benu Restaurant", latitude: 37.78545, longitude: -122.39935, address: "22 Hawthorne St", phone: "+1 415")
        let resolver = ELVPlaceResolver(searcher: StubSearch(results: [match]))
        let resolution = try #require(try await resolver.resolve(name: "Benu", urlPin: pin))
        #expect(resolution.origin == .urlPin)
        #expect(resolution.point == Point(latitude: 37.78545, longitude: -122.39935))
        #expect(resolution.place?.phone == "+1 415")
    }

    @Test
    func `A rejected match keeps the validated pin itself`() async throws {
        let junk = ELVGeocodedPlace(name: "Some Other Place", latitude: 37.7855, longitude: -122.3994)
        let resolver = ELVPlaceResolver(searcher: StubSearch(results: [junk]))
        let resolution = try #require(try await resolver.resolve(name: "Benu", urlPin: pin))
        #expect(resolution.point == pin)
        #expect(resolution.place == nil)
    }

    @Test
    func `A viewport-biased lookup fills metadata but never lands a coordinate`() async throws {
        let match = ELVGeocodedPlace(name: "Benu Restaurant", latitude: 37.7855, longitude: -122.3994, address: "22 Hawthorne St")
        let resolver = ELVPlaceResolver(searcher: StubSearch(results: [match]))
        let resolution = try #require(try await resolver.resolve(name: "Benu", urlPin: nil, viewport: pin))
        #expect(resolution.point == nil)
        #expect(resolution.origin == nil)
        #expect(resolution.place?.address == "22 Hawthorne St")
    }

    @Test
    func `No anchor at all skips the search entirely`() async throws {
        let resolver = ELVPlaceResolver(searcher: StubSearch(results: [ELVGeocodedPlace(name: "Benu", latitude: 1, longitude: 2)]))
        let resolution = try await resolver.resolve(name: "Benu", urlPin: nil, viewport: nil)
        #expect(resolution == nil)
    }

    @Test
    func `A backend failure throws instead of masquerading as no results`() async {
        let resolver = ELVPlaceResolver(searcher: ThrowingStubSearch())
        await #expect(throws: ThrowingStubSearch.StubError()) {
            _ = try await resolver.resolve(name: "Benu", urlPin: pin)
        }
        await #expect(throws: ThrowingStubSearch.StubError()) {
            _ = try await resolver.resolve(name: "Benu", urlPin: nil, viewport: pin)
        }
    }

    @Test
    func `A hung backend hits the lookup deadline instead of hanging the caller`() async {
        let resolver = ELVPlaceResolver(searcher: HangingStubSearch(), timeoutSeconds: 0.2)
        await #expect(throws: ELVPlaceLookupTimeout(seconds: 0.2)) {
            _ = try await resolver.resolve(name: "Benu", urlPin: pin)
        }
    }

    @Test
    func `An empty result set on the metadata path is a genuine nil, not an error`() async throws {
        let resolver = ELVPlaceResolver(searcher: StubSearch(results: []))
        let resolution = try await resolver.resolve(name: "Benu", urlPin: nil, viewport: pin)
        #expect(resolution == nil)
    }
}
