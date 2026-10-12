import Foundation
@testable import EluviumPlaces

/// A canned search backend: returns fixed results.
struct StubSearch: ELVPlaceSearching {
    var results: [ELVGeocodedPlace] = []

    func search(_: String, near _: ELVAnchorLadder.Point?, radiusMeters _: Double) async throws -> [ELVGeocodedPlace] {
        results
    }
}

/// A failing backend: always throws — the "MapKit failed" case, which must
/// stay distinguishable from "no results".
struct ThrowingStubSearch: ELVPlaceSearching {
    struct StubError: Error, Equatable {}

    func search(_: String, near _: ELVAnchorLadder.Point?, radiusMeters _: Double) async throws -> [ELVGeocodedPlace] {
        throw StubError()
    }
}

/// A hung backend: sleeps far past any test deadline before answering — the
/// MKLocalSearch-never-returns case the resolver's deadline race must
/// unblock instead of awaiting.
struct HangingStubSearch: ELVPlaceSearching {
    func search(_: String, near _: ELVAnchorLadder.Point?, radiusMeters _: Double) async throws -> [ELVGeocodedPlace] {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return []
    }
}
