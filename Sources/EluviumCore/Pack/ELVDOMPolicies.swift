import Foundation

/// A settle policy: the DOM engine waits for stability AND at least one
/// content signal before extracting. Stability alone is not enough (a
/// hydrating SPA sits idle with metas present but nothing rendered) and a
/// content signal alone is not enough (a challenge shell sits stable and
/// empty for 10s+), so both are required. A source whose pages publish none
/// of the defaults declares its own; a CSS selector counts as a signal.
/// Pack-schema type (decoded from fetch steps), which is why it lives in
/// Pack/ beside its siblings.
public struct ELVSettlePolicy: Sendable, Decodable, Equatable {
    /// Signals, any one of which (present in the DOM) satisfies the content
    /// requirement: the literals `h1`, `jsonld`, `og:title`, or any CSS
    /// selector.
    public var signals: [String]
    public var pollSeconds: Double
    public var maxPolls: Int

    public init(signals: [String] = ["h1", "jsonld", "og:title"], pollSeconds: Double = 1, maxPolls: Int = 25) {
        self.signals = signals.isEmpty ? ["h1", "jsonld", "og:title"] : signals
        // Clamped on both sides: a pack's 1e300 would trap the renderer's
        // nanosecond conversion (NaN is safe — max(0.1, .nan) is 0.1).
        self.pollSeconds = min(max(0.1, pollSeconds), 10)
        self.maxPolls = max(1, min(maxPolls, 60))
    }

    private enum CodingKeys: String, CodingKey {
        case signals, pollSeconds, maxPolls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let signals = try container.elvStringList(forKey: .signals)
        let pollSeconds = try container.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? 1
        let maxPolls = try container.decodeIfPresent(Int.self, forKey: .maxPolls) ?? 25
        self.init(signals: signals, pollSeconds: pollSeconds, maxPolls: maxPolls)
    }
}

/// Canonical-URL capture: the iOS Google Maps share expands to a URL
/// with no coordinate anywhere a fetch can see; Google materializes the pin
/// client-side and rewrites the address bar. The webview watches its own
/// `url` until a declared predicate matches, then re-enters recognition.
public struct ELVCanonicalCapture: Sendable, Decodable, Equatable {
    /// A regex over the live URL; when it matches, the canonical URL is
    /// captured.
    public var untilURLRegex: String
    public var maxPolls: Int

    public init(untilURLRegex: String, maxPolls: Int = 20) {
        self.untilURLRegex = untilURLRegex
        self.maxPolls = max(1, min(maxPolls, 40))
    }

    private enum CodingKeys: String, CodingKey {
        case until
        case maxPolls
    }

    private enum UntilKeys: String, CodingKey {
        case urlRegex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` like every sibling nested-container decode: a malformed
        // capture drops the capture, never the whole source.
        guard let until = try? container.nestedContainer(keyedBy: UntilKeys.self, forKey: .until),
              let regex = try? until.decode(String.self, forKey: .urlRegex)
        else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "captureCanonical requires until.urlRegex"
            ))
        }
        try self.init(untilURLRegex: regex, maxPolls: container.decodeIfPresent(Int.self, forKey: .maxPolls) ?? 20)
    }
}
