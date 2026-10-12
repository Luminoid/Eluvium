import Foundation

/// Main-content extraction from raw article HTML (the `article.bodyFromPage@1`
/// readability heuristic): one linear tag scan builds a container stack with
/// source ranges, paragraphs score their nearest containers by text mass,
/// comma density, and link density (class/id hints adjust), and the winner's
/// inner HTML comes back as the page's own bytes cleaned of scripts, styles,
/// comments, and embedded chrome — no DOM dependency, matching the
/// `ELVHTMLScanner` posture. Pages without a scoring body (storefronts, link
/// hubs, shells) return nil so the calling candidate falls through.
///
/// The scoring follows the heuristics of Arc90's Readability and its
/// successor, Mozilla's Readability.js (Apache License 2.0): the
/// positive/negative class and id hint lists, the ±25 class weight, the
/// `1 + commas + min(length / 100, 3)` paragraph score scaled by link
/// density, and the full-score parent / half-score grandparent propagation.
/// The implementation here is independent (a tag scan, not a DOM port).
public enum ELVArticleBody {
    public struct Extraction: Sendable, Equatable {
        /// The winning container's inner HTML, cleaned.
        public var html: String
        /// The paragraph text mass that earned the pick.
        public var textLength: Int
    }

    /// Scan cap in UTF-16 units: pages past the fetcher's byte budget never
    /// reach here whole, and a linear regex pass over more than this buys
    /// nothing but latency.
    private static let maxScanLength = 1_500_000
    /// Output cap so one pathological page can't grow an unbounded record.
    private static let maxOutputLength = 400_000
    /// A candidate must carry at least this much paragraph text…
    fileprivate static let minimumTextLength = 250
    /// …and score at least this much, or the page has no article body.
    fileprivate static let minimumScore = 8.0
    /// Paragraphs shorter than this are captions/labels, not body text.
    fileprivate static let minimumParagraphLength = 20

    /// The container stack's depth cap: opens nested deeper are ignored
    /// (their closes too), so a page of 100k nested `<div>`s costs a
    /// bounded stack instead of one entry per open. Real article markup
    /// nests a few dozen deep.
    fileprivate static let maxContainerDepth = 512

    // Fixed patterns, compiled once (the static-pattern rule; a compile
    // failure is a programmer error, same convention as ELVHTMLScanner).
    // Hostile-input shape: a comment is matched by its OPEN only (the scan
    // finds its close with one literal search), and a tag's attribute run
    // stops at the next `<`, so neither an unclosed `<!--` nor an unclosed
    // tag makes later matches rescan the rest of the page.
    // swiftlint:disable force_try
    private static let tagPattern = try! NSRegularExpression(pattern: "<!--|<(/?)([a-zA-Z][a-zA-Z0-9-]*+)([^<>]*+)>")
    private static let positiveHintPattern = try! NSRegularExpression(pattern: "article|blog|body|content|entry|main|page|post|story|text", options: [.caseInsensitive])
    private static let negativeHintPattern = try! NSRegularExpression(
        pattern: "banner|breadcrumb|combx|comment|contact|disqus|extra|foot|header|masthead|menu|nav|outbrain"
            + "|pager|pagination|popup|promo|related|scroll|share|shoutbox|sidebar|social|sponsor|tags|tool|widget",
        options: [.caseInsensitive]
    )
    /// The opens of the chrome `removingChrome` drops; each close is a
    /// literal search, not a lazy `[\\s\\S]*?` per open.
    private static let chromeOpenPattern = try! NSRegularExpression(
        pattern: "<!--|<(script|style|noscript|iframe|form|svg)\\b[^<>]*+>",
        options: [.caseInsensitive]
    )
    // swiftlint:enable force_try

    fileprivate static let containerTags: Set<String> = ["article", "main", "section", "div", "td", "body"]
    fileprivate static let paragraphTags: Set<String> = ["p", "blockquote", "pre", "h2", "h3"]
    /// Structural chrome whose text must never score.
    fileprivate static let mutedTags: Set<String> = ["aside", "button", "footer", "form", "header", "nav", "noscript", "select", "textarea"]
    /// Raw-text elements: their content is not HTML, so every event until
    /// the matching close tag is noise (per spec, `</script` inside a string
    /// still terminates — real parsers behave the same).
    fileprivate static let rawTextTags: Set<String> = ["script", "style"]

    fileprivate struct Container {
        let tag: String
        let hint: Double
        let innerStart: Int
        /// The scan's running prose total when this container opened: its
        /// own prose mass is the total at close minus this, so a paragraph
        /// close costs O(1) instead of a walk over every open ancestor.
        let proseAtOpen: Int
        var score = 0.0
    }

    fileprivate struct Paragraph {
        var textLength = 0
        var commas = 0
        var linkTextLength = 0
    }

    public static func extract(html: String) -> Extraction? {
        let nsHTML = html as NSString
        let scanLength = min(nsHTML.length, maxScanLength)
        var scan = Scan(nsHTML: nsHTML, scanLength: scanLength)
        tagPattern.enumerateMatches(in: html, range: NSRange(location: 0, length: scanLength)) { match, _, _ in
            guard let match else { return }
            scan.handleTag(match)
        }
        scan.finish(at: scanLength)

        guard let best = scan.best else { return nil }
        let clipped = NSRange(location: best.range.location, length: min(best.range.length, maxOutputLength))
        let cleaned = removingChrome(nsHTML.substring(with: clipped)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return Extraction(html: cleaned, textLength: best.textLength)
    }

    /// Drops scripts, styles, noscript, iframes, forms, inline SVG, and
    /// comments from the winner's HTML. An element without its close is
    /// kept (as the old lazy regex did), and once a kind's close is missing
    /// after some offset it is never searched for again (none can follow a
    /// later open either); every successful search skips past the element
    /// it removed. So the walk is linear even over a page of unclosed opens.
    private static func removingChrome(_ html: String) -> String {
        let nsHTML = html as NSString
        var kept = ""
        var keptFrom = 0
        var unclosedKinds = Set<String>()
        chromeOpenPattern.enumerateMatches(in: html, range: NSRange(location: 0, length: nsHTML.length)) { match, _, _ in
            guard let match, match.range.location >= keptFrom else { return }
            let nameRange = match.range(at: 1)
            let kind = nameRange.location == NSNotFound ? "--" : nsHTML.substring(with: nameRange).lowercased()
            guard !unclosedKinds.contains(kind) else { return }
            let closer = kind == "--" ? "-->" : "</\(kind)>"
            let searchStart = match.range.location + match.range.length
            let close = nsHTML.range(of: closer, options: .caseInsensitive, range: NSRange(location: searchStart, length: nsHTML.length - searchStart))
            guard close.location != NSNotFound else {
                unclosedKinds.insert(kind)
                return
            }
            kept += nsHTML.substring(with: NSRange(location: keptFrom, length: match.range.location - keptFrom))
            keptFrom = close.location + close.length
        }
        guard keptFrom > 0 else { return html }
        return kept + nsHTML.substring(from: keptFrom)
    }

    /// Class/id hints, readability-style: `<article>`/`<main>` announce
    /// themselves, positive markers help, chrome markers hurt.
    fileprivate static func hint(tag: String, attributes: String) -> Double {
        var value = 0.0
        if tag == "article" || tag == "main" { value += 30 }
        let parsed = ELVHTMLScanner.parseAttributes(attributes)
        let markers = [parsed["class"], parsed["id"]].compactMap(\.self).joined(separator: " ")
        guard !markers.isEmpty else { return value }
        let markerRange = NSRange(markers.startIndex..., in: markers)
        if positiveHintPattern.firstMatch(in: markers, range: markerRange) != nil { value += 25 }
        if negativeHintPattern.firstMatch(in: markers, range: markerRange) != nil { value -= 25 }
        return value
    }
}

/// The one-pass scan state: the container stack, the open-paragraph stack,
/// the muting depths, and the running best candidate — a struct with small
/// methods so each concern reads (and lints) on its own.
private struct Scan {
    let nsHTML: NSString
    /// The scanned prefix; a comment closing past it is not a comment.
    let scanLength: Int
    var containers: [ELVArticleBody.Container] = []
    /// Open containers per tag name, so a close's "is this tag open at
    /// all" check is O(1) instead of a stack walk.
    var openCounts: [String: Int] = [:]
    /// Opens ignored past `maxContainerDepth`, per tag name; their closes
    /// are ignored too, so they never pop a real container.
    var overflowCounts: [String: Int] = [:]
    var paragraphs: [ELVArticleBody.Paragraph] = []
    /// Prose mass of every paragraph closed so far (see
    /// `Container.proseAtOpen`).
    var totalProse = 0
    var anchorDepth = 0
    var mutedDepth = 0
    var rawSkipTag: String?
    var lastIndex = 0
    /// Matches before this offset sit inside a comment already consumed.
    var skipUntil = 0
    /// Set once a `<!--` has no `-->` after it: no later open can have one
    /// either, so later opens are ignored without another search.
    var commentCloseMissing = false
    var best: (score: Double, textLength: Int, range: NSRange)?

    mutating func handleTag(_ match: NSTextCheckingResult) {
        guard match.range.location >= skipUntil else { return }
        // The comment alternative is the bare `<!--` open, with no groups.
        guard match.range(at: 2).location != NSNotFound else {
            handleComment(openedAt: match.range)
            return
        }
        handleText(upTo: match.range.location)
        lastIndex = match.range.location + match.range.length
        let name = nsHTML.substring(with: match.range(at: 2)).lowercased()
        let isClose = match.range(at: 1).length > 0
        if let skip = rawSkipTag {
            if isClose, name == skip { rawSkipTag = nil }
            return
        }
        let attributes = match.range(at: 3).location != NSNotFound ? nsHTML.substring(with: match.range(at: 3)) : ""
        route(name: name, isClose: isClose, selfClosing: attributes.hasSuffix("/"), attributes: attributes, at: match.range.location)
    }

    /// A comment consumes through its `-->` like the old lazy alternative
    /// did: the text before it counts, nothing inside it does. An
    /// unclosed `<!--` is no comment at all (the tags after it still scan).
    private mutating func handleComment(openedAt open: NSRange) {
        guard !commentCloseMissing else { return }
        let searchStart = open.location + open.length
        let close = nsHTML.range(of: "-->", range: NSRange(location: searchStart, length: max(0, scanLength - searchStart)))
        guard close.location != NSNotFound else {
            commentCloseMissing = true
            return
        }
        handleText(upTo: open.location)
        lastIndex = close.location + close.length
        skipUntil = lastIndex
    }

    private mutating func route(name: String, isClose: Bool, selfClosing: Bool, attributes: String, at location: Int) {
        if ELVArticleBody.rawTextTags.contains(name) {
            if !isClose, !selfClosing { rawSkipTag = name }
        } else if ELVArticleBody.mutedTags.contains(name) {
            if isClose { mutedDepth = max(0, mutedDepth - 1) } else if !selfClosing { mutedDepth += 1 }
        } else if name == "a" {
            if isClose { anchorDepth = max(0, anchorDepth - 1) } else if !selfClosing { anchorDepth += 1 }
        } else if ELVArticleBody.paragraphTags.contains(name) {
            if isClose { closeParagraph() } else if !selfClosing { paragraphs.append(ELVArticleBody.Paragraph()) }
        } else if ELVArticleBody.containerTags.contains(name) {
            if isClose {
                closeContainer(named: name, at: location)
            } else if !selfClosing {
                openContainer(named: name, attributes: attributes)
            }
        }
    }

    private mutating func openContainer(named name: String, attributes: String) {
        guard containers.count < ELVArticleBody.maxContainerDepth else {
            overflowCounts[name, default: 0] += 1
            return
        }
        let hint = ELVArticleBody.hint(tag: name, attributes: attributes)
        containers.append(ELVArticleBody.Container(tag: name, hint: hint, innerStart: lastIndex, proseAtOpen: totalProse))
        openCounts[name, default: 0] += 1
    }

    /// Mis-nesting tolerance: close intermediates down to the matching tag;
    /// a stray close with no match is ignored. A close whose open was
    /// ignored past the depth cap is ignored with it.
    private mutating func closeContainer(named name: String, at location: Int) {
        if let overflow = overflowCounts[name], overflow > 0 {
            overflowCounts[name] = overflow - 1
            return
        }
        guard openCounts[name, default: 0] > 0 else { return }
        while let top = containers.popLast() {
            openCounts[top.tag, default: 1] -= 1
            finalize(top, endsAt: location)
            if top.tag == name { break }
        }
    }

    private mutating func handleText(upTo location: Int) {
        defer { lastIndex = location }
        guard rawSkipTag == nil, mutedDepth == 0, !paragraphs.isEmpty, location > lastIndex else { return }
        let text = nsHTML.substring(with: NSRange(location: lastIndex, length: location - lastIndex))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paragraphs[paragraphs.count - 1].textLength += trimmed.count
        paragraphs[paragraphs.count - 1].commas += trimmed.count(where: { $0 == "," || $0 == "，" })
        if anchorDepth > 0 { paragraphs[paragraphs.count - 1].linkTextLength += trimmed.count }
    }

    private mutating func closeParagraph() {
        guard let paragraph = paragraphs.popLast() else { return }
        guard paragraph.textLength >= ELVArticleBody.minimumParagraphLength, !containers.isEmpty else { return }
        let density = Double(paragraph.linkTextLength) / Double(max(paragraph.textLength, 1))
        let points = (1.0 + Double(paragraph.commas) + min(Double(paragraph.textLength) / 100, 3)) * max(0, 1 - density)
        // Prose mass is containment: every open ancestor holds this text,
        // folded lazily through the running total (`proseAtOpen`). Link
        // text is navigation, not mass — a wall of linked rows must never
        // reach the text floor.
        totalProse += max(0, paragraph.textLength - paragraph.linkTextLength)
        containers[containers.count - 1].score += points
        if containers.count >= 2 { containers[containers.count - 2].score += points / 2 }
    }

    private mutating func finalize(_ container: ELVArticleBody.Container, endsAt: Int) {
        let total = container.score + container.hint
        let textLength = totalProse - container.proseAtOpen
        // The hint can boost an earned score, never substitute for one: a
        // zero-scoring container is chrome no matter what its class says.
        guard container.score > 0, textLength >= ELVArticleBody.minimumTextLength, total >= ELVArticleBody.minimumScore, endsAt > container.innerStart else { return }
        if total > (best?.score ?? 0) {
            best = (total, textLength, NSRange(location: container.innerStart, length: endsAt - container.innerStart))
        }
    }

    /// End of document: flush the text tail, close whatever never closed.
    mutating func finish(at scanLength: Int) {
        handleText(upTo: scanLength)
        while !paragraphs.isEmpty {
            closeParagraph()
        }
        while let top = containers.popLast() {
            finalize(top, endsAt: scanLength)
        }
    }
}
