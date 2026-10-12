import EluviumCatalog
import EluviumCore
import Foundation
import Testing
@testable import EluviumPlaces

/// Serialized: every test re-registers ops in the shared process-wide
/// registry, and parallel re-registration would race across tests.
@Suite("Places native ops", .serialized)
struct ELVPlacesOpsTests {
    private let match = ELVGeocodedPlace(name: "Benu Restaurant", latitude: 37.7855, longitude: -122.3994, address: "22 Hawthorne St", locality: "San Francisco")

    @Test
    func `geo anchorLadder registers as a sync op with config knobs as inputs`() throws {
        ELVPlacesOps.register(searcher: StubSearch(results: [match]))
        let op = try #require(ELVNativeOps.lookup("geo.anchorLadder"))
        let outputs = try #require(op(["urlLat": "37.7854", "urlLng": "-122.3993"], ELVExtractionContext()))
        #expect(outputs["geo"] == .geo(latitude: 37.7854, longitude: -122.3993))
        #expect(outputs["origin"] == .text("urlPin"))
        // The pack's own radii ride as inputs: a 100 m far radius rejects a
        // ~70 m-off geocode's plausible tier only when tightened below it.
        let tightened = op([
            "geoLat": "37.7860", "geoLng": "-122.3990",
            "viewportLat": "37.7854", "viewportLng": "-122.3993",
            "nearMeters": "10", "farMeters": "20",
        ], ELVExtractionContext())
        #expect(tightened == nil)
    }

    @Test
    func `place mapKitLookup registers as an async op and gates capabilities`() async throws {
        ELVPlacesOps.register(searcher: StubSearch(results: [match]))
        #expect(ELVNativeOps.isRegistered("place.mapKitLookup"))
        #expect(ELVNativeOps.isRegistered("place.mapKitLookup@1"))
        let op = try #require(ELVNativeOps.lookupAsync("place.mapKitLookup"))
        let outputs = try #require(await op(["name": "Benu", "urlLat": "37.7854", "urlLng": "-122.3993"], ELVExtractionContext()))
        #expect(outputs["geo"] == .geo(latitude: 37.7855, longitude: -122.3994))
        #expect(outputs["address"] == .text("22 Hawthorne St"))
        #expect(outputs["locality"] == .text("San Francisco"))
        #expect(outputs["origin"] == .text("urlPin"))
        let skipped = try await op(["name": "Benu"], ELVExtractionContext())
        #expect(skipped == nil)
    }

    @Test
    func `Absurd pack radii are clamped before they dissolve the trust ladder`() throws {
        ELVPlacesOps.register(searcher: StubSearch())
        let op = try #require(ELVNativeOps.lookup("geo.anchorLadder"))
        // farMeters 1e9 clamps to 200 km (`ELVAnchorLadder.Config`): a
        // geocode ~250 km from the viewport still fails the plausible tier.
        let outputs = op([
            "geoLat": "40.0354", "geoLng": "-122.3993",
            "viewportLat": "37.7854", "viewportLng": "-122.3993",
            "farMeters": "1000000000",
        ], ELVExtractionContext())
        #expect(outputs == nil)
    }

    @Test
    func `Out-of-range and null-island coordinates never enter the ladder`() throws {
        ELVPlacesOps.register(searcher: StubSearch())
        let op = try #require(ELVNativeOps.lookup("geo.anchorLadder"))
        #expect(op(["urlLat": "91", "urlLng": "-122.3993"], ELVExtractionContext()) == nil)
        #expect(op(["urlLat": "37.7854", "urlLng": "181"], ELVExtractionContext()) == nil)
        #expect(op(["urlLat": "0", "urlLng": "0"], ELVExtractionContext()) == nil)
    }

    @Test
    func `place mapKitLookup propagates a backend failure as a thrown error`() async throws {
        ELVPlacesOps.register(searcher: ThrowingStubSearch())
        let op = try #require(ELVNativeOps.lookupAsync("place.mapKitLookup"))
        await #expect(throws: ThrowingStubSearch.StubError()) {
            _ = try await op(["name": "Benu", "urlLat": "37.7854", "urlLng": "-122.3993"], ELVExtractionContext())
        }
    }

    @Test
    func `place mapKitLookup returns nil only for genuinely-no-results`() async throws {
        ELVPlacesOps.register(searcher: StubSearch(results: []))
        let op = try #require(ELVNativeOps.lookupAsync("place.mapKitLookup"))
        // Viewport-only with an empty answer: nothing matched, so nil.
        let empty = try await op(["name": "Benu", "viewportLat": "37.7854", "viewportLng": "-122.3993"], ELVExtractionContext())
        #expect(empty == nil)
        // URL-pin with an empty answer: the pin itself still resolves.
        let pinned = try await op(["name": "Benu", "urlLat": "37.7854", "urlLng": "-122.3993"], ELVExtractionContext())
        #expect(pinned?["geo"] == .geo(latitude: 37.7854, longitude: -122.3993))
        #expect(pinned?["origin"] == .text("urlPin"))
    }

    // MARK: - The starter pack's mapkit place flow

    private let benu = ELVGeocodedPlace(
        name: "Benu",
        latitude: 37.7855, longitude: -122.3994,
        address: "22 Hawthorne St, San Francisco",
        locality: "San Francisco",
        phone: "+1 415-685-4860",
        category: "MKPOICategoryRestaurant"
    )

    private func starterSource(_ id: String) throws -> (source: ELVSource, pack: ELVLoadedPack) {
        let pack = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
        let source = try #require(pack.source(withId: id))
        return (source, pack)
    }

    @Test
    func `The mapkit place source wins recognition when the ops are registered and serves address, phone, and refined geo`() async throws {
        ELVPlacesOps.register(searcher: StubSearch(results: [benu]))
        let (source, pack) = try starterSource("gmaps.place.mapkit")
        // Priority 110 shadows plain gmaps.place only in a Places binary.
        let url = try #require(URL(string: "https://www.google.com/maps/place/Benu/@37.7854,-122.3993,17z/data=!8m2!3d37.7854!4d-122.3993"))
        let recognition = try #require(pack.registry.recognize(url))
        #expect(recognition.sourceId == "gmaps.place.mapkit")
        // The pack loads diagnostic-free with the async ops live in fields.
        #expect(pack.diagnostics.isEmpty, "\(pack.diagnostics)")

        let result = try await ELVExtractor.extractAsync(fields: source.fields, context: ELVExtractionContext(url: url, params: recognition.params))
        #expect(result.values["title"] == .text("Benu"))
        // The match's own coordinate refines the pin — the pin validated it
        // (TripDays fillPlaceDetails / Petfolio vet-contact parity).
        #expect(result.values["geo"] == .geo(latitude: 37.7855, longitude: -122.3994))
        #expect(result.values["address"] == .text("22 Hawthorne St, San Francisco"))
        // A place-path URL with no comma segments has no URL-derived
        // locality; the lookup's placemark fills it (the COIN DE RUE case).
        #expect(result.values["locality"] == .text("San Francisco"))
        #expect(result.values["phone"] == .text("+1 415-685-4860"))
        #expect(result.values["category"] == .text("MKPOICategoryRestaurant"))
    }

    @Test
    func `A failed MapKit backend degrades to the anchor ladder's raw URL pin, metadata absent`() async throws {
        ELVPlacesOps.register(searcher: ThrowingStubSearch())
        let (source, _) = try starterSource("gmaps.place.mapkit")
        let url = try #require(URL(string: "https://www.google.com/maps/place/Benu/@37.7854,-122.3993,17z/data=!8m2!3d37.7854!4d-122.3993"))
        let result = try await ELVExtractor.extractAsync(fields: source.fields, context: ELVExtractionContext(url: url))
        // The throw invalidated the mapKit candidates; geo.anchorLadder's
        // URL-pin tier still lands the coordinate (skip beats wrong never
        // means losing the pin the URL itself carries).
        #expect(result.values["geo"] == .geo(latitude: 37.7854, longitude: -122.3993))
        #expect(result.values["title"] == .text("Benu"))
        #expect(result.values["address"] == nil)
        #expect(result.values["phone"] == nil)
    }

    @Test
    func `A viewport-only Maps URL fills metadata but never a coordinate`() async throws {
        ELVPlacesOps.register(searcher: StubSearch(results: [benu]))
        let (source, _) = try starterSource("gmaps.place.mapkit")
        // No !3d!4d pair: the /@ segment is only the viewport.
        let url = try #require(URL(string: "https://www.google.com/maps/place/Benu/@37.7854,-122.3993,15z"))
        let result = try await ELVExtractor.extractAsync(fields: source.fields, context: ELVExtractionContext(url: url))
        #expect(result.values["title"] == .text("Benu"))
        // The viewport-biased lookup serves metadata only.
        #expect(result.values["address"] == .text("22 Hawthorne St, San Francisco"))
        #expect(result.values["phone"] == .text("+1 415-685-4860"))
        // Viewport biases, never pins (geo.anchorLadder).
        #expect(result.values["geo"] == nil)
        #expect(result.values["viewport"] == .geo(latitude: 37.7854, longitude: -122.3993))
    }
}
