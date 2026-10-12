import Foundation

/// A string transform in a candidate's pipeline. Encoded as a bare
/// string (`"trim"`) or a single-key object with an argument
/// (`{"stripSuffix": " | AllTrails"}`). An unrecognized pipe decodes to
/// `.unsupported` and invalidates its candidate.
public enum ELVPipe: Sendable, Equatable {
    case trim
    case collapseWhitespace
    case decodeEntities
    case decodePercent
    case slugToTitle
    case capitalizeFirst
    case lower
    case upper
    case stripPrefix(String)
    case stripSuffix(String)
    case regexReplace(pattern: String, template: String)
    case split(String)
    case join(String)
    case first
    case last
    case take(Int)
    /// Resolves a relative URL string against the input URL. http(s) only,
    /// via `ELVURLPolicy`.
    case resolveURL
    /// Substitutes a default when the value is empty.
    case defaultValue(String)
    /// Removes elements matching simple selectors (`tag`, `.class`, `#id`,
    /// `tag.class`) from an HTML value — the ftr-strip / Miniflux-rules
    /// class of content cleanup.
    case htmlStrip([String])
    /// Rewrites lazy-loaded `<img data-src=…>` tags so images render
    /// without the page's JS.
    case rewriteLazyImages
    case unsupported(name: String)

    /// Applies this pipe. `nil` invalidates the candidate.
    func apply(_ value: ELVExtractedValue, context: ELVExtractionContext) -> ELVExtractedValue? {
        if let transform = stringTransform {
            return value.mapStrings(transform)
        }
        return applyStructural(value, context: context)
    }

    // The one whitespace-run pattern, compiled once: the
    // `range(of:options:.regularExpression)` string API compiles a throwaway
    // regex per string. Fixed pattern, so a `static let` (not the
    // pack-pattern cache) is the shape; a compile failure is a programmer
    // error, same convention as `ELVHTMLScanner`'s static patterns.
    // swiftlint:disable:next force_try
    private static let whitespaceRunPattern = try! NSRegularExpression(pattern: "\\s+")

    /// Per-string transforms, applied uniformly across single and list
    /// values. Pipes that can fail or reshape the value are not in here.
    private var stringTransform: ((String) -> String)? {
        switch self {
        case .trim:
            { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        case .collapseWhitespace:
            { string in
                Self.whitespaceRunPattern.stringByReplacingMatches(
                    in: string,
                    range: NSRange(string.startIndex..., in: string),
                    withTemplate: " "
                )
            }
        case .decodeEntities:
            { ELVEntityDecoder.decode($0) }
        case .decodePercent:
            { $0.removingPercentEncoding ?? $0 }
        case .slugToTitle:
            { slug in
                slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
            }
        case .capitalizeFirst:
            { $0.isEmpty ? $0 : $0.prefix(1).uppercased() + $0.dropFirst() }
        case .lower:
            { $0.lowercased() }
        case .upper:
            { $0.uppercased() }
        case let .stripPrefix(prefix):
            { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
        case let .stripSuffix(suffix):
            { $0.hasSuffix(suffix) ? String($0.dropLast(suffix.count)) : $0 }
        case let .htmlStrip(selectors):
            { ELVHTMLCleanup.strip($0, selectors: selectors) }
        case .rewriteLazyImages:
            { ELVHTMLCleanup.rewriteLazyImages($0) }
        default:
            nil
        }
    }

    /// Pipes that reshape the value, read the context, or can fail.
    private func applyStructural(_ value: ELVExtractedValue, context: ELVExtractionContext) -> ELVExtractedValue? {
        switch self {
        case let .regexReplace(pattern, template):
            // Pack patterns apply per element for list values: the compile
            // goes through the bounded cache, and the regex runs over at
            // most `ELVRegexCache.inputCap` characters like every pack-regex
            // evaluation (a content field can be a whole article body). The
            // remainder past the cap is kept verbatim, so bounding the scan
            // never truncates the value. A scan that runs out of the
            // evaluation budget leaves its text unchanged.
            guard let regex = ELVRegexCache.regex(pattern) else { return nil }
            return value.mapStrings { string in
                ELVRegexCache.rewritingBoundedHead(of: string) { bounded in
                    ELVRegexCache.boundedReplacing(regex, in: bounded, template: template) ?? bounded
                }
            }
        case let .split(separator):
            guard let string = value.singleString else { return nil }
            return .list(string.components(separatedBy: separator))
        case let .join(separator):
            return .string(value.strings.joined(separator: separator))
        case .first:
            guard let first = value.strings.first else { return nil }
            return .string(first)
        case .last:
            guard let last = value.strings.last else { return nil }
            return .string(last)
        case let .take(count):
            guard count > 0 else { return nil }
            return .list(Array(value.strings.prefix(count)))
        case .resolveURL:
            // Through the one scheme-allowlisted resolution: without it a
            // `javascript:`/`data:` string rides into any `.text` field the
            // pipe feeds, not just URL-coerced ones.
            guard let string = value.singleString,
                  let resolved = ELVURLPolicy.resolve(string, relativeTo: context.url) else { return nil }
            return .string(resolved.absoluteString)
        case let .defaultValue(fallback):
            return value.strings.allSatisfy(\.isEmpty) ? .string(fallback) : value
        default:
            return nil
        }
    }
}

extension ELVPipe: Decodable {
    private static let bareNames: [String: ELVPipe] = [
        "trim": .trim, "collapseWhitespace": .collapseWhitespace, "decodeEntities": .decodeEntities,
        "decodePercent": .decodePercent, "slugToTitle": .slugToTitle, "capitalizeFirst": .capitalizeFirst,
        "lower": .lower, "upper": .upper, "first": .first, "last": .last, "resolveURL": .resolveURL,
        "rewriteLazyImages": .rewriteLazyImages,
    ]

    /// Decoding never throws: a malformed pipe — wrong container
    /// shape, several keys, a wrong-typed payload — degrades to
    /// `.unsupported` so it invalidates only its candidate, and the pack
    /// validator reports it.
    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self = Self.bareNames[name] ?? .unsupported(name: name)
            return
        }
        guard let container = try? decoder.container(keyedBy: ELVDynamicKey.self) else {
            self = .unsupported(name: "(malformed)")
            return
        }
        let keys = container.allKeys.map(\.stringValue)
        guard keys.count == 1, let key = keys.first else {
            self = .unsupported(name: keys.isEmpty ? "(empty)" : keys.sorted().joined(separator: "+"))
            return
        }
        func value() -> String? {
            try? container.decode(String.self, forKey: .init(key))
        }
        switch key {
        case "stripPrefix": self = value().map { .stripPrefix($0) } ?? .unsupported(name: key)
        case "stripSuffix": self = value().map { .stripSuffix($0) } ?? .unsupported(name: key)
        case "split": self = value().map { .split($0) } ?? .unsupported(name: key)
        case "join": self = value().map { .join($0) } ?? .unsupported(name: key)
        case "take": self = (try? container.decode(Int.self, forKey: .init(key))).map { .take($0) } ?? .unsupported(name: key)
        case "default": self = value().map { .defaultValue($0) } ?? .unsupported(name: key)
        case "htmlStrip": self = (try? container.decode([String].self, forKey: .init(key))).map { .htmlStrip($0) } ?? .unsupported(name: key)
        case "regexReplace":
            // One spelling: the `["pattern", "template"]` pair.
            if let parts = try? container.decode([String].self, forKey: .init(key)), parts.count == 2 {
                self = .regexReplace(pattern: parts[0], template: parts[1])
            } else {
                self = .unsupported(name: key)
            }
        default:
            self = .unsupported(name: key)
        }
    }
}
