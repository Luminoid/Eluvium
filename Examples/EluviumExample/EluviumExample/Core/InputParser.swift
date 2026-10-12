import Foundation

/// Pulls the first URL out of a paste, tolerating a share blurb around it
/// (pasted-text input, the simple half).
enum InputParser {
    // Compiled once (the static-pattern rule): NSDataDetector construction
    // is expensive and this runs on every paste.
    // swiftlint:disable:next force_try
    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func firstURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = normalized(trimmed) { return direct }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = linkDetector.firstMatch(in: trimmed, range: range), let url = match.url, url.scheme?.hasPrefix("http") == true {
            return url
        }
        // Fall back to the first whitespace-delimited token that parses.
        return trimmed.split(whereSeparator: \.isWhitespace).lazy.compactMap { normalized(String($0)) }.first
    }

    private static func normalized(_ token: String) -> URL? {
        guard let url = URL(string: token), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}
