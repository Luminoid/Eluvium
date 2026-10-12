import Foundation
import Testing
@testable import EluviumPlaces

private typealias Point = ELVAnchorLadder.Point

@Suite("Anchor ladder")
struct ELVAnchorLadderTests {
    private let benu = Point(latitude: 37.7854, longitude: -122.3993)

    @Test
    func `A URL pin wins outright`() {
        let anchor = ELVAnchorLadder.resolve(urlPin: benu, geocoded: Point(latitude: 0, longitude: 0), viewport: nil)
        #expect(anchor == ELVAnchorLadder.Anchor(point: benu, origin: .urlPin))
    }

    @Test
    func `A geocode validates against the viewport by distance tier`() throws {
        let nearby = Point(latitude: 37.7860, longitude: -122.3990) // ~70 m
        let sameRegion = Point(latitude: 37.9, longitude: -122.5) // ~16 km
        let anchored = try #require(ELVAnchorLadder.resolve(urlPin: nil, geocoded: nearby, viewport: benu))
        #expect(anchored.origin == .geocodeAnchored)
        let plausible = try #require(ELVAnchorLadder.resolve(urlPin: nil, geocoded: sameRegion, viewport: benu))
        #expect(plausible.origin == .geocodePlausible)
    }

    @Test
    func `A far geocode, an unvalidated geocode, and a bare viewport all skip`() {
        let fremont = Point(latitude: 37.55, longitude: -121.98) // ~45 km — inside far, so shrink config
        let vienna = Point(latitude: 48.2, longitude: 16.37)
        #expect(ELVAnchorLadder.resolve(urlPin: nil, geocoded: vienna, viewport: benu) == nil)
        #expect(ELVAnchorLadder.resolve(urlPin: nil, geocoded: fremont, viewport: benu, config: ELVAnchorLadder.Config(farMeters: 10000)) == nil)
        #expect(ELVAnchorLadder.resolve(urlPin: nil, geocoded: fremont, viewport: nil) == nil)
        #expect(ELVAnchorLadder.resolve(urlPin: nil, geocoded: nil, viewport: benu) == nil)
    }

    @Test
    func `Pack radii are clamped and near never exceeds far`() {
        // The radii are the packs' only unclamped numeric knob otherwise: a
        // 1e9 m radius would dissolve the trust ladder entirely.
        let absurd = ELVAnchorLadder.Config(nearMeters: 1e9, farMeters: 1e9)
        #expect(absurd.nearMeters == 5000)
        #expect(absurd.farMeters == 200_000)
        let inverted = ELVAnchorLadder.Config(nearMeters: 5000, farMeters: 100)
        #expect(inverted.nearMeters == 100)
        #expect(inverted.farMeters == 100)
        let floors = ELVAnchorLadder.Config(nearMeters: 0, farMeters: -1)
        #expect(floors.nearMeters == 1)
        #expect(floors.farMeters == 1)
        // A NaN falls back to the default rather than poisoning every
        // distance comparison downstream.
        let nan = ELVAnchorLadder.Config(nearMeters: .nan, farMeters: .nan)
        #expect(nan.nearMeters == 2000)
        #expect(nan.farMeters == 50000)
    }
}
