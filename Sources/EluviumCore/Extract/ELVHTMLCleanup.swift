import Foundation

/// Pack-driven HTML content cleanup (the `htmlStrip` / `rewriteLazyImages`
/// pipes): the Miniflux-rewrite-rules / ftr-strip class of fixes for
/// `content` fields. Selector grammar is deliberately small — `tag`,
/// `.class`, `#id`, `tag.class`, `tag#id` — matched with a balanced
/// same-tag walk so nested containers strip whole, not to the first close.
public enum ELVHTMLCleanup {
    /// Removes every element matching any of `selectors` (element and
    /// content). Unparseable selectors are no-ops: cleanup degrades, it
    /// never invalidates the value carrying it. Like every pack-driven
    /// rewrite, it scans at most `ELVRegexCache.inputCap` characters and
    /// keeps the rest verbatim.
    public static func strip(_ html: String, selectors: [String]) -> String {
        ELVRegexCache.rewritingBoundedHead(of: html) { head in
            var result = head
            for selector in selectors {
                result = strip(result, selector: selector)
            }
            return result
        }
    }

    private struct Selector {
        var tag: String?
        var className: String?
        var id: String?
    }

    // Fixed patterns, compiled once (static-pattern rule). Hostile-input
    // shape: the tag name and the quote-aware attribute run are possessive
    // (no backtracking into them), and an unquoted run stops at the next
    // `<`, so an unclosed tag costs the distance to the next tag. Without
    // the `<` stop, one unclosed quote makes every later open rescan the
    // rest of the page (quadratic even when possessive).
    // swiftlint:disable force_try
    private static let openTagPattern = try! NSRegularExpression(pattern: "<([a-zA-Z][a-zA-Z0-9-]*+)((?:[^<>\"']++|\"[^\"]*+\"|'[^']*+')*+)>")
    private static let imgTagPattern = try! NSRegularExpression(pattern: "<img\\b(?:[^<>\"']++|\"[^\"]*+\"|'[^']*+')*+>", options: [.caseInsensitive])
    private static let srcAttributePattern = try! NSRegularExpression(pattern: "\\bsrc\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive])
    // swiftlint:enable force_try

    /// Lazy-loaded image attributes in adoption order; the first present wins.
    private static let lazySrcAttributes = ["data-src", "data-original", "data-lazy-src", "data-echo", "data-url"]

    private static func parse(_ selector: String) -> Selector? {
        var parsed = Selector()
        let rest = Substring(selector.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return nil }
        if let separator = rest.firstIndex(where: { $0 == "." || $0 == "#" }) {
            let tag = rest[..<separator]
            if !tag.isEmpty { parsed.tag = tag.lowercased() }
            let marker = rest[separator]
            let token = rest[rest.index(after: separator)...]
            guard !token.isEmpty, !token.contains(where: { $0 == "." || $0 == "#" || $0 == " " }) else { return nil }
            if marker == "." { parsed.className = String(token) } else { parsed.id = String(token) }
        } else {
            guard rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
            parsed.tag = rest.lowercased()
        }
        return parsed
    }

    private static func strip(_ html: String, selector raw: String) -> String {
        guard let selector = parse(raw) else { return html }
        let nsHTML = html as NSString
        var removals: [NSRange] = []
        var searchFrom = 0
        while searchFrom < nsHTML.length {
            guard let match = openTagPattern.firstMatch(in: html, range: NSRange(location: searchFrom, length: nsHTML.length - searchFrom)) else { break }
            searchFrom = match.range.location + match.range.length
            let tag = nsHTML.substring(with: match.range(at: 1)).lowercased()
            if let wanted = selector.tag, wanted != tag { continue }
            let attributes = nsHTML.substring(with: match.range(at: 2))
            guard matches(selector, attributes: attributes) else { continue }
            let end = balancedEnd(of: tag, in: nsHTML, openTag: match.range)
            removals.append(NSRange(location: match.range.location, length: end - match.range.location))
            searchFrom = end
        }
        guard !removals.isEmpty else { return html }
        let result = NSMutableString(string: nsHTML)
        for range in removals.reversed() {
            result.replaceCharacters(in: range, with: "")
        }
        return result as String
    }

    private static func matches(_ selector: Selector, attributes: String) -> Bool {
        guard selector.className != nil || selector.id != nil else { return true }
        let parsed = ELVHTMLScanner.parseAttributes(attributes)
        if let className = selector.className {
            guard (parsed["class"] ?? "").split(separator: " ").contains(Substring(className)) else { return false }
        }
        if let id = selector.id {
            guard (parsed["id"] ?? "").trimmingCharacters(in: .whitespaces) == id else { return false }
        }
        return true
    }

    /// The end offset (past the close tag) of the element opened at
    /// `openTag`, balancing nested same-tag opens. A self-closing open, or a
    /// document that never closes the tag, ends at the open tag / document
    /// end respectively.
    private static func balancedEnd(of tag: String, in nsHTML: NSString, openTag: NSRange) -> Int {
        if nsHTML.substring(with: openTag).hasSuffix("/>") { return openTag.location + openTag.length }
        guard let sameTag = ELVRegexCache.regex("<(/?)\(NSRegularExpression.escapedPattern(for: tag))\\b[^<>]*+>") else {
            return openTag.location + openTag.length
        }
        var depth = 1
        var end = nsHTML.length
        let html = nsHTML as String
        let searchStart = openTag.location + openTag.length
        sameTag.enumerateMatches(in: html, range: NSRange(location: searchStart, length: nsHTML.length - searchStart)) { match, _, stop in
            guard let match else { return }
            if match.range(at: 1).length > 0 {
                depth -= 1
                if depth == 0 {
                    end = match.range.location + match.range.length
                    stop.pointee = true
                }
            } else if !nsHTML.substring(with: match.range).hasSuffix("/>") {
                depth += 1
            }
        }
        return end
    }

    // MARK: - Lazy images

    /// Rewrites lazy-loaded `<img>` tags so the real image renders without
    /// the page's JS: a `data-src`-family attribute becomes `src` when `src`
    /// is absent or a placeholder (`data:` inline, empty), and `data-srcset`
    /// becomes `srcset` when none exists. The data attributes stay — extra
    /// bytes, zero harm. Scans at most `ELVRegexCache.inputCap` characters
    /// and keeps the rest verbatim.
    public static func rewriteLazyImages(_ html: String) -> String {
        ELVRegexCache.rewritingBoundedHead(of: html, rewriteLazyImageTags)
    }

    private static func rewriteLazyImageTags(_ html: String) -> String {
        let nsHTML = html as NSString
        let matches = imgTagPattern.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return html }
        let result = NSMutableString(string: nsHTML)
        for match in matches.reversed() {
            let tag = nsHTML.substring(with: match.range)
            guard let rewritten = rewriteImgTag(tag), rewritten != tag else { continue }
            result.replaceCharacters(in: match.range, with: rewritten)
        }
        return result as String
    }

    private static func rewriteImgTag(_ tag: String) -> String? {
        let attributes = ELVHTMLScanner.parseAttributes(tag)
        var rewritten = tag
        let src = attributes["src"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let placeholder = src.isEmpty || src.lowercased().hasPrefix("data:")
        if placeholder, let lazy = lazySrcAttributes.compactMap({ attributes[$0] }).first(where: { !$0.isEmpty }) {
            let nsRewritten = rewritten as NSString
            if let existing = srcAttributePattern.firstMatch(in: rewritten, range: NSRange(location: 0, length: nsRewritten.length)) {
                rewritten = nsRewritten.replacingCharacters(in: existing.range, with: "src=\"\(lazy)\"")
            } else if let insertion = rewritten.range(of: "<img", options: .caseInsensitive) {
                rewritten.replaceSubrange(insertion, with: "<img src=\"\(lazy)\"")
            }
        }
        if attributes["srcset"] == nil, let lazySet = attributes["data-srcset"], !lazySet.isEmpty,
           let insertion = rewritten.range(of: "<img", options: .caseInsensitive) {
            rewritten.replaceSubrange(insertion, with: "<img srcset=\"\(lazySet)\"")
        }
        return rewritten
    }
}
