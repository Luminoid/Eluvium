import Foundation

/// The one `{param.x}` template filler for pack URL templates (a fetch
/// step's `url`, a list's `seed`), with `fillInput` for the placeholders
/// only a fetch step can fill (`{host}`, `{query.x}`). Param values are
/// recognition-derived text, so they are percent-encoded before
/// substitution: a reserved character in a captured path segment must not
/// reshape the template's path or query. The pipeline and the enumerator
/// both build URLs from pack templates, so there is exactly one filler.
public enum ELVURLTemplate {
    /// RFC 3986 unreserved characters: everything else (`/`, `?`, `#`, `&`,
    /// `=`, `+`, space, non-ASCII) is percent-encoded, because a param
    /// substitutes into one path segment or one query value and must stay
    /// exactly that.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func fill(_ template: String, params: [String: String]) -> String {
        var filled = template
        for (name, value) in params {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            filled = filled.replacingOccurrences(of: "{param.\(name)}", with: encoded)
        }
        return filled
    }

    /// Fills the placeholders that read the INPUT URL: `{host}` is its host
    /// (a site served per language or region on sibling hosts — Wikipedia's
    /// `xx.wikipedia.org` and `xx.m.wikipedia.org` — keeps one source whose
    /// API call lands on the host the user pasted), and `{query.x}` a query
    /// item (the share links that carry their id in the query, WeRead's
    /// `book-detail?v=`, rather than the path). Same encoding rule as
    /// `{param.x}` for query values; the host must already be host-shaped
    /// (letters, digits, dots, hyphens), since nothing else can reach a
    /// recognized URL's host. Nil when a named item is absent or empty, or
    /// the host is missing or malformed, so the caller fails the step
    /// instead of fetching a URL with a hole in it. Fetch steps only: a list
    /// seed has no input URL to read, and the validator says so.
    public static func fillInput(_ template: String, from url: URL) -> String? {
        var filled = template
        if filled.contains(hostPlaceholder) {
            guard let host = url.host?.lowercased(), !host.isEmpty,
                  host.unicodeScalars.allSatisfy({ hostCharacters.contains($0) }) else { return nil }
            filled = filled.replacingOccurrences(of: hostPlaceholder, with: host)
        }
        guard filled.contains("{query.") else { return filled }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let nsTemplate = filled as NSString
        for match in queryPlaceholderRegex.matches(in: filled, range: NSRange(location: 0, length: nsTemplate.length)).reversed() {
            let name = nsTemplate.substring(with: match.range(at: 1))
            guard let value = items.first(where: { $0.name == name })?.value, !value.isEmpty else { return nil }
            let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            filled = (filled as NSString).replacingCharacters(in: match.range, with: encoded)
        }
        return filled
    }

    /// The input-host placeholder (schemaMinor 4).
    public static let hostPlaceholder = "{host}"
    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    // `{query.x}` placeholders: group 1 is the query item name. Fixed
    // pattern, compiled once.
    // swiftlint:disable:next force_try
    static let queryPlaceholderRegex = try! NSRegularExpression(pattern: "\\{query\\.([A-Za-z0-9_]+)\\}")

    // `{native:op(param.x)}` placeholders: group 1 is the op reference,
    // group 2 the param name. Fixed pattern, compiled once (the
    // static-pattern rule); shared by the validator's load-time probe and
    // the pipeline's runtime substitution so the two cannot disagree.
    // swiftlint:disable:next force_try
    public static let nativePlaceholderRegex = try! NSRegularExpression(pattern: "\\{native:([A-Za-z0-9_.@]+)\\(param\\.([A-Za-z0-9_]+)\\)\\}")
}
