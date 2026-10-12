import Foundation

/// The one scheme-allowlisted URL resolution: every place that turns
/// page-sourced text into a `URL` (the url/image coercions, the `resolveURL`
/// pipe, feed autodiscovery) routes here so a `javascript:` or `data:`
/// string can never ride into a record or a fetch, whichever site produced
/// it.
public enum ELVURLPolicy {
    /// Resolves `string` against `base`, accepting only http(s) results on
    /// a host that could be public: a dotted name, an IPv4 address, or an
    /// IPv6 literal. Protocol-relative (`//host/path`) resolves as https.
    /// The dotless-host refusal lives here, at the one funnel, because a
    /// page can put a non-URL where a URL belongs: fujifilm-x.com writes
    /// `og:image="http://92884"` (a WordPress attachment id) on most of its
    /// lens pages (2026-10-12), which otherwise rode into records as the
    /// media ref `https://92884`. Loopback and private hosts are the egress
    /// policy's call, not this one's.
    public static func resolve(_ string: String, relativeTo base: URL?) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var url = URL(string: trimmed, relativeTo: base)?.absoluteURL
        if url?.scheme == nil, trimmed.hasPrefix("//") {
            url = URL(string: "https:" + trimmed)
        }
        guard let resolved = url, let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = resolved.host, host.contains(".") || host.contains(":")
        else { return nil }
        return resolved
    }

    /// The same URL with an `http` scheme upgraded to `https`; anything else
    /// is returned unchanged. Share sheets hand out `http://` links, and some
    /// sites still publish `http://` media (Viltrox's Shopify theme writes
    /// its `og:image` that way, with the https twin only in
    /// `og:image:secure_url`), while the egress policy is https-only and ATS
    /// refuses plain http inside an app. Only the scheme changes; a URL that
    /// can't round-trip through components stays as-is.
    public static func httpsUpgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        return components.url ?? url
    }
}
