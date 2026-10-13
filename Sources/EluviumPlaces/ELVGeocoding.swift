import EluviumCore
import Foundation

/// One geocoder result, reduced to what the address-anchor rung and the
/// locality backfill read.
public struct ELVGeocodedAddress: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// ISO country code when the backend reports one.
    public var isoCountryCode: String?
    /// The country's display name, the fallback when no code is reported.
    public var country: String?
    /// Name-like fields (name, street, locality, full address) the
    /// query-echo guard matches tokens against.
    public var echoFields: [String?]
    /// "City, Region" for a place subtitle ("Moose, WY").
    public var localitySubtitle: String?

    public init(latitude: Double, longitude: Double, isoCountryCode: String? = nil, country: String? = nil, echoFields: [String?] = [], localitySubtitle: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.isoCountryCode = isoCountryCode
        self.country = country
        self.echoFields = echoFields
        self.localitySubtitle = localitySubtitle
    }
}

/// The host's geocoder, for `place.mapKitLookup@2`'s address anchor and
/// locality backfill. Injected rather than built in, so a host routes every
/// call through its own pacing (geocoders rate-limit per app) and picks the
/// platform API it already uses. Without one, a coordinate-free link whose
/// only anchor would be its street address gets no lookup at all: no valid
/// anchor, no pin.
public protocol ELVGeocoding: Sendable {
    /// The best forward match for a free-form address, or nil for none.
    func forwardGeocode(_ address: String) async throws -> ELVGeocodedAddress?
    /// The best reverse match for a coordinate, or nil for none.
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> ELVGeocodedAddress?
}

/// The radii `place.mapKitLookup@2` trusts a match within, as pack values.
/// Clamped like `ELVAnchorLadder.Config`, so a pack can tune them but never
/// turn the guards off.
public struct ELVPlaceLookupPolicy: Sendable, Equatable {
    /// A match within this distance of the link's own pin (or of its
    /// viewport, for metadata only) is the same place. Loose: a big venue's
    /// POI centroid can sit kilometers from a pin dropped on its entrance.
    public var pinMeters: Double
    /// The tight radius around an address-geocoded anchor: the place IS at
    /// that address, so a farther match is a same-named place elsewhere in
    /// town.
    public var addressMeters: Double
    /// The search region's span around the anchor (a bias, never a filter).
    public var regionMeters: Double

    public init(pinMeters: Double = 50000, addressMeters: Double = 2000, regionMeters: Double = 20000) {
        self.pinMeters = Self.clamp(pinMeters, default: 50000, range: 1 ... 200_000)
        self.addressMeters = Self.clamp(addressMeters, default: 2000, range: 1 ... 5000)
        self.regionMeters = Self.clamp(regionMeters, default: 20000, range: 100 ... 200_000)
    }

    private static func clamp(_ value: Double, default fallback: Double, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Address-anchor heuristics shared by the lookup and its tests.
public enum ELVAddressAnchor {
    /// Whether a place label's tail reads like a street address (any digit,
    /// or three or more comma components) rather than a bare region
    /// ("Wyoming"): only a real address is worth geocoding into an anchor.
    public static func looksLikeStreetAddress(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .decimalDigits) != nil || text.count(where: { $0 == "," }) >= 2
    }

    /// Whether a forward-geocoded result plausibly IS the given address.
    /// Geocoders fuzzy-match street formats they can't parse to something
    /// near the device region (a Lima street address once came back in
    /// Fremont, CA): when the address tail names a country, the result must
    /// sit in that country; otherwise the result must echo an address token.
    public static func isPlausible(_ place: ELVGeocodedAddress, for address: String) -> Bool {
        if let addressCountry = ELVCountry.code(fromAddressTail: address) {
            return ELVCountry.code(for: place.isoCountryCode ?? place.country) == addressCountry
        }
        return ELVPlaceLookupGuards.echoes(query: address, fields: place.echoFields)
    }
}
