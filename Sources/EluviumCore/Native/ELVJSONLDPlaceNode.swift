import Foundation

/// Picks the most relevant place node out of a page's JSON-LD
/// (`jsonld.bestPlaceNode`) and normalizes its fields: a physical place
/// (food / lodging / attraction) beats an event, then a product / tour. A
/// node whose type maps to no category but that carries coordinates still
/// qualifies, last — AllTrails types its trails "LocalBusiness" (unmapped),
/// and dropping the node lost the trail's exact geo and name, leaving the
/// pin to a state-level forward geocode that once landed a Portola Redwoods
/// trail on a same-named Folsom street.
enum ELVJSONLDPlaceNode {
    struct Node: Equatable {
        var raw: ELVRawJSON
        var category: String?
    }

    static func best(in nodes: [ELVRawJSON]) -> Node? {
        let ranked = nodes.compactMap { node -> (node: ELVRawJSON, category: String?, priority: Int)? in
            if let category = category(forTypes: types(of: node)) {
                let priority = switch category {
                case "food", "lodging", "attraction": 0
                case "event": 1
                default: 2
                }
                return (node, category, priority)
            }
            if geo(from: node) != nil { return (node, nil, 3) }
            return nil
        }
        guard let best = ranked.min(by: { $0.priority < $1.priority }) else { return nil }
        return Node(raw: best.node, category: best.category)
    }

    // MARK: - Type mapping

    static func types(of node: ELVRawJSON) -> [String] {
        if let single = node["@type"]?.stringValue { return [single] }
        if let array = node["@type"]?.arrayValue { return array.compactMap(\.stringValue) }
        return []
    }

    static func category(forTypes types: [String]) -> String? {
        for raw in types {
            switch raw.lowercased() {
            case "restaurant", "foodestablishment", "cafeorcoffeeshop", "barorpub", "bakery", "fastfoodrestaurant", "winery", "brewery":
                return "food"
            case "hotel", "lodgingbusiness", "resort", "motel", "bedandbreakfast", "hostel", "campground", "apartment", "vacationrental":
                return "lodging"
            case "touristattraction", "museum", "park", "amusementpark", "zoo", "aquarium", "landmarksorhistoricalbuildings", "touristdestination", "placeofworship", "beach", "nationalpark":
                return "attraction"
            case "event", "theaterevent", "musicevent", "festival", "exhibitionevent", "businessevent", "sportsevent":
                return "event"
            // "productgroup" per the Chewy lesson: retailers type multi-variant
            // listings as ProductGroup, and a matcher that only knows Product
            // drops the page's one structured node.
            case "product", "productgroup", "touristtrip", "trip", "offer", "service":
                return "activity"
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - Field extractors (defensive: string-or-number, object-or-array)

    static func asString(_ value: ELVRawJSON?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value.numberValue { return ELVNumberFormat.compactString(number) }
        if value.objectValue != nil { return asString(value["name"]) }
        if let array = value.arrayValue { return array.lazy.compactMap { asString($0) }.first }
        return nil
    }

    /// A finite number from a JSON number or a numeric string. `Double(_:)`
    /// accepts "nan", "inf", and hex floats, and page JSON-LD is hostile
    /// input, so anything non-finite is absent rather than a value that
    /// poisons every consumer's arithmetic.
    static func asDouble(_ value: ELVRawJSON?) -> Double? {
        guard let value else { return nil }
        let parsed = value.numberValue ?? value.stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    /// A formatted address from either a plain string or a schema.org
    /// PostalAddress object.
    static func addressString(from value: ELVRawJSON?) -> String? {
        guard let value else { return nil }
        if value.stringValue != nil { return asString(value) }
        guard value.objectValue != nil else { return asString(value) }
        let parts = ["streetAddress", "addressLocality", "addressRegion", "postalCode", "addressCountry"]
            .compactMap { asString(value[$0]) }
        let joined = parts.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// (latitude, longitude) from a `geo` GeoCoordinates child, or top-level
    /// latitude / longitude. Both must be present, finite, in range, and not
    /// null island: the same gate as the `geo` coercion, so a JSON-LD pin
    /// and a coerced pin are equally trustworthy.
    static func geo(from node: ELVRawJSON) -> (latitude: Double, longitude: Double)? {
        let source = node["geo"] ?? node
        guard let latitude = asDouble(source["latitude"]), let longitude = asDouble(source["longitude"]),
              abs(latitude) <= 90, abs(longitude) <= 180, latitude != 0 || longitude != 0 else { return nil }
        return (latitude, longitude)
    }

    /// A price + ISO currency from `offers` (object or first of an array),
    /// reaching into a nested `priceSpecification`. `lowPrice` rides along
    /// because AggregateOffer ranges (ProductGroup listings) publish it
    /// instead of `price`. The amount runs through the money coercion engine
    /// so minor-unit exponents stay in one place.
    static func money(from node: ELVRawJSON) -> ELVValue? {
        var offers = node["offers"]
        if offers?.objectValue == nil { offers = offers?.arrayValue?.first }
        guard let offers, offers.objectValue != nil else { return nil }
        let spec = offers["priceSpecification"]
        guard let amount = asString(offers["price"]) ?? asString(offers["lowPrice"])
            ?? asString(spec?["price"]) ?? asString(spec?["lowPrice"]),
            let currency = asString(offers["priceCurrency"]) ?? asString(spec?["priceCurrency"]),
            currency.count == 3 else { return nil }
        let coercion = ELVCoercion(kind: "money", currency: currency.uppercased())
        guard case let .money(minor, code)? = ELVCoercionEngine.apply(coercion, to: .string(amount), context: ELVExtractionContext()),
              minor > 0 else { return nil }
        return .money(minorUnits: minor, currencyCode: code)
    }

    /// The product's brand name, from a plain string or a schema.org Brand
    /// object (`asString` already walks `{"name": …}`).
    static func brand(from node: ELVRawJSON) -> String? {
        asString(node["brand"])
    }

    /// The public aggregate rating as a `.rating` leaf on the scale the
    /// page declares: schema.org `bestRating` when plausible (positive, at
    /// most 100), else the schema.org default of 5, with 0 as the lower
    /// bound like the rating coercion's default. A zero, non-finite, or
    /// off-scale value is absent: a public score is never squeezed onto a
    /// scale it was not given on.
    static func rating(from node: ELVRawJSON) -> ELVValue? {
        guard let rating = node["aggregateRating"],
              let value = asDouble(rating["ratingValue"]), value > 0, value.isFinite else { return nil }
        let best = asDouble(rating["bestRating"]).flatMap { $0 > 0 && $0 <= 100 ? $0 : nil } ?? 5
        guard value <= best else { return nil }
        return .rating(value: value, scale: 0 ... best)
    }

    /// A lodging's star class (1...5) from schema.org `starRating`, clamped
    /// in Double space BEFORE the Int conversion: these values come from
    /// arbitrary web-page JSON-LD, and `Int(1e300)` traps where a
    /// post-conversion clamp never runs.
    static func hotelStars(from node: ELVRawJSON) -> Int? {
        guard let star = node["starRating"],
              let value = asDouble(star["ratingValue"]), value > 0, value.isFinite else { return nil }
        let clamped = min(max(value, 1), 5)
        return Int(clamped.rounded())
    }

    /// Duration seconds from a schema.org `duration` / `timeRequired` value
    /// (ISO 8601 "PT2H30M"), through the duration coercion.
    static func durationSeconds(from node: ELVRawJSON) -> Double? {
        guard let raw = asString(node["duration"]) ?? asString(node["timeRequired"]) else { return nil }
        guard case let .duration(seconds)? = ELVCoercionEngine.apply(ELVCoercion(kind: "duration"), to: .string(raw), context: ELVExtractionContext()) else {
            return nil
        }
        return seconds
    }
}
