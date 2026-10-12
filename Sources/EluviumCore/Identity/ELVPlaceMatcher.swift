import Foundation

/// The heuristic identity tier (`entity.placeMatch`): where no
/// shared namespace exists (a Michelin restaurant vs a Swarm check-in),
/// score candidate pairs on name similarity plus geo distance and emit a
/// scored *suggestion* — never a link. Pure and deterministic, so the same
/// pair always scores the same.
public enum ELVPlaceMatcher {
    /// A place to match: a display name and, when known, a coordinate.
    public struct Place: Sendable, Equatable {
        public var name: String
        public var latitude: Double?
        public var longitude: Double?

        public init(name: String, latitude: Double? = nil, longitude: Double? = nil) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// A scored candidate match. `confidence` is in 0...1; the caller decides
    /// the confirm threshold (default is confirm-always).
    public struct Match: Sendable, Equatable {
        public var confidence: Double
        public var nameSimilarity: Double
        public var distanceMeters: Double?
    }

    /// Scores `a` against `b`. Returns `nil` when the pair is implausible
    /// (names share nothing AND they are far apart) — "skip beats wrong"
    /// applied at the scorer, so a hopeless pair never becomes a suggestion.
    public static func score(_ first: Place, _ second: Place) -> Match? {
        let nameSimilarity = similarity(first.name, second.name)
        let distance = distanceMeters(first, second)

        // Geo agreement, when both coordinates exist: 1.0 at 0 m decaying to
        // 0 by ~2 km (the trusted-anchor radius).
        let geoScore: Double? = if let distance {
            max(0, 1 - distance / 2000)
        } else {
            nil
        }

        let confidence: Double = if let geoScore {
            // Name and geo both count; geo is the stronger signal for places.
            nameSimilarity * 0.45 + geoScore * 0.55
        } else {
            // No coordinates: names alone, discounted (a name-only match is
            // inherently weaker and must clear a higher bar downstream).
            nameSimilarity * 0.7
        }

        // Reject the hopeless pair: unrelated names AND (no geo OR far apart).
        let farApart = distance.map { $0 > 2000 } ?? true
        if nameSimilarity < 0.34, farApart { return nil }

        return Match(confidence: min(1, confidence), nameSimilarity: nameSimilarity, distanceMeters: distance)
    }

    // MARK: - Name similarity

    /// Token-set Jaccard blended with normalized edit distance, over
    /// case/diacritic/punctuation-folded names. Robust to word order
    /// ("Benu" vs "Benu Restaurant") and to minor spelling drift.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalize(lhs)
        let right = normalize(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }

        let leftTokens = meaningfulTokens(left)
        let rightTokens = meaningfulTokens(right)
        let intersection = leftTokens.intersection(rightTokens).count
        let union = leftTokens.union(rightTokens).count
        let jaccard = union == 0 ? 0 : Double(intersection) / Double(union)
        // Containment: the smaller distinctive name fully inside the larger
        // ("Benu" inside "Benu Restaurant") is a strong signal that Jaccard
        // alone under-weights.
        let smaller = min(leftTokens.count, rightTokens.count)
        let containment = smaller == 0 ? 0 : Double(intersection) / Double(smaller)

        let edit = 1 - normalizedEditDistance(left, right)
        return max(jaccard, containment, edit * 0.9)
    }

    /// Distinctive name tokens: generic place-type words and articles are
    /// dropped, unless dropping them would leave nothing (a place literally
    /// named "The Restaurant" keeps its words).
    private static func meaningfulTokens(_ normalized: String) -> Set<String> {
        let all = normalized.split(separator: " ").map(String.init)
        let distinctive = all.filter { !Self.stopwords.contains($0) }
        return Set(distinctive.isEmpty ? all : distinctive)
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "le", "la", "les", "el", "il",
        "restaurant", "cafe", "bar", "grill", "kitchen", "bistro", "brasserie",
        "co", "company", "group", "inc", "llc", "and",
    ]

    // Fixed pattern compiled once: `normalize` runs per string per pairwise
    // comparison, and `range(of:options:.regularExpression)` compiles a
    // throwaway regex each call.
    // swiftlint:disable:next force_try
    private static let whitespaceRunRegex = try! NSRegularExpression(pattern: "\\s+")

    /// The longest name prefix compared. The edit distance costs the product
    /// of both lengths, and names come from pages, so an uncapped pair of
    /// megabyte "names" stalls the matcher; no real place name comes close.
    private static let maxNameLength = 256

    private static func normalize(_ string: String) -> String {
        let folded = String(string.prefix(maxNameLength)).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let collapsed = String(stripped)
        return whitespaceRunRegex.stringByReplacingMatches(in: collapsed, range: NSRange(collapsed.startIndex..., in: collapsed), withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedEditDistance(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 1 }
        var previous = Array(0 ... b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    // MARK: - Geo distance

    /// Haversine distance in meters, or `nil` when either coordinate is
    /// missing.
    static func distanceMeters(_ first: Place, _ second: Place) -> Double? {
        guard let lat1 = first.latitude, let lon1 = first.longitude,
              let lat2 = second.latitude, let lon2 = second.longitude else { return nil }
        return distanceMeters(fromLatitude: lat1, longitude: lon1, toLatitude: lat2, longitude: lon2)
    }

    /// Haversine distance in meters between two raw coordinates. Public so
    /// the geo trust policies (EluviumPlaces' anchor ladder, distance
    /// guards) share one implementation.
    public static func distanceMeters(fromLatitude lat1: Double, longitude lon1: Double, toLatitude lat2: Double, longitude lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
