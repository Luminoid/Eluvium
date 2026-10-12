import Foundation

/// The perfume note pyramid from prose (`notePyramid.fromProse`, the
/// Phase-8 fragrance sources): "Top notes are Bergamot, Lemon and Neroli;
/// middle notes are Jasmine and Ylang-Ylang; base notes are Sandalwood and
/// Musk." Fragrantica and Parfumo both render this template; pages with no
/// tiered pyramid still say "The fragrance features X, Y and Z"
/// (Fragrantica's untiered template) or "notes of X, Y and Z", which lands
/// in the flat `notes` output instead — tiers are never invented.
///
/// The text is a whole page (the http path hands the op the raw HTML, the
/// dom path the rendered text), reviews included, so a tier phrase alone
/// is not evidence: Santal 33's first "top note is" sits in a review
/// ("iris set on a nice base of sandalwood, nothing more nothing less",
/// 2026-10-11 log) and landed as `topNotes`. A capture counts as a note
/// list only when every item runs at most `maxWordsPerNote` words and
/// carries no digit, a capture the page cut short with an ellipsis (its
/// own truncated `og:description`, which precedes the body in the HTML)
/// is passed over, and each pattern inspects its first
/// `maxMatchesPerPattern` hits for the first list that qualifies.
enum ELVNotePyramid {
    struct Pyramid: Equatable {
        var top: [String] = []
        var heart: [String] = []
        var base: [String] = []
        var flat: [String] = []

        var isEmpty: Bool { top.isEmpty && heart.isEmpty && base.isEmpty && flat.isEmpty }
    }

    /// "Lily of the Valley" is the longest note name in common use; review
    /// prose runs longer.
    static let maxWordsPerNote = 4
    /// Hits per pattern inspected before the tier is given up: a page's
    /// reviews can repeat a tier phrase many times.
    static let maxMatchesPerPattern = 8

    // Fixed patterns compiled once (the static-pattern rule): five per
    // parse, per page. Each tier list runs from "<tier> notes are/include/:"
    // to the next clause boundary (";", ".", or a following tier phrase).
    // swiftlint:disable force_try
    private static let topRegex = tierRegex("top")
    private static let heartRegex = tierRegex("(?:middle|heart)")
    private static let baseRegex = tierRegex("base")
    private static let featuresRegex = try! NSRegularExpression(pattern: "\\bfragrance\\s+features\\s+([^;.\\n]+)", options: [.caseInsensitive])
    private static let flatRegex = try! NSRegularExpression(pattern: "\\bnotes\\s+of\\s+([^;.\\n]+)", options: [.caseInsensitive])
    // swiftlint:enable force_try

    private static func tierRegex(_ tier: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\b\(tier)\\s+notes?\\s*(?:are|is|include[s]?|:)?\\s+([^;.\\n]+)", options: [.caseInsensitive])
    }

    static func parse(fromText text: String) -> Pyramid? {
        var pyramid = Pyramid()
        pyramid.top = noteList(topRegex, in: text)
        pyramid.heart = noteList(heartRegex, in: text)
        pyramid.base = noteList(baseRegex, in: text)
        if pyramid.top.isEmpty, pyramid.heart.isEmpty, pyramid.base.isEmpty {
            // The untiered forms: the site template first, then prose.
            pyramid.flat = noteList(featuresRegex, in: text)
            if pyramid.flat.isEmpty { pyramid.flat = noteList(flatRegex, in: text) }
        }
        return pyramid.isEmpty ? nil : pyramid
    }

    /// The first capture of `regex` that reads as a note list, split; empty
    /// when none of the inspected hits does.
    private static func noteList(_ regex: NSRegularExpression, in text: String) -> [String] {
        var items: [String] = []
        var inspected = 0
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            inspected += 1
            if inspected > maxMatchesPerPattern {
                stop.pointee = true
                return
            }
            guard let match, match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return }
            // A list the page cut short ("Papyru...") is not the list; the
            // body repeats it in full further down.
            let continuation = text[range.upperBound...].prefix(3)
            guard !continuation.hasPrefix("..."), !continuation.hasPrefix("…") else { return }
            let candidate = splitNoteList(String(text[range]).trimmingCharacters(in: .whitespaces))
            guard isNoteList(candidate) else { return }
            items = candidate
            stop.pointee = true
        }
        return items
    }

    /// Prose fails this and a note list passes: every item is short and
    /// carries no digit ("a bit harsh for the first 10 minutes" is a
    /// review, "Virginia Cedar" a note).
    private static func isNoteList(_ items: [String]) -> Bool {
        !items.isEmpty && items.allSatisfy { item in
            item.rangeOfCharacter(from: .decimalDigits) == nil
                && item.split(whereSeparator: \.isWhitespace).count <= maxWordsPerNote
        }
    }

    /// Splits "Bergamot, Lemon and Neroli" into its notes, tolerating an
    /// Oxford comma and multi-word note names ("Ylang-Ylang", "Tonka Bean").
    private static func splitNoteList(_ list: String) -> [String] {
        list.replacingOccurrences(of: ", and ", with: ", ")
            .replacingOccurrences(of: " and ", with: ", ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension ELVNativeOps {
    static func registerNotePyramidOp() {
        register("notePyramid.fromProse", version: 1) { input, context in
            let text = input["text"] ?? context.document.text
                ?? context.document.metas["og:description"] ?? context.document.metas["description"]
            guard let text, let pyramid = ELVNotePyramid.parse(fromText: text) else { return nil }
            var outputs: [String: ELVValue] = [:]
            if !pyramid.top.isEmpty { outputs["top"] = .tags(pyramid.top) }
            if !pyramid.heart.isEmpty { outputs["heart"] = .tags(pyramid.heart) }
            if !pyramid.base.isEmpty { outputs["base"] = .tags(pyramid.base) }
            if !pyramid.flat.isEmpty { outputs["notes"] = .tags(pyramid.flat) }
            return outputs.isEmpty ? nil : outputs
        }
    }
}
