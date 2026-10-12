import Foundation

/// A URL path pattern with named parameters:
/// `/trail/:country/:region/:slug` matches
/// `/trail/us/wyoming/hidden-falls-trail` and captures the three params.
///
/// Segments are matched literally (case-insensitive), `:name` captures one
/// non-empty segment, `@:name` (any literal glued to a `:capture`) captures
/// the remainder after the literal prefix (`/@:handle` matches `/@apple`,
/// capturing `handle = "apple"` — the YouTube/Mastodon handle shape;
/// additive at schemaMinor 2), `*` matches one segment without capturing,
/// and a trailing `**` matches any remainder (including none).
public struct ELVPathPattern: Sendable, Equatable {
    private enum Segment: Equatable {
        case literal(String)
        case parameter(String)
        case prefixedParameter(prefix: String, name: String)
        case wildcard
        case rest
    }

    private let segments: [Segment]
    public let pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
        segments = pattern.split(separator: "/").map { raw in
            let segment = String(raw)
            if segment == "**" { return .rest }
            if segment == "*" { return .wildcard }
            if segment.hasPrefix(":"), segment.count > 1 { return .parameter(String(segment.dropFirst())) }
            if let colon = segment.firstIndex(of: ":"), colon != segment.startIndex, segment.index(after: colon) < segment.endIndex {
                return .prefixedParameter(prefix: String(segment[..<colon]).lowercased(), name: String(segment[segment.index(after: colon)...]))
            }
            return .literal(segment.lowercased())
        }
    }

    /// Matches `path` and returns captured params, or `nil` on mismatch.
    /// Percent-encoding is decoded in captured values.
    public func match(path: String) -> [String: String]? {
        let pathSegments = path.split(separator: "/").map(String.init)
        var params: [String: String] = [:]
        var pathIndex = 0

        for (index, segment) in segments.enumerated() {
            if case .rest = segment {
                // A trailing `**` swallows the remainder; params so far stand.
                return index == segments.count - 1 ? params : nil
            }
            guard pathIndex < pathSegments.count else { return nil }
            let candidate = pathSegments[pathIndex]
            switch segment {
            case let .literal(literal):
                guard candidate.lowercased() == literal else { return nil }
            case let .parameter(name):
                guard !candidate.isEmpty else { return nil }
                params[name] = candidate.removingPercentEncoding ?? candidate
            case let .prefixedParameter(prefix, name):
                guard candidate.lowercased().hasPrefix(prefix), candidate.count > prefix.count else { return nil }
                let value = String(candidate.dropFirst(prefix.count))
                params[name] = value.removingPercentEncoding ?? value
            case .wildcard:
                break
            case .rest:
                preconditionFailure("Handled above")
            }
            pathIndex += 1
        }
        guard pathIndex == pathSegments.count else { return nil }
        return params
    }
}
