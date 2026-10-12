import Foundation

/// Bounded compile cache for pack-supplied regex patterns. `NSRegularExpression`
/// compilation is expensive and the extraction hot path evaluates the same
/// pack pattern once per candidate per record; patterns are pack-authored
/// strings, so a per-pattern cache (not a per-site `static let`) is the
/// shape. `NSRegularExpression` is immutable and thread-safe, so handing
/// instances out of the lock is sound.
public enum ELVRegexCache {
    /// The input bound every pack-regex evaluation applies, in characters:
    /// a catastrophic-backtracking pack pattern over a multi-MB body must be
    /// an extraction miss, not a hang. Matches past the cap are misses.
    public static let inputCap = 262_144

    /// Distinct-pattern capacity. The starter pack alone compiles ~70
    /// distinct patterns, and the dynamic keys (per-island script ids,
    /// per-tag close patterns) add more; 256 keeps a whole pack's working set
    /// resident instead of thrashing at the boundary.
    private static let cache = ELVBoundedCache<String, NSRegularExpression?>(capacity: 256)

    /// The compiled regex for `pattern`, or nil when the pattern is invalid.
    /// Invalid patterns are cached as negative entries: a pack typo is
    /// evaluated on every candidate otherwise, and the failing compile costs
    /// as much as a successful one.
    public static func regex(_ pattern: String) -> NSRegularExpression? {
        cache.value(for: pattern) { try? NSRegularExpression(pattern: pattern) }
    }

    /// Whether `pattern` matches anywhere in the first `cap` characters of
    /// `string`.
    public static func matches(_ pattern: String, in string: String, cap: Int = inputCap) -> Bool {
        guard let regex = regex(pattern) else { return false }
        let bounded = boundedInput(string, cap: cap)
        return regex.firstMatch(in: bounded, range: NSRange(bounded.startIndex..., in: bounded)) != nil
    }

    /// `string` cut to `cap` characters when its UTF-8 length exceeds the
    /// cap. The trigger tests `utf8.count` (O(1) on native strings) rather
    /// than `count`, which grapheme-walks the whole body before the cap can
    /// help; the result is identical because `utf8.count >= count`.
    public static func boundedInput(_ string: String, cap: Int = inputCap) -> String {
        string.utf8.count > cap ? String(string.prefix(cap)) : string
    }

    /// Applies a whole-value rewrite (`regexReplace`, `htmlStrip`,
    /// `rewriteLazyImages`) to the first `cap` characters of `string` and
    /// keeps the remainder verbatim, so bounding the scan never truncates
    /// the value. One cut, shared by every rewriting pipe.
    static func rewritingBoundedHead(of string: String, cap: Int = inputCap, _ rewrite: (String) -> String) -> String {
        guard string.utf8.count > cap, let cut = string.index(string.startIndex, offsetBy: cap, limitedBy: string.endIndex) else {
            return rewrite(string)
        }
        return rewrite(String(string[..<cut])) + string[cut...]
    }

    /// The wall-clock budget of one pack-regex evaluation over page-sized
    /// text. The input cap bounds how much a pattern reads, not what it
    /// costs: a pattern that backtracks quadratically still runs for minutes
    /// over a capped hostile body. An evaluation that runs out is a miss
    /// (a rewrite leaves its text unchanged), never a hang.
    public static let evaluationBudget: Duration = .seconds(2)

    /// Up to `limit` matches of `regex` in `string`, or nil when the scan ran
    /// out of `budget`. `.reportProgress` makes ICU call the block
    /// periodically inside a single long match attempt too, which is what
    /// lets a catastrophic backtrack stop at the deadline.
    static func boundedMatches(
        of regex: NSRegularExpression,
        in string: String,
        limit: Int = .max,
        budget: Duration = evaluationBudget
    ) -> [NSTextCheckingResult]? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        var results: [NSTextCheckingResult] = []
        var timedOut = false
        regex.enumerateMatches(in: string, options: .reportProgress, range: NSRange(location: 0, length: (string as NSString).length)) { match, _, stop in
            if let match {
                results.append(match)
                if results.count >= limit {
                    stop.pointee = true
                    return
                }
            }
            if clock.now >= deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        return timedOut ? nil : results
    }

    /// `stringByReplacingMatches(in:range:withTemplate:)` under the same
    /// budget, or nil when the scan ran out.
    static func boundedReplacing(_ regex: NSRegularExpression, in string: String, template: String, budget: Duration = evaluationBudget) -> String? {
        guard let matches = boundedMatches(of: regex, in: string, budget: budget) else { return nil }
        guard !matches.isEmpty else { return string }
        let result = NSMutableString(string: string)
        // Templates read their groups from the original string (offset 0);
        // `shift` tracks how far earlier replacements moved the output.
        var shift = 0
        for match in matches {
            let replacement = regex.replacementString(for: match, in: string, offset: 0, template: template)
            result.replaceCharacters(in: NSRange(location: match.range.location + shift, length: match.range.length), with: replacement)
            shift += (replacement as NSString).length - match.range.length
        }
        return result as String
    }
}
