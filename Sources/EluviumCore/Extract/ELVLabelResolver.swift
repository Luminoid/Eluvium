import Foundation

/// Picks a record's display label from a source's declared ladder
/// (`"label": ["title", "metaName"]`, schemaMinor 5): the label a host's
/// user typed first, then the first strong ladder value, then the first
/// weak-but-specific one (a bare country name), then the brand.
///
/// The ladder's order is the precedence. The convention the starter pack
/// follows is page-derived > share blurb > URL slug > brand: page
/// candidates sit ahead of `{"paste": "label"}` and URL candidates in a
/// field's own ladder, and a later step's value replaces an earlier one's,
/// so a fetched page's name outranks the slug the URL offered. A source
/// whose URL names the place more reliably than its page (Maps) lists the
/// URL field first.
public enum ELVLabelResolver {
    public struct Resolution: Sendable, Equatable {
        public var value: String
        /// `user`, the ladder field that supplied the value, or `brand`.
        public var origin: String

        public init(value: String, origin: String) {
            self.value = value
            self.origin = origin
        }
    }

    /// The label for `ladder` (field name and its string value, in ladder
    /// order), or nil when nothing, not even a brand, is available.
    public static func resolve(userLabel: String?, ladder: [(field: String, value: String)], brand: String?) -> Resolution? {
        if let typed = trimmedNonEmpty(userLabel) {
            return Resolution(value: typed, origin: "user")
        }
        let candidates = ladder.compactMap { entry in trimmedNonEmpty(entry.value).map { (field: entry.field, value: $0) } }
        if let strong = candidates.first(where: { !isWeak($0.value, brand: brand) }) {
            return Resolution(value: strong.value, origin: strong.field)
        }
        // A country-shaped value is weak (anything stronger replaces it)
        // but never generic: with nothing better it is still the label,
        // because a pasted "Japan" may be exactly what the user meant.
        if let specific = candidates.first(where: { !isGeneric($0.value, brand: brand) }) {
            return Resolution(value: specific.value, origin: specific.field)
        }
        return trimmedNonEmpty(brand).map { Resolution(value: $0, origin: "brand") }
    }

    /// Generic: empty, or the brand itself ("Google Maps" names the
    /// service, not the place).
    public static func isGeneric(_ label: String, brand: String?) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let brand = trimmedNonEmpty(brand) else { return false }
        return trimmed.caseInsensitiveCompare(brand) == .orderedSame
    }

    /// Weak: generic, or a bare country name ("Japan", "USA", "日本" is not
    /// in the English table and stays strong). A weak label is replaceable;
    /// `weakAny` triggers fetch past one.
    public static func isWeak(_ label: String, brand: String?) -> Bool {
        isGeneric(label, brand: brand) || ELVCountryNames.namesCountry(label)
    }

    private static func trimmedNonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
