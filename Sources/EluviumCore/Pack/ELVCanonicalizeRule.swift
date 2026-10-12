import Foundation

/// Per-source URL canonicalization: provably per-brand, so it is
/// config. `strip` removes matching query params (glob `*` allowed);
/// `keep` removes everything else (Komoot's `share_token` gates access —
/// never strip it).
public struct ELVCanonicalizeRule: Sendable, Decodable, Equatable {
    public var strip: [String]
    public var keep: [String]

    public init(strip: [String] = [], keep: [String] = []) {
        self.strip = strip
        self.keep = keep
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        strip = try container.elvStringList(forKey: .init("strip"))
        keep = try container.elvStringList(forKey: .init("keep"))
    }

    public func apply(to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return url }
        let kept = items.filter { item in
            if !keep.isEmpty { return keep.contains(item.name) }
            return !strip.contains { matchesGlob(item.name, pattern: $0) }
        }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    private func matchesGlob(_ name: String, pattern: String) -> Bool {
        Self.matchesGlob(name, pattern: pattern)
    }

    fileprivate static func matchesGlob(_ name: String, pattern: String) -> Bool {
        // A pack pattern evaluated per query item per URL: the compile goes
        // through the shared cache.
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        return ELVRegexCache.matches("^\(escaped)$", in: name)
    }
}

public extension ELVCanonicalizeRule {
    /// Query params that record how a link was clicked or shared, never
    /// which page it is: campaign tags (`utm_*`), ad and mail click ids, and
    /// share-sheet stamps. The one list for every place that keys on a URL.
    static let trackingParams: [String] = [
        "utm_*", "fbclid", "gclid", "dclid", "mc_cid", "mc_eid", "igshid", "_hsenc", "_hsmi", "yclid", "msclkid",
    ]

    /// `url` without its `trackingParams`. A URL that carries none comes
    /// back exactly as given (no re-serialized query), so only tracked links
    /// change.
    static func strippingTracking(_ url: URL) -> URL {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.contains(where: { item in trackingRule.strip.contains { matchesGlob(item.name, pattern: $0) } })
        else { return url }
        return trackingRule.apply(to: url)
    }

    private static let trackingRule = ELVCanonicalizeRule(strip: trackingParams)
}
