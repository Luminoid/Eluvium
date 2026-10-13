import Foundation

/// A source as the matcher sees it: an id plus its match rule. The full
/// source definition (fetch plan, fields, …) lives in the pack layer.
public struct ELVMatchableSource: Sendable, Equatable {
    public var id: String
    public var match: ELVMatchRule

    public init(id: String, match: ELVMatchRule) {
        self.id = id
        self.match = match
    }
}

/// Stage ① for URL inputs: match a URL against the registry and return the
/// winning source with captured params.
public struct ELVRecognition: Sendable, Equatable {
    public var sourceId: String
    /// Named path params (`url.param.<name>` downstream).
    public var params: [String: String]
    public var priority: Int

    public init(sourceId: String, params: [String: String] = [:], priority: Int = 0) {
        self.sourceId = sourceId
        self.params = params
        self.priority = priority
    }
}

/// The source registry: exact host rules first, highest `priority` wins,
/// declaration order breaks ties (pack order is deterministic).
/// Generic platform fingerprints probe the network and live in the
/// fetch layer; this registry is the pure, offline half of recognition.
public struct ELVSourceRegistry: Sendable {
    /// A source with its path patterns compiled at construction: the
    /// registry answers every recognition, and the pattern strings never
    /// change after load.
    private struct Entry {
        let source: ELVMatchableSource
        let paths: [ELVPathPattern]
    }

    private let entries: [Entry]

    public init(sources: [ELVMatchableSource]) {
        entries = sources.map { Entry(source: $0, paths: $0.match.paths.map { ELVPathPattern($0) }) }
    }

    /// All sources matching `url`, best first. A web URL matches host and
    /// brand rules; any other scheme matches only scheme rules (an app link
    /// like `comgooglemaps://?q=…` has no host to match).
    public func candidates(for url: URL) -> [ELVRecognition] {
        let scheme = url.scheme?.lowercased() ?? ""
        let isWeb = scheme == "http" || scheme == "https"
        let host = url.host?.lowercased() ?? ""
        guard isWeb ? !host.isEmpty : !scheme.isEmpty else { return [] }
        var matches: [(order: Int, recognition: ELVRecognition)] = []
        for (order, entry) in entries.enumerated() {
            let rule = entry.source.match
            let matched = if isWeb {
                rule.hosts.contains { ELVHostMatcher.hostMatches(host, pattern: $0) }
                    || rule.brands.contains { ELVHostMatcher.hostMatchesBrand(host, brand: $0) }
            } else {
                rule.schemes.contains(scheme)
            }
            guard matched else { continue }

            var params: [String: String] = [:]
            if !entry.paths.isEmpty {
                guard let captured = entry.paths.lazy.compactMap({ $0.match(path: url.path) }).first else { continue }
                params = captured
            }
            matches.append((order, ELVRecognition(sourceId: entry.source.id, params: params, priority: rule.priority)))
        }
        return matches
            .sorted { ($0.recognition.priority, $1.order) > ($1.recognition.priority, $0.order) }
            .map(\.recognition)
    }

    /// The single best match for `url`, or `nil` when nothing matches.
    public func recognize(_ url: URL) -> ELVRecognition? {
        candidates(for: url).first
    }
}
