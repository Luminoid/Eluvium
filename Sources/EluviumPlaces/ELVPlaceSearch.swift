import EluviumCore
import Foundation
import MapKit
import Synchronization

/// One place candidate from a search backend.
public struct ELVGeocodedPlace: Sendable, Equatable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var address: String?
    /// The city-level component (the placemark's locality), separate from
    /// the full address line so packs can fill a `locality` field directly.
    public var locality: String?
    public var phone: String?
    /// The backend's point-of-interest category, verbatim (an
    /// `MKPointOfInterestCategory` raw value for the MapKit backend).
    public var category: String?
    /// The region above the locality (state, prefecture, or the country
    /// when there is none), for `localitySubtitle`.
    public var region: String?
    /// The county-level area (the placemark's `subAdministrativeArea`):
    /// `localitySubtitle`'s stand-in for a place outside any city (a lake,
    /// a trailhead), so it reads "Teton County, WY" rather than "WY".
    public var county: String?

    public init(
        name: String, latitude: Double, longitude: Double, address: String? = nil, locality: String? = nil,
        phone: String? = nil, category: String? = nil, region: String? = nil, county: String? = nil
    ) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.locality = locality
        self.phone = phone
        self.category = category
        self.region = region
        self.county = county
    }

    /// "City, Region" ("Moose, WY"), the county standing in for a missing
    /// city ("Teton County, WY"), or whichever half exists.
    public var localitySubtitle: String? {
        let city = [locality, county]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let area = region?.trimmingCharacters(in: .whitespaces)
        let parts = [city, area == city ? nil : area].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// A place search backend. `near` biases the search region; it must never be
/// treated as a filter by implementations — the guards do the filtering.
public protocol ELVPlaceSearching: Sendable {
    func search(_ query: String, near: ELVAnchorLadder.Point?, radiusMeters: Double) async throws -> [ELVGeocodedPlace]
}

/// A place lookup that outran its deadline (`place.mapKitLookup`).
/// `MKLocalSearch.start`-based backends cannot be cancelled reliably, so on
/// expiry the search is abandoned, not awaited; the enrichment layer's catch
/// maps this like any other lookup failure — never a silent nil.
public struct ELVPlaceLookupTimeout: Error, Sendable, Equatable {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }
}

/// The distance / echo guards a lookup result must pass
/// (`place.mapKitLookup`). Ported from TripDays' `PlaceGeocoder`.
public enum ELVPlaceLookupGuards {
    /// Whether any candidate field echoes any token of the query. Geocoders
    /// pattern-match aggressively on names they can't really resolve
    /// ("Shinjuku Gyoen National Garden 新宿御苑" once returned a Tateyama
    /// placemark, ~90 km off but inside the radius), so a result that
    /// repeats none of the query's words is a junk match. Tokens are Latin
    /// letter/digit runs and CJK runs, 2+ characters each, compared case-
    /// and diacritic-insensitively by containment in either direction (so
    /// "Kamakura" matches a "Kamakura-shi" locality). Permissive by design:
    /// a query with no usable tokens passes as unjudgeable, and a false
    /// pass just leaves the distance guard to decide.
    public static func echoes(query: String, fields: [String?]) -> Bool {
        let tokens = queryTokens(query)
        guard !tokens.isEmpty else { return true }
        let folded = fields.compactMap { field -> String? in
            guard let field, !field.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return fold(field)
        }
        guard !folded.isEmpty else { return false }
        return tokens.contains { token in
            folded.contains { $0.contains(token) || token.contains($0) }
        }
    }

    /// The first result that passes both guards: echoes the query, and sits
    /// within `maxMeters` of `anchor` (a match implausibly far from the
    /// anchor is discarded — same-named places exist everywhere).
    public static func firstTrusted(
        query: String,
        results: [ELVGeocodedPlace],
        anchor: ELVAnchorLadder.Point,
        maxMeters: Double
    ) -> ELVGeocodedPlace? {
        results.first { candidate in
            guard echoes(query: query, fields: [candidate.name, candidate.address]) else { return false }
            let distance = ELVPlaceMatcher.distanceMeters(
                fromLatitude: candidate.latitude, longitude: candidate.longitude,
                toLatitude: anchor.latitude, longitude: anchor.longitude
            )
            return distance <= maxMeters
        }
    }

    private static func queryTokens(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsCJK = false
        func flush() {
            if current.count >= 2 { tokens.append(fold(current)) }
            current = ""
        }
        for scalar in query.unicodeScalars {
            if isCJK(scalar) {
                if !currentIsCJK { flush() }
                currentIsCJK = true
                current.unicodeScalars.append(scalar)
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if currentIsCJK { flush() }
                currentIsCJK = false
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00 ... 0x9FFF).contains(scalar.value)
            || (0x3400 ... 0x4DBF).contains(scalar.value)
            || (0x3040 ... 0x30FF).contains(scalar.value)
            || (0xAC00 ... 0xD7AF).contains(scalar.value)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// The MapKit backend: MKLocalSearch with the anchor as a region bias.
public struct ELVMapKitPlaceSearch: ELVPlaceSearching {
    public init() {}

    public func search(_ query: String, near: ELVAnchorLadder.Point?, radiusMeters: Double) async throws -> [ELVGeocodedPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude),
                latitudinalMeters: radiusMeters * 2,
                longitudinalMeters: radiusMeters * 2
            )
        }
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            // MapKit reports an empty answer as an error; the resolver must
            // see "no results", not "MapKit failed".
            return []
        }
        return response.mapItems.map { item in
            let coordinate = item.placemark.coordinate
            return ELVGeocodedPlace(
                name: item.name ?? query,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                address: item.placemark.title,
                locality: item.placemark.locality,
                phone: item.phoneNumber,
                category: item.pointOfInterestCategory?.rawValue,
                region: item.placemark.administrativeArea ?? item.placemark.country,
                county: item.placemark.subAdministrativeArea
            )
        }
    }
}

/// The anchored place resolver: ladder + search + guards in one call. Skip
/// beats wrong throughout — an unanchored lookup may fill METADATA (name,
/// address, phone, category) but never lands a coordinate.
public struct ELVPlaceResolver: Sendable {
    public struct Resolution: Sendable, Equatable {
        /// The trusted pin, nil when nothing earned one.
        public var point: ELVAnchorLadder.Point?
        public var origin: ELVAnchorLadder.Origin?
        /// The matched place's metadata, nil when no search match passed.
        public var place: ELVGeocodedPlace?
        /// A reverse-geocoded "City, Region" for the anchor, filled only by
        /// `lookup` when nothing matched and the link carried no locality.
        public var reverseLocality: String?
    }

    private let searcher: any ELVPlaceSearching
    private let config: ELVAnchorLadder.Config
    /// Per-search deadline (seconds), clamped to 0.1 ... 60. MapKit is the
    /// only async platform lookup with no budget of its own — `MKLocalSearch`
    /// can hang — so the race in `search` unblocks the caller at this bound.
    private let timeoutSeconds: Double

    public init(
        searcher: any ELVPlaceSearching = ELVMapKitPlaceSearch(),
        config: ELVAnchorLadder.Config = ELVAnchorLadder.Config(),
        timeoutSeconds: Double = 10
    ) {
        self.searcher = searcher
        self.config = config
        self.timeoutSeconds = timeoutSeconds.isNaN ? 10 : min(max(timeoutSeconds, 0.1), 60)
    }

    /// Resolves `name` against the available anchors. A URL pin anchors the
    /// search tightly (`nearMeters`) and stays the pin even when the search
    /// misses; a viewport biases a metadata-only lookup (`farMeters`)
    /// whose coordinate is never adopted; no anchor at all skips the
    /// search entirely rather than gamble on a same-named place anywhere.
    ///
    /// A backend failure or deadline expiry throws — "MapKit failed" must
    /// stay distinguishable from "no results" — while nil remains the
    /// genuinely-nothing answer: no anchor at all, or no trusted match on
    /// the metadata-only path.
    public func resolve(name: String, urlPin: ELVAnchorLadder.Point?, viewport: ELVAnchorLadder.Point? = nil) async throws -> Resolution? {
        if let urlPin {
            let results = try await search(name, near: urlPin, radiusMeters: config.nearMeters)
            let match = ELVPlaceLookupGuards.firstTrusted(query: name, results: results, anchor: urlPin, maxMeters: config.nearMeters)
            // The match's own coordinate is the exact one; the pin validated it.
            let point = match.map { ELVAnchorLadder.Point(latitude: $0.latitude, longitude: $0.longitude) } ?? urlPin
            return Resolution(point: point, origin: .urlPin, place: match)
        }
        if let viewport {
            let results = try await search(name, near: viewport, radiusMeters: config.farMeters)
            let match = ELVPlaceLookupGuards.firstTrusted(query: name, results: results, anchor: viewport, maxMeters: config.farMeters)
            return match.map { Resolution(point: nil, origin: nil, place: $0) }
        }
        return nil
    }

    /// The `place.mapKitLookup@2` resolution: one anchored search whose
    /// match is trusted by the anchor it was found against.
    ///
    /// - A URL pin anchors the search and the match must sit within
    ///   `policy.pinMeters` of it.
    /// - With no pin and a street-address `locality` (the coordinate-free
    ///   `?q=name, address` share), the address is forward-geocoded through
    ///   `geocoder` into an anchor (`ELVAddressAnchor.isPlausible` vetoes a
    ///   junk geocode). The match must sit within `policy.addressMeters` of
    ///   it, and on a miss the anchor itself is the pin. No valid anchor
    ///   means no search: an unanchored search gambles on a same-named
    ///   place anywhere, and a known address that won't geocode is exactly
    ///   that gamble.
    /// - A viewport only biases the search: its match fills metadata within
    ///   `policy.pinMeters` but never the pin.
    /// - With no anchor at all the search runs unbiased, for metadata only.
    ///
    /// On a miss with any anchor, `geocoder` reverse-geocodes the anchor
    /// for the locality the link lacked.
    public func lookup(
        name: String,
        locality: String?,
        urlPin: ELVAnchorLadder.Point?,
        viewport: ELVAnchorLadder.Point?,
        policy: ELVPlaceLookupPolicy,
        geocoder: (any ELVGeocoding)?
    ) async throws -> Resolution? {
        let trimmedLocality = locality?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = [name, trimmedLocality].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        guard !query.isEmpty else { return nil }

        var addressAnchor: ELVAnchorLadder.Point?
        if urlPin == nil, let address = trimmedLocality, ELVAddressAnchor.looksLikeStreetAddress(address) {
            guard let geocoder, let place = try await geocoder.forwardGeocode(address),
                  ELVAddressAnchor.isPlausible(place, for: address)
            else { return nil }
            addressAnchor = ELVAnchorLadder.Point(latitude: place.latitude, longitude: place.longitude)
        }
        let trusted = urlPin ?? addressAnchor
        let anchor = trusted ?? viewport
        let radius = addressAnchor != nil ? policy.addressMeters : policy.pinMeters
        let results = try await search(query, near: anchor, radiusMeters: policy.regionMeters / 2)

        let match = results.first.flatMap { first -> ELVGeocodedPlace? in
            guard let anchor else { return first }
            let distance = ELVPlaceMatcher.distanceMeters(
                fromLatitude: first.latitude, longitude: first.longitude,
                toLatitude: anchor.latitude, longitude: anchor.longitude
            )
            return distance <= radius ? first : nil
        }
        if let match {
            let origin: ELVAnchorLadder.Origin? = urlPin != nil ? .urlPin : (addressAnchor != nil ? .geocodeAnchored : nil)
            let point = trusted.map { _ in ELVAnchorLadder.Point(latitude: match.latitude, longitude: match.longitude) }
            return Resolution(point: point, origin: origin, place: match)
        }
        var resolution = Resolution(point: addressAnchor, origin: addressAnchor != nil ? .geocodeAnchored : nil, place: nil)
        if trimmedLocality?.isEmpty ?? true, let anchor, let geocoder,
           let reversed = try await geocoder.reverseGeocode(latitude: anchor.latitude, longitude: anchor.longitude),
           let subtitle = reversed.localitySubtitle {
            resolution.reverseLocality = subtitle
        }
        return resolution.point == nil && resolution.reverseLocality == nil ? nil : resolution
    }

    // MARK: - Deadline race

    /// One backend search raced against `timeoutSeconds`, first result
    /// winning. The losing search is abandoned (`abandonableSearch`) rather
    /// than awaited, so the group — and the caller — unblocks the moment
    /// either child finishes.
    private func search(_ query: String, near anchor: ELVAnchorLadder.Point?, radiusMeters: Double) async throws -> [ELVGeocodedPlace] {
        try await withThrowingTaskGroup(of: [ELVGeocodedPlace].self) { group in
            group.addTask {
                try await Self.abandonableSearch(searcher, query: query, near: anchor, radiusMeters: radiusMeters)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ELVPlaceLookupTimeout(seconds: timeoutSeconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ELVPlaceLookupTimeout(seconds: timeoutSeconds) }
            return first
        }
    }

    private typealias SearchContinuation = CheckedContinuation<[ELVGeocodedPlace], any Error>

    /// The exactly-once resume state for `abandonableSearch`.
    private enum SearchState {
        case pending
        case running(SearchContinuation)
        case finished

        /// The continuation if still resumable, transitioning to `finished`.
        mutating func take() -> SearchContinuation? {
            guard case let .running(continuation) = self else {
                self = .finished
                return nil
            }
            self = .finished
            return continuation
        }
    }

    /// Reference box around the exactly-once state: `Mutex` is `~Copyable`,
    /// so closures capture the *local* by reference, which region analysis
    /// refuses to send into the unstructured task — a `Sendable` class box
    /// gives every closure the same shareable reference instead.
    private final class SearchStateBox: Sendable {
        let state = Mutex<SearchState>(.pending)
    }

    /// Runs one backend search behind an exactly-once continuation.
    /// Cancellation — the deadline racer winning — resumes early with
    /// `CancellationError`; the backend's own completion resumes only when
    /// it gets there first, otherwise it lands in the void instead of
    /// double-resuming. The inner task is deliberately unstructured (and
    /// unstored: it resumes the continuation, or finds it spent, and ends);
    /// a structured child would force the deadline to wait the backend out.
    private static func abandonableSearch(
        _ searcher: any ELVPlaceSearching,
        query: String,
        near anchor: ELVAnchorLadder.Point?,
        radiusMeters: Double
    ) async throws -> [ELVGeocodedPlace] {
        let box = SearchStateBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: SearchContinuation) in
                let proceed = box.state.withLock { current -> Bool in
                    guard case .pending = current else { return false }
                    current = .running(continuation)
                    return true
                }
                guard proceed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                Task {
                    do {
                        let results = try await searcher.search(query, near: anchor, radiusMeters: radiusMeters)
                        box.state.withLock { $0.take() }?.resume(returning: results)
                    } catch {
                        box.state.withLock { $0.take() }?.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.state.withLock { $0.take() }?.resume(throwing: CancellationError())
        }
    }
}
