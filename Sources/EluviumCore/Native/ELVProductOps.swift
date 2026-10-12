import Foundation

/// The product / place-node op roster: `jsonld.bestPlaceNode@1` picks the
/// page's best schema.org place or product node (`ELVJSONLDPlaceNode`) and
/// normalizes it into typed outputs, so lodging, food, and store pages read
/// one node instead of a ladder of `jsonld` selectors per type.
extension ELVNativeOps {
    static func registerProductOps() {
        register("jsonld.bestPlaceNode", version: 1) { _, context in
            guard let best = ELVJSONLDPlaceNode.best(in: context.document.jsonLDNodes) else { return nil }
            let node = best.raw
            var outputs: [String: ELVValue] = [:]
            if let category = best.category { outputs["category"] = .text(category) }
            if let name = ELVJSONLDPlaceNode.asString(node["name"]) { outputs["name"] = .text(name) }
            if let brand = ELVJSONLDPlaceNode.brand(from: node) { outputs["brand"] = .text(brand) }
            if let address = ELVJSONLDPlaceNode.addressString(from: node["address"]) { outputs["address"] = .text(address) }
            if let phone = ELVJSONLDPlaceNode.asString(node["telephone"]) { outputs["phone"] = .text(phone) }
            if let geo = ELVJSONLDPlaceNode.geo(from: node) { outputs["geo"] = .geo(latitude: geo.latitude, longitude: geo.longitude) }
            if let cuisine = joinedStrings(node["servesCuisine"]) { outputs["cuisine"] = .text(cuisine) }
            if let rating = ELVJSONLDPlaceNode.rating(from: node) { outputs["rating"] = rating }
            if let stars = ELVJSONLDPlaceNode.hotelStars(from: node) { outputs["hotelStars"] = .number(Double(stars)) }
            if let money = ELVJSONLDPlaceNode.money(from: node) { outputs["price"] = money }
            if let seconds = ELVJSONLDPlaceNode.durationSeconds(from: node) { outputs["duration"] = .duration(seconds) }
            if let description = ELVJSONLDPlaceNode.asString(node["description"]) { outputs["description"] = .text(description) }
            return outputs.isEmpty ? nil : outputs
        }
    }

    /// A string-or-string-array value as one comma-joined string
    /// (`servesCuisine`).
    private static func joinedStrings(_ value: ELVRawJSON?) -> String? {
        if let array = value?.arrayValue {
            let strings = array.compactMap(\.stringValue)
            return strings.isEmpty ? nil : strings.joined(separator: ", ")
        }
        return ELVJSONLDPlaceNode.asString(value)
    }
}
