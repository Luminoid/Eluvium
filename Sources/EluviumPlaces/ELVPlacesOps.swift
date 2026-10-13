import EluviumCore
import Foundation

/// Registers this module's native ops into the shared registry. An
/// app that links EluviumPlaces calls `ELVPlacesOps.register()` once at
/// startup; a binary that doesn't skips every source requiring
/// `native:place.mapKitLookup` or `native:geo.anchorLadder` — capability
/// gating, not half-working.
public enum ELVPlacesOps {
    /// `searcher` is injectable for tests; production uses MapKit.
    /// `geocoder` serves `place.mapKitLookup@2`'s address anchor and
    /// locality backfill; without one that rung never anchors (no valid
    /// anchor, no pin).
    public static func register(searcher: any ELVPlaceSearching = ELVMapKitPlaceSearch(), geocoder: (any ELVGeocoding)? = nil) {
        registerAnchorLadder()
        registerMapKitLookup(searcher: searcher)
        registerMapKitLookupV2(searcher: searcher, geocoder: geocoder)
    }

    /// `geo.anchorLadder@1`: the pure trust decision over coordinates the
    /// pack already extracted (`maps.pinCoordinate` outputs, a geocode
    /// step's result). Sync — no platform lookup involved. The radii ride in
    /// as pack values; `ELVAnchorLadder.Config` clamps them so the trust
    /// ladder's tiers stay meaningful no matter what a pack claims. Public
    /// on its own for hosts that want the ladder without a MapKit lookup
    /// (a binary that never resolves places should not advertise
    /// `place.mapKitLookup` to the capability gate).
    public static func registerAnchorLadder() {
        ELVNativeOps.register("geo.anchorLadder", version: 1) { input, _ in
            let config = ELVAnchorLadder.Config(
                nearMeters: input["nearMeters"].flatMap(Double.init) ?? 2000,
                farMeters: input["farMeters"].flatMap(Double.init) ?? 50000
            )
            let anchor = ELVAnchorLadder.resolve(
                urlPin: point(input, "urlLat", "urlLng"),
                geocoded: point(input, "geoLat", "geoLng"),
                viewport: point(input, "viewportLat", "viewportLng"),
                config: config
            )
            guard let anchor else { return nil }
            return [
                "geo": .geo(latitude: anchor.point.latitude, longitude: anchor.point.longitude),
                "origin": .text(anchor.origin.rawValue),
            ]
        }
    }

    /// `place.mapKitLookup@1`: the anchored MKLocalSearch with distance /
    /// echo guards. Async — served through `ELVNativeOps.lookupAsync` for
    /// enrichment stages; never runs on the sync extraction path. A backend
    /// failure or deadline expiry throws out of the op — the enrichment
    /// layer's catch maps it — so "MapKit failed" stays distinguishable
    /// from the genuinely-no-results nil. One record's fields (address,
    /// phone, category, geo) read this op with the identical resolved
    /// input; the extractor's per-walk op memo runs the search once for all
    /// of them (TripDays runs ONE search per link).
    private static func registerMapKitLookup(searcher: any ELVPlaceSearching) {
        let resolver = ELVPlaceResolver(searcher: searcher)
        ELVNativeOps.registerAsync("place.mapKitLookup", version: 1) { input, _ in
            guard let name = input["name"], !name.isEmpty else { return nil }
            let resolution = try await resolver.resolve(
                name: name,
                urlPin: point(input, "urlLat", "urlLng"),
                viewport: point(input, "viewportLat", "viewportLng")
            )
            var outputs: [String: ELVValue] = [:]
            if let resolution {
                if let point = resolution.point {
                    outputs["geo"] = .geo(latitude: point.latitude, longitude: point.longitude)
                }
                if let origin = resolution.origin { outputs["origin"] = .text(origin.rawValue) }
                if let place = resolution.place {
                    outputs["name"] = .text(place.name)
                    if let address = place.address { outputs["address"] = .text(address) }
                    if let locality = place.locality { outputs["locality"] = .text(locality) }
                    if let phone = place.phone { outputs["phone"] = .text(phone) }
                    if let category = place.category { outputs["category"] = .text(category) }
                }
            }
            return outputs.isEmpty ? nil : outputs
        }
    }

    /// `place.mapKitLookup@2`: `ELVPlaceResolver.lookup`, the address-
    /// anchored lookup. Inputs: `name`, `locality` (a URL-borne locality
    /// tail, the address the anchor geocodes), the `urlLat`/`urlLng` pin and
    /// `viewportLat`/`viewportLng` hint, and the `pinMeters` /
    /// `addressMeters` / `regionMeters` radii (`ELVPlaceLookupPolicy`
    /// clamps them). Outputs `geo` + `origin` only when a trusted anchor
    /// vouched for the coordinate, plus the match's `name`, `address`,
    /// `locality` ("City, Region"; the reverse-geocoded anchor's on a
    /// miss), `phone`, and raw `category`.
    private static func registerMapKitLookupV2(searcher: any ELVPlaceSearching, geocoder: (any ELVGeocoding)?) {
        let resolver = ELVPlaceResolver(searcher: searcher)
        ELVNativeOps.registerAsync("place.mapKitLookup", version: 2) { input, _ in
            guard let name = input["name"], !name.isEmpty else { return nil }
            let policy = ELVPlaceLookupPolicy(
                pinMeters: input["pinMeters"].flatMap(Double.init) ?? 50000,
                addressMeters: input["addressMeters"].flatMap(Double.init) ?? 2000,
                regionMeters: input["regionMeters"].flatMap(Double.init) ?? 20000
            )
            guard let resolution = try await resolver.lookup(
                name: name,
                locality: input["locality"],
                urlPin: point(input, "urlLat", "urlLng"),
                viewport: point(input, "viewportLat", "viewportLng"),
                policy: policy,
                geocoder: geocoder
            ) else { return nil }
            var outputs: [String: ELVValue] = [:]
            if let point = resolution.point {
                outputs["geo"] = .geo(latitude: point.latitude, longitude: point.longitude)
            }
            if let origin = resolution.origin { outputs["origin"] = .text(origin.rawValue) }
            if let place = resolution.place {
                outputs["name"] = .text(place.name)
                if let address = place.address { outputs["address"] = .text(address) }
                if let locality = place.localitySubtitle { outputs["locality"] = .text(locality) }
                if let phone = place.phone { outputs["phone"] = .text(phone) }
                if let category = place.category { outputs["category"] = .text(category) }
            } else if let locality = resolution.reverseLocality {
                outputs["locality"] = .text(locality)
            }
            return outputs.isEmpty ? nil : outputs
        }
    }

    /// A coordinate pair from pack-controlled strings, held to the same
    /// rules as `ELVCoercionEngine`'s geo coercion: latitude within ±90,
    /// longitude within ±180, and never exactly (0, 0) — null island is a
    /// parser artifact, not a place. Anything else must not reach the
    /// haversine math or MapKit.
    private static func point(_ input: [String: String], _ latKey: String, _ lngKey: String) -> ELVAnchorLadder.Point? {
        guard let lat = input[latKey].flatMap(Double.init), let lng = input[lngKey].flatMap(Double.init),
              abs(lat) <= 90, abs(lng) <= 180, lat != 0 || lng != 0 else { return nil }
        return ELVAnchorLadder.Point(latitude: lat, longitude: lng)
    }
}
