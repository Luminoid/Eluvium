import Foundation

/// Anchored host matching. Framework law, not pack choice: the pack
/// schema has no substring form, so `amazon.evil.com` can never match an
/// `amazon` rule by construction. The hostile-lookalike conformance suite in
/// `EluviumCoreTests` runs against every change here.
public enum ELVHostMatcher {
    /// Exact-or-subdomain match: `pattern` `booking.com` matches
    /// `booking.com` and `www.booking.com`, never `evil-booking.com`,
    /// `booking.com.attacker.net`, or an IDN homoglyph.
    public static func hostMatches(_ host: String, pattern: String) -> Bool {
        let host = normalize(host)
        let pattern = normalize(pattern)
        guard !host.isEmpty, !pattern.isEmpty else { return false }
        return host == pattern || host.hasSuffix("." + pattern)
    }

    /// TLD-constrained brand match for multi-TLD brands (Amazon's
    /// storefronts, Google's ccTLDs): the brand must be its own label,
    /// followed only by a plausible public suffix — a single TLD label
    /// (`amazon.de`) or a constrained second-level pair (`amazon.co.jp`).
    /// `amazon.evil.com` fails because `evil` is not an allowed second level.
    public static func hostMatchesBrand(_ host: String, brand: String) -> Bool {
        let host = normalize(host)
        let brand = normalize(brand)
        guard !host.isEmpty, !brand.isEmpty, !brand.contains(".") else { return false }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let brandIndex = labels.lastIndex(of: brand) else { return false }
        let suffix = Array(labels[(brandIndex + 1)...])
        switch suffix.count {
        case 1:
            return isTLDLabel(suffix[0])
        case 2:
            return allowedSecondLevels.contains(suffix[0]) && suffix[1].count == 2 && isTLDLabel(suffix[1])
        default:
            return false
        }
    }

    /// Second-level labels accepted between a brand and a ccTLD
    /// (`co.jp`, `com.au`, `co.uk`, …). Deliberately small: a lookalike's
    /// registrable label (`evil`) must never qualify.
    private static let allowedSecondLevels: Set<String> = ["co", "com", "net", "org", "ac", "gov", "edu"]

    private static func isTLDLabel(_ label: String) -> Bool {
        label.count >= 2 && label.count <= 24 && label.allSatisfy { $0.isLetter && $0.isASCII }
    }

    private static func normalize(_ host: String) -> String {
        var normalized = host.lowercased()
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }
}
