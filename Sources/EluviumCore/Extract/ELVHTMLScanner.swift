import Foundation

/// Lightweight extraction over raw HTML text: meta tags, the title, and
/// JSON-LD islands. This is the `http`-mode half of extraction — no HTML
/// parser dependency; the DOM engine handles anything that needs a real
/// render.
public enum ELVHTMLScanner {
    /// Everything the scanner pulls from one HTML document.
    public struct Result: Sendable, Equatable {
        /// `property`/`name` → decoded `content`, first occurrence wins
        /// (`og:title`, `description`, `product:price:currency`, …).
        public var metas: [String: String]
        /// Decoded, whitespace-collapsed `<title>` text.
        public var title: String?
        /// Every parseable `application/ld+json` island, `@graph` flattened
        /// to top-level nodes in document order.
        public var jsonLDNodes: [ELVRawJSON]
        /// The `<link>` tags with a `rel` and an `href`, in document order
        /// (feed discovery, canonical).
        public var links: [ELVHTMLLink]
    }

    public static func scan(_ html: String) -> Result {
        // One NSString bridge serves all four scans of the document.
        let nsHTML = html as NSString
        return Result(
            metas: scanMetas(html, nsHTML),
            title: scanTitle(html, nsHTML),
            jsonLDNodes: scanJSONLD(html, nsHTML),
            links: scanLinks(html, nsHTML)
        )
    }

    // MARK: - Metas

    /// Hostile-input shape: every tag pattern stops at the next `<`
    /// (`[^<>]*+`, possessive), so an attempt from an unclosed `<meta` costs
    /// the distance to the next tag, never the rest of the page. With
    /// `[^>]*`, k unclosed opens over n bytes cost O(k·n); a length bound
    /// alone (`[^>]{0,4096}`) still costs O(k·4096), which is minutes on a
    /// 2 MB page of opens.
    private static let metaTagPattern = regex("<meta\\b[^<>]*+>")
    // An attribute name starts only at a name boundary and every run is
    // possessive: with a plain `[a-zA-Z0-9:_-]*`, a 2 MB run of letters in one
    // tag retried the name from every letter and backtracked each time
    // (quadratic, effectively never finishing).
    private static let attributePattern = regex("(?<![a-zA-Z0-9:_-])([a-zA-Z][a-zA-Z0-9:_-]*+)\\s*+=\\s*+(?:\"([^\"]*+)\"|'([^']*+)')")
    private static let titleOpenPattern = regex("<title\\b[^<>]*+>")
    private static let linkTagPattern = regex("<link\\b[^<>]*+>")
    private static let scriptOpenPattern = regex("<script\\b[^<>]*?type\\s*=\\s*[\"']application/ld\\+json[\"'][^<>]*+>")
    private static let whitespaceRunPattern = regex("\\s+", options: [])
    /// The longest `<title>` body the scan reads: the close is a literal
    /// search inside this window, never a lazy `.*?` across the page.
    private static let maxTitleLength = 4096

    private static func scanMetas(_ html: String, _ nsHTML: NSString) -> [String: String] {
        var metas: [String: String] = [:]
        for tag in matches(of: metaTagPattern, in: html, nsHTML) {
            let attributes = parseAttributes(tag)
            guard let content = attributes["content"] else { continue }
            let key = attributes["property"] ?? attributes["name"] ?? attributes["itemprop"]
            guard let key, !key.isEmpty, metas[key] == nil else { continue }
            metas[key] = ELVEntityDecoder.decode(content)
        }
        return metas
    }

    /// The first `<title>` element's text. The open tag is a linear regex
    /// hit; the close is a literal `</title` search inside
    /// `maxTitleLength`, so a page of unclosed opens costs one bounded
    /// search, not one lazy scan per open.
    private static func scanTitle(_ html: String, _ nsHTML: NSString) -> String? {
        guard let open = titleOpenPattern.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)) else { return nil }
        let bodyStart = open.range.location + open.range.length
        let window = NSRange(location: bodyStart, length: min(maxTitleLength + "</title".count, nsHTML.length - bodyStart))
        let close = nsHTML.range(of: "</title", options: .caseInsensitive, range: window)
        guard close.location != NSNotFound else { return nil }
        let raw = ELVEntityDecoder.decode(nsHTML.substring(with: NSRange(location: bodyStart, length: close.location - bodyStart)))
        // A fixed pattern compiled once; this runs per scanned document.
        let collapsed = whitespaceRunPattern.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func scanLinks(_ html: String, _ nsHTML: NSString) -> [ELVHTMLLink] {
        matches(of: linkTagPattern, in: html, nsHTML).compactMap { tag in
            let attributes = parseAttributes(tag)
            guard let rel = attributes["rel"]?.lowercased(), let href = attributes["href"], !href.isEmpty else { return nil }
            return ELVHTMLLink(rel: rel, href: href, type: attributes["type"]?.lowercased())
        }
    }

    /// `name` → value for every quoted attribute in `tag` (a whole tag or a
    /// bare attribute string): names lowercased, first occurrence wins,
    /// unquoted values are not attributes. The one attribute walk shared by
    /// the meta and link scans, the article-body hint scorer, and HTML
    /// cleanup, so the three can never disagree on what an attribute is.
    static func parseAttributes(_ tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let nsTag = tag as NSString
        for match in attributePattern.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)) {
            let name = nsTag.substring(with: match.range(at: 1)).lowercased()
            let doubleQuoted = match.range(at: 2)
            let singleQuoted = match.range(at: 3)
            let value = doubleQuoted.location != NSNotFound ? nsTag.substring(with: doubleQuoted)
                : singleQuoted.location != NSNotFound ? nsTag.substring(with: singleQuoted) : ""
            if attributes[name] == nil { attributes[name] = value }
        }
        return attributes
    }

    // MARK: - JSON-LD

    /// Linear on hostile pages: an open inside an island already read is
    /// skipped (it is that island's text), and the first open with no
    /// `</script` after it ends the scan (no later open can have one), so
    /// the close searches cover each byte once.
    private static func scanJSONLD(_ html: String, _ nsHTML: NSString) -> [ELVRawJSON] {
        var nodes: [ELVRawJSON] = []
        var resumeAt = 0
        for match in scriptOpenPattern.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) where match.range.location >= resumeAt {
            let bodyStart = match.range.location + match.range.length
            let closeRange = nsHTML.range(of: "</script", options: .caseInsensitive, range: NSRange(location: bodyStart, length: nsHTML.length - bodyStart))
            guard closeRange.location != NSNotFound else { break }
            resumeAt = closeRange.location + closeRange.length
            let body = nsHTML.substring(with: NSRange(location: bodyStart, length: closeRange.location - bodyStart))
            guard let parsed = ELVRawJSON.parse(Data(body.utf8)) else { continue }
            nodes.append(contentsOf: flattenJSONLD(parsed))
        }
        return nodes
    }

    /// Top-level arrays and `@graph` wrappers both flatten to their member
    /// nodes; anything else is one node. Depth-capped: the nesting is
    /// attacker-controlled page content, so past the cap the wrapper counts
    /// as one node instead of recursing further.
    private static func flattenJSONLD(_ root: ELVRawJSON, depth: Int = 0) -> [ELVRawJSON] {
        guard depth < 32 else { return [root] }
        if let array = root.arrayValue {
            return array.flatMap { flattenJSONLD($0, depth: depth + 1) }
        }
        if let graph = root["@graph"]?.arrayValue {
            return graph.flatMap { flattenJSONLD($0, depth: depth + 1) }
        }
        return [root]
    }

    // MARK: - JSON islands

    /// The parsed body of an embedded `<script id="…">` JSON island
    /// (Next.js-style server data). The id arrives from a pack step's
    /// `jsonIsland` key, so it is escaped before it touches the pattern;
    /// nil when the island is absent or its body is not JSON. Body capture
    /// mirrors the JSON-LD scan: a literal `</script` search, never a
    /// lazy-dot regex across a megabyte island.
    public static func jsonIsland(id: String, in html: String) -> ELVRawJSON? {
        let nsHTML = html as NSString
        let escaped = NSRegularExpression.escapedPattern(for: id)
        guard let open = ELVRegexCache.regex("(?i)<script\\b[^<>]*?\\bid\\s*=\\s*[\"']\(escaped)[\"'][^<>]*+>"),
              let match = open.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)) else { return nil }
        let bodyStart = match.range.location + match.range.length
        let closeRange = nsHTML.range(of: "</script", options: .caseInsensitive, range: NSRange(location: bodyStart, length: nsHTML.length - bodyStart))
        guard closeRange.location != NSNotFound else { return nil }
        let body = nsHTML.substring(with: NSRange(location: bodyStart, length: closeRange.location - bodyStart))
        return ELVRawJSON.parse(Data(body.utf8))
    }

    // MARK: - Regex plumbing

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure is a programmer error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(of regex: NSRegularExpression, in string: String, _ nsString: NSString) -> [String] {
        regex.matches(in: string, range: NSRange(location: 0, length: nsString.length)).map {
            nsString.substring(with: $0.range)
        }
    }
}

/// One `<link>` tag the scanner kept: lowercased `rel` and `type`, the
/// `href` as written (resolve it with `ELVURLPolicy` before fetching).
public struct ELVHTMLLink: Sendable, Equatable, Hashable {
    public var rel: String
    public var href: String
    public var type: String?

    public init(rel: String, href: String, type: String? = nil) {
        self.rel = rel
        self.href = href
        self.type = type
    }
}
