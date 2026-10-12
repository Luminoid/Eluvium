import EluviumCore
import Foundation

/// The Identity tab's `geo.anchorLadder@1` showcase: canned
/// coordinate inputs run through the native-op registry — the exact call
/// surface a pack candidate uses — fully offline. `place.mapKitLookup@1`
/// stays registered as a capability, but the demo never invokes it: the
/// ladder is the pure trust decision over coordinates already extracted.
enum AnchorLadderDemo {
    struct Case: Equatable {
        let title: String
        let detail: String
        /// The op's named inputs, as a pack would pass them.
        let input: [String: String]
    }

    struct Anchor: Equatable {
        let latitude: Double
        let longitude: Double
        let origin: String
    }

    /// One case per ladder rule worth showing: absolute trust, and the
    /// refusal that keeps a wrong coordinate off the map.
    static let cases: [Case] = [
        Case(
            title: "URL pin beats geocoded anchor",
            detail: "A dropped-pin coordinate in the URL is the place. The far-off geocode (and the viewport) never get a vote.",
            input: [
                "urlLat": "37.7854", "urlLng": "-122.3993",
                "geoLat": "48.2082", "geoLng": "16.3738",
                "viewportLat": "37.7749", "viewportLng": "-122.4194",
            ]
        ),
        Case(
            title: "Viewport only never pins",
            detail: "The map center biases a search but is not evidence of the place, so the ladder grants nothing.",
            input: ["viewportLat": "37.7749", "viewportLng": "-122.4194"]
        ),
    ]

    /// Runs one case's inputs through the registered op. Nil when the ladder
    /// grants no trust, which the UI renders as "skip beats wrong".
    static func resolve(_ input: [String: String]) -> Anchor? {
        guard let op = ELVNativeOps.lookup("geo.anchorLadder@1"),
              let outputs = op(input, ELVExtractionContext()),
              case let .geo(latitude, longitude)? = outputs["geo"],
              case let .text(origin)? = outputs["origin"] else { return nil }
        return Anchor(latitude: latitude, longitude: longitude, origin: origin)
    }

    /// The one-line outcome the demo row shows.
    static func verdict(for demoCase: Case) -> String {
        guard let anchor = resolve(demoCase.input) else { return "No pin: skip beats wrong" }
        return "Pinned \(coordinate(anchor.latitude)), \(coordinate(anchor.longitude)) via \(anchor.origin)"
    }

    private static func coordinate(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
