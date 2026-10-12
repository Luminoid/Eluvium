import EluviumCore
import Foundation

/// The trusted-anchor policy (`geo.anchorLadder`): decides which
/// coordinate, if any, may pin a place. The mechanism lives here in the
/// framework; the policy knobs (radii, what counts as anchored) are config
/// so an app's tuning is a pack value, not framework law.
///
/// The ladder, hardest-won rule first:
/// 1. A URL pin (the `!3d!4d` pair, a dropped-pin `?q=`) IS the place —
///    absolute trust.
/// 2. A forward-geocoded coordinate is trusted only when an independent
///    anchor validates it: within `nearMeters` (2 km, the address-anchored
///    radius — unanchored, a same-named church once matched 3.5 km off) it
///    is anchored; within `farMeters` (50 km, the cross-POI radius) it is
///    merely plausible.
/// 3. The viewport BIASES a search but never pins, and a geocode with no
///    anchor at all never lands: skip beats wrong (a bare trail name once
///    geocoded "confidently" to Austria).
public enum ELVAnchorLadder {
    public struct Point: Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public struct Config: Sendable, Equatable {
        /// Trust radius for an anchored geocode (address-validated).
        /// Clamped to 1 ... 5000 m and never above `farMeters`.
        public var nearMeters: Double
        /// Plausibility radius for a viewport-validated geocode.
        /// Clamped to 1 ... 200_000 m.
        public var farMeters: Double

        /// The radii are pack-controlled numerics (`geo.anchorLadder` passes
        /// pack values straight through), so they are clamped like every
        /// other pack numeric: an absurd radius dissolves the ladder above
        /// (rule 2 — a 1e9 m "near" would anchor every geocode on Earth),
        /// and `near` never exceeds `far`, keeping the anchored tier the
        /// tight one. A NaN falls back to the default.
        public init(nearMeters: Double = 2000, farMeters: Double = 50000) {
            let far = min(max(farMeters.isNaN ? 50000 : farMeters, 1), 200_000)
            self.farMeters = far
            self.nearMeters = min(min(max(nearMeters.isNaN ? 2000 : nearMeters, 1), 5000), far)
        }
    }

    public enum Origin: String, Sendable {
        case urlPin
        case geocodeAnchored
        case geocodePlausible
    }

    public struct Anchor: Sendable, Equatable {
        public var point: Point
        public var origin: Origin

        public init(point: Point, origin: Origin) {
            self.point = point
            self.origin = origin
        }
    }

    /// Resolves the ladder. `geocoded` is a forward-geocode result needing
    /// validation; `viewport` is the only validator (the map center the
    /// link was copied at). Nil when nothing earns trust.
    public static func resolve(
        urlPin: Point?,
        geocoded: Point? = nil,
        viewport: Point? = nil,
        config: Config = Config()
    ) -> Anchor? {
        if let urlPin {
            return Anchor(point: urlPin, origin: .urlPin)
        }
        guard let geocoded else { return nil }
        // An unvalidated geocode never pins; the viewport is the validator.
        guard let viewport else { return nil }
        let distance = ELVPlaceMatcher.distanceMeters(
            fromLatitude: geocoded.latitude, longitude: geocoded.longitude,
            toLatitude: viewport.latitude, longitude: viewport.longitude
        )
        if distance <= config.nearMeters {
            return Anchor(point: geocoded, origin: .geocodeAnchored)
        }
        if distance <= config.farMeters {
            return Anchor(point: geocoded, origin: .geocodePlausible)
        }
        return nil
    }
}
