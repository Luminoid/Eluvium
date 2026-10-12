import Foundation

/// Trail stat extraction from freeform prose (`trail.statsFromText@2`):
/// the clustered / labeled / template parsers ported from TripDays'
/// `TrailInfo`, hardened at the port with URL stripping (a share token like
/// "?sh=7mixyz" otherwise reads as "7 mi") so callers don't each carry that
/// guard. Share text gets the benefit of the doubt; page text is skeptical —
/// AllTrails metas are freeform trail prose these days ("…preserve with 15
/// miles of multi-use trails…" on a 0.9 mi trail), so page stats must arrive
/// as a clustered stats block, a value/label block, or the hyphenated
/// template phrasing. Never a lone distance.
struct ELVTrailStats: Equatable {
    var distance: String? // "1.8 mi"
    var difficulty: String? // "Moderate"
    var duration: String? // "38 min"

    var hasAny: Bool { distance != nil || difficulty != nil || duration != nil }

    /// Best-effort extraction from a pasted share blurb ("Mist Trail ·
    /// Moderate · 3.0 mi · 2 h 30 m"). Embedded URLs are stripped first.
    static func parse(fromText text: String) -> Self? {
        let cleaned = strippingURLs(text)
        let info = Self(
            distance: distance(in: cleaned),
            difficulty: difficulty(in: cleaned),
            duration: duration(in: cleaned)
        )
        return info.hasAny ? info : nil
    }

    /// Skeptical extraction for PAGE-sourced text: the three shapes
    /// complement each other (the cluster window can clip a trailing "…to
    /// complete" phrase; the label-value block keeps its difficulty far away
    /// in the title row), so each fills the others' gaps; the cluster wins
    /// where they overlap.
    static func parseFromPage(_ text: String) -> Self? {
        let cleaned = strippingURLs(text)
        let info = [parseClustered(fromText: cleaned), parseLabeled(fromText: cleaned), parseTemplate(fromText: cleaned)]
            .compactMap(\.self)
            .reduce(nil as Self?) { $0?.merging($1) ?? $1 }
        return (info?.hasAny ?? false) ? info : nil
    }

    /// The receiver's values kept, `other`'s used only to fill nil fields.
    func merging(_ other: Self?) -> Self {
        guard let other else { return self }
        return Self(
            distance: distance ?? other.distance,
            difficulty: difficulty ?? other.difficulty,
            duration: duration ?? other.duration
        )
    }

    /// Scans free-running body text line by line for the rendered description
    /// paragraph. A line counts only when the template yields two or more
    /// fields there: the phrasings are specific to the page's own
    /// description, but a lone hyphenated distance ("a 28-mile scenic
    /// drive") is still just prose. Line-scoped so fields from unrelated
    /// paragraphs can never combine.
    static func parseTemplateLine(fromText text: String) -> Self? {
        for line in text.components(separatedBy: "\n") {
            guard let info = parseTemplate(fromText: strippingURLs(line)) else { continue }
            let fieldCount = [info.distance, info.difficulty, info.duration].compactMap(\.self).count
            if fieldCount >= 2 { return info }
        }
        return nil
    }

    // MARK: - Fixed patterns

    // Every pattern here is a compile-time constant compiled once (the
    // static-pattern rule); the field parsers run several of them per call
    // site per record, and all are case-insensitive.
    // swiftlint:disable force_try
    private static let lengthLineRegex = try! NSRegularExpression(pattern: "^[0-9]+(?:\\.[0-9]+)?\\s*(?:mi(?:les?)?|km|kilomet(?:er|re)s?)$", options: [.caseInsensitive])
    private static let durationLineRegex = try! NSRegularExpression(pattern: "^[0-9][0-9.\\s:–-]*(?:h(?:rs?)?|hours?|m(?:ins?)?|minutes?)(?:\\s*[0-9]+\\s*m(?:ins?)?)?$", options: [.caseInsensitive])
    private static let distanceRegex = try! NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*-?\\s*(km|kilomet(?:er|re)s?|mi(?:les?)?)\\b", options: [.caseInsensitive])
    private static let templateDistanceRegex = try! NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)-(mile|km|kilomet(?:er|re))\\b", options: [.caseInsensitive])
    private static let difficultyPhraseRegex = try! NSRegularExpression(pattern: "considered an?\\s+(.+?)\\s+route", options: [.caseInsensitive])
    private static let difficultyWordRegex = try! NSRegularExpression(pattern: "\\b(easy|moderately challenging|moderate|hard|difficult|challenging)\\b", options: [.caseInsensitive])
    private static let durationPhraseRegex = try! NSRegularExpression(pattern: "average of\\s+(.+?)\\s+to complete", options: [.caseInsensitive])
    /// Bare duration shapes in fallback order: "2 h 30 m" / "1h"; "45 min";
    /// AllTrails' rendered header "Est. 15m" (the anchor keeps metric
    /// elevation like "22 m gain" out); and the label-value block's hour
    /// range "1.5–2hr" (the required hour unit keeps bare numbers out).
    private static let bareDurationRegexes: [NSRegularExpression] = [
        "\\b([0-9]+\\s*h(?:\\s*[0-9]+\\s*m(?:in)?)?)\\b",
        "\\b([0-9]+\\s*min(?:utes)?)\\b",
        "\\bEst\\.?\\s*([0-9]+\\s*m)\\b",
        "\\b([0-9]+(?:\\.[0-9]+)?(?:\\s*[–-]\\s*[0-9]+(?:\\.[0-9]+)?)?\\s*h(?:rs?|ours?)?)\\b",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    // swiftlint:enable force_try

    // MARK: - Shapes

    /// The stats block AllTrails renders as value/label line pairs
    /// ("3.9mi\nLength\n518ft\nElevation gain\n1.5–2hr\nEstimated time"),
    /// with the difficulty up in the title row as its own line. The distance
    /// only counts against a "Length" label so elevation ("518ft") can't
    /// bleed in, and difficulty / duration ride along only when that label
    /// hit exists — a free-floating "Hard" line alone is someone else's badge.
    static func parseLabeled(fromText text: String) -> Self? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func value(around label: String, matching regex: NSRegularExpression) -> String? {
            guard let index = lines.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else { return nil }
            let neighbors = [index > 0 ? lines[index - 1] : nil, index + 1 < lines.count ? lines[index + 1] : nil]
            return neighbors.compactMap(\.self).first {
                regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
            }
        }
        guard let lengthLine = value(around: "Length", matching: lengthLineRegex),
              let distance = distance(in: lengthLine)
        else { return nil }
        let levelWords: Set = ["easy", "moderate", "moderately challenging", "hard", "difficult", "challenging"]
        return Self(
            distance: distance,
            difficulty: lines.first { levelWords.contains($0.lowercased()) }.map(capitalizedFirst),
            duration: value(around: "Estimated time", matching: durationLineRegex)
        )
    }

    /// The generated-description template phrasing alone ("this 0.9-mile
    /// out-and-back trail…", "considered an easy route", "average of 15 min
    /// to complete"). Nil when no template phrase matched.
    static func parseTemplate(fromText text: String) -> Self? {
        var distance: String?
        if let groups = captures(templateDistanceRegex, in: text), groups.count >= 2 {
            distance = "\(groups[0]) \(groups[1].lowercased().hasPrefix("m") ? "mi" : "km")"
        }
        let info = Self(
            distance: distance,
            difficulty: captures(difficultyPhraseRegex, in: text)?.first.flatMap { $0.isEmpty ? nil : capitalizedFirst($0) },
            duration: captures(durationPhraseRegex, in: text)?.first.flatMap { $0.isEmpty ? nil : $0 }
        )
        return info.hasAny ? info : nil
    }

    /// Cluster extraction for noisy free-running text: a lone "15 mi" there
    /// is usually some OTHER trail's stat (related-trail cards), a search
    /// radius, or area prose, so a distance only counts when a second stat
    /// sits within `window` characters of it — the shape of a rendered stats
    /// block ("Easy · 0.9 mi · Est. 15 min"). The first such cluster wins:
    /// the page's own stats header precedes related cards in DOM order.
    static func parseClustered(fromText text: String, window: Int = 90) -> Self? {
        let nsText = text as NSString
        for match in distanceRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            let start = max(0, match.range.location - window)
            let end = min(nsText.length, match.range.location + match.range.length + window)
            let windowText = nsText.substring(with: NSRange(location: start, length: end - start))
            let difficulty = difficulty(in: windowText)
            let duration = duration(in: windowText)
            guard difficulty != nil || duration != nil else { continue }
            let unit = nsText.substring(with: match.range(at: 2)).lowercased().hasPrefix("k") ? "km" : "mi"
            return Self(
                distance: "\(nsText.substring(with: match.range(at: 1))) \(unit)",
                difficulty: difficulty,
                duration: duration
            )
        }
        return nil
    }

    // MARK: - Field parsers

    private static func distance(in text: String) -> String? {
        guard let groups = captures(distanceRegex, in: text), groups.count >= 2 else { return nil }
        let unit = groups[1].lowercased().hasPrefix("k") ? "km" : "mi"
        return "\(groups[0]) \(unit)"
    }

    private static func difficulty(in text: String) -> String? {
        if let phrase = captures(difficultyPhraseRegex, in: text)?.first, !phrase.isEmpty {
            return capitalizedFirst(phrase)
        }
        if let word = captures(difficultyWordRegex, in: text)?.first {
            return capitalizedFirst(word)
        }
        return nil
    }

    private static func duration(in text: String) -> String? {
        if let phrase = captures(durationPhraseRegex, in: text)?.first, !phrase.isEmpty {
            return phrase
        }
        for regex in bareDurationRegexes {
            if let bare = captures(regex, in: text)?.first { return bare }
        }
        return nil
    }

    // MARK: - Helpers

    /// Removes URL-shaped tokens so query strings never feed the stat
    /// regexes (the "?sh=7mixyz" share token once read as "7 mi").
    private static func strippingURLs(_ text: String) -> String {
        guard text.range(of: "://") != nil else { return text }
        return text.split(whereSeparator: \.isWhitespace)
            .filter { $0.range(of: "://") == nil }
            .joined(separator: " ")
    }

    /// Trimmed capture groups (1...) of the first match.
    private static func captures(_ regex: NSRegularExpression, in text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        return (1 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }

    private static func capitalizedFirst(_ string: String) -> String {
        guard let first = string.first else { return string }
        return first.uppercased() + string.dropFirst()
    }
}
