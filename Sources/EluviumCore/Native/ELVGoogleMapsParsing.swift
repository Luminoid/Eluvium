import Foundation

/// Google Maps URL coordinate + label extraction (`maps.pinCoordinate`,
/// `maps.splitPlaceLabel`). The invariant this whole file exists to protect:
/// the pin is the PATH's data blob `!3d!4d` pair (or a coordinate-shaped
/// `?q=`, a dropped-pin share IS its coordinate); the `/@lat,lng` segment and
/// the map-center params are only the VIEWPORT the link was copied at,
/// identical for two places copied from the same view and kilometers off the
/// place. Both extractions are path-scoped so a tracking param echoing a
/// coordinate can never inject one.
enum ELVGoogleMapsURL {
    /// The place's own pin: the `/data=` blob's LAST `!3d<lat>!4d<lng>` pair
    /// (earlier pairs can belong to intermediate markers), or a
    /// coordinate-shaped `q` / `query` value.
    static func pinCoordinate(in url: String) -> (latitude: Double, longitude: Double)? {
        dataCoordinate(in: url) ?? coordinatePair(inQuery: url, names: ["q", "query"])
    }

    /// The viewport the link was copied at: the PATH's `/@lat,lng,zoom`
    /// segment, or the map-center params (`ll` / `sll` / `center`). A search
    /// bias, never a pin.
    static func viewportCoordinate(in url: String) -> (latitude: Double, longitude: Double)? {
        atCoordinate(in: url) ?? coordinatePair(inQuery: url, names: ["ll", "sll", "center"])
    }

    /// Place label from a `/maps/place/<segment>` path or a non-coordinate
    /// `q` / `query` value, plus-decoded.
    static func placeLabel(in url: String) -> String? {
        let path = pathPortion(of: url)
        let segments = path.split(separator: "/").map(String.init)
        if let placeIndex = segments.firstIndex(of: "place"), placeIndex + 1 < segments.count {
            return prettifyPlus(segments[placeIndex + 1])
        }
        for value in queryValues(in: url, names: ["q", "query"]) where commaPair(value) == nil {
            let label = prettifyPlus(value)
            if !label.isEmpty { return label }
        }
        return nil
    }

    /// Splits a Maps place label into its name and locality tail. Google
    /// often uses the full formatted address as the place segment ("Jenny
    /// Lake, Wyoming 83424, USA"), where only the leading component is the
    /// spot's name. Big-endian share labels are folded first.
    static func splitPlaceLabel(_ rawLabel: String) -> (name: String, locality: String?) {
        let label = littleEndianLabel(rawLabel)
        guard let comma = label.firstIndex(of: ",") else { return (label, nil) }
        let name = String(label[..<comma]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return (label, nil) }
        let locality = String(label[label.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        return (name, locality.isEmpty ? nil : locality)
    }

    /// Restores little-endian (name-first) order for a share label Google
    /// composed in a big-endian region's address order: a JP / CN / KR share
    /// serves "United States, California, Los Angeles, S Western Ave, COIN DE
    /// RUE bakery and cafe" — country first, the place's own name LAST. Gated
    /// on the leading component naming a country while the trailing one does
    /// NOT, so an ordinary little-endian address that merely starts with a
    /// country-shaped name ("Jordan, 123 Main St, Springfield, USA") is left
    /// alone (`place.littleEndianLabel`).
    static func littleEndianLabel(_ label: String) -> String {
        let parts = label.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count > 1,
              ELVCountryNames.namesCountry(parts.first),
              !ELVCountryNames.namesCountry(parts.last)
        else { return label }
        return parts.reversed().joined(separator: ", ")
    }

    // MARK: - Path-scoped extraction

    private static func pathPortion(of url: String) -> String {
        let pathEnd = url.firstIndex { $0 == "?" || $0 == "#" } ?? url.endIndex
        return String(url[..<pathEnd])
    }

    // Fixed pattern compiled once (the static-pattern rule): the data-blob
    // pair scan runs per Maps URL.
    // swiftlint:disable:next force_try
    private static let dataPairRegex = try! NSRegularExpression(pattern: "!3d(-?\\d+(?:\\.\\d+)?)!4d(-?\\d+(?:\\.\\d+)?)")

    private static func dataCoordinate(in url: String) -> (latitude: Double, longitude: Double)? {
        let path = pathPortion(of: url)
        guard let dataStart = path.range(of: "/data=") else { return nil }
        let blob = String(path[dataStart.upperBound...])
        guard let match = dataPairRegex.matches(in: blob, range: NSRange(blob.startIndex..., in: blob)).last,
              let latRange = Range(match.range(at: 1), in: blob),
              let lngRange = Range(match.range(at: 2), in: blob)
        else { return nil }
        return commaPair("\(blob[latRange]),\(blob[lngRange])")
    }

    private static func atCoordinate(in url: String) -> (latitude: Double, longitude: Double)? {
        let path = pathPortion(of: url)
        guard let range = path.range(of: "/@") else { return nil }
        let chunk = path[range.upperBound...].prefix { $0 != "/" }
        return commaPair(String(chunk))
    }

    private static func coordinatePair(inQuery url: String, names: [String]) -> (latitude: Double, longitude: Double)? {
        for value in queryValues(in: url, names: names) {
            if let pair = commaPair(value) { return pair }
        }
        return nil
    }

    private static func queryValues(in url: String, names: [String]) -> [String] {
        guard let components = URLComponents(string: url), let items = components.queryItems else { return [] }
        return names.flatMap { name in items.filter { $0.name == name }.compactMap(\.value) }
    }

    /// Parses "lat,lng" (ignoring trailing comma-separated extras like zoom).
    static func commaPair(_ string: String) -> (latitude: Double, longitude: Double)? {
        let parts = string.split(separator: ",")
        guard parts.count >= 2,
              let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lng = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              abs(lat) <= 90, abs(lng) <= 180 else {
            return nil
        }
        return (lat, lng)
    }

    /// Decodes percent-escapes and turns "+" into spaces (Google place segments).
    private static func prettifyPlus(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return (spaced.removingPercentEncoding ?? spaced).trimmingCharacters(in: .whitespaces)
    }
}

/// Shape-not-position classification of a Maps place page's `og:title` /
/// `og:description` " · " segments (`maps.classifyMetaSegments`). The
/// serving VARIES by share path: "Name · address" with "★★★★☆ · Catholic
/// church" on one variant, swapped on another, a bare "Name · Lima" on a
/// third — so every segment routes by shape: numeric rating / glyph star row
/// / keyword-mapped comma-less type (checked BEFORE the address shape so
/// "4-star hotel" doesn't misroute) / digits-or-commas address / bare
/// locality. The "Find local businesses…" boilerplate description is dropped
/// whole: its commas would read as an address, and a real place meta never
/// names the product (nor does a bare "Google Maps" title name a place).
enum ELVMapsMetaClassifier {
    struct Meta: Equatable {
        var name: String?
        var address: String?
        var locality: String?
        var typeText: String?
        /// The public star rating a "4.6★(3,067)" segment carries, on the
        /// 0–5 scale Maps renders.
        var rating: Double?
    }

    static func classify(title: String?, description: String?) -> Meta {
        var meta = Meta()
        classify(title, isTitle: true, into: &meta)
        if let description, description.range(of: "google maps", options: .caseInsensitive) == nil {
            classify(description, isTitle: false, into: &meta)
        }
        return meta
    }

    /// The coarse category a type segment implies ("Catholic church" →
    /// "attraction"), or nil for unmapped text. Word-bounded
    /// (`ELVTokenizedText`) so "parking lot" never reads as a park nor
    /// "dinner" as an inn, with one tokenization pass instead of a regex
    /// compile per keyword. Categories are kind tokens: a hiking type
    /// maps to `trail`, the kind every trail source records.
    static func category(forTypeText text: String) -> String? {
        let tokenized = ELVTokenizedText(text)
        func containsAny(_ keywords: [String]) -> Bool {
            keywords.contains { tokenized.contains(keyword: $0) }
        }
        if containsAny(["trail", "hiking"]) { return "trail" }
        if containsAny(["hotel", "motel", "lodge", "lodging", "hostel", "resort", "campground", "bed and breakfast", "bed & breakfast", "inn"]) { return "lodging" }
        if containsAny(["restaurant", "cafe", "coffee", "bakery", "diner", "brewery", "winery", "bar", "food", "pizzeria", "eatery", "bistro", "grill"]) { return "food" }
        if containsAny([
            "park", "museum", "attraction", "scenic", "viewpoint", "vista", "overlook", "zoo", "aquarium",
            "theater", "beach", "garden", "landmark", "monument", "church", "cathedral", "basilica", "chapel",
            "temple", "shrine", "mosque", "synagogue", "monastery", "pagoda", "palace", "castle", "plaza", "square",
        ]) { return "attraction" }
        return nil
    }

    private static func classify(_ text: String?, isTitle: Bool, into meta: inout Meta) {
        guard let text else { return }
        var segments = text.components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return }
        if isTitle {
            // A page with no place behind it carries the product's own
            // title ("Google Maps"), which names nothing.
            let first = segments.removeFirst()
            if meta.name == nil, first.caseInsensitiveCompare("Google Maps") != .orderedSame { meta.name = first }
        }
        let hasRatingContext = segments.contains { isRatingSegment($0) || isStarGlyphSegment($0) }
        for segment in segments {
            route(segment, hasRatingContext: hasRatingContext, into: &meta)
        }
    }

    private static func route(_ segment: String, hasRatingContext: Bool, into meta: inout Meta) {
        if isRatingSegment(segment) {
            if meta.rating == nil { meta.rating = ratingValue(segment) }
        } else if isStarGlyphSegment(segment) {
            return
        } else if !segment.contains(","), category(forTypeText: segment) != nil {
            if meta.typeText == nil { meta.typeText = segment }
        } else if segment.rangeOfCharacter(from: .decimalDigits) != nil || segment.contains(",") {
            if meta.address == nil { meta.address = segment }
        } else if hasRatingContext {
            if meta.typeText == nil { meta.typeText = segment }
        } else if meta.locality == nil {
            meta.locality = segment
        }
    }

    // Fixed pattern compiled once: the old `range(of:)` form recompiled it
    // per meta segment.
    // swiftlint:disable:next force_try
    private static let ratingSegmentRegex = try! NSRegularExpression(pattern: "^\\d(?:[.,]\\d)?\\s*★\\s*\\([\\d,.\\s]+\\)$")

    /// True for a numeric public-rating segment: "4.6★(3,067)", "5★(12)".
    private static func isRatingSegment(_ segment: String) -> Bool {
        ratingSegmentRegex.firstMatch(in: segment, range: NSRange(segment.startIndex..., in: segment)) != nil
    }

    /// The number in front of the star of a rating segment ("4.6★(3,067)"
    /// → 4.6, "4,6★(12)" → 4.6), held to the 0–5 scale Maps renders.
    private static func ratingValue(_ segment: String) -> Double? {
        let number = segment.prefix { $0 != "★" }.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(number), value > 0, value <= 5 else { return nil }
        return value
    }

    /// True for a glyph-only star row ("★★★★★", "★★★★☆").
    private static func isStarGlyphSegment(_ segment: String) -> Bool {
        !segment.isEmpty && segment.allSatisfy { $0 == "★" || $0 == "☆" }
    }
}
