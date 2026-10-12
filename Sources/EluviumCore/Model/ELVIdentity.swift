import Foundation

/// How an identity landed on a record. The origin decides linking
/// rights: declared and crosswalk identities in strong namespaces auto-link;
/// heuristic identities are suggestions until a consumer confirms them.
public enum ELVIdentityOrigin: Sendable, Equatable, Hashable {
    /// Extracted from the source's own page or row (a Douban page printing
    /// its IMDb id; an export column that is the id).
    case declared
    /// Emitted by a hub source (e.g. Wikidata) about another namespace.
    case crosswalk(via: String)
    /// A scored match. A suggestion until confirmed — never auto-links.
    case heuristic(confidence: Double)
    /// An origin kind written by a newer binary. Never links (the
    /// fail-safe) and re-encodes as the original token, so a round trip
    /// through this binary does not rewrite future origin kinds. Only the
    /// `kind` token is preserved; a future origin's sibling payload keys
    /// are dropped on re-encode — origins are advisory metadata, so this
    /// stays acceptable where it would not be for `ELVValue`.
    case unknown(raw: String)
}

/// A cross-source identity key: "this record is `tt0076759` in the `imdb`
/// namespace". The same real-world thing reached through different
/// sources is linkable through shared identities without merging the lists
/// it appears on.
public struct ELVIdentity: Sendable, Codable, Equatable, Hashable {
    /// Identity namespace, e.g. `imdb`, `wikidata`, `douban.film`,
    /// `fsq.venue`, `isbn13`, `podcast.guid`. Namespaces live in the pack
    /// vocabulary and are append-only.
    public var namespace: String
    /// The key within the namespace, e.g. `tt0076759`.
    public var value: String
    public var origin: ELVIdentityOrigin

    public init(namespace: String, value: String, origin: ELVIdentityOrigin = .declared) {
        self.namespace = namespace
        self.value = value
        self.origin = origin
    }
}

// MARK: - Codable

extension ELVIdentityOrigin: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case via
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "declared":
            self = .declared
        case "crosswalk":
            self = try .crosswalk(via: container.decode(String.self, forKey: .via))
        case "heuristic":
            self = try .heuristic(confidence: container.decode(Double.self, forKey: .confidence))
        default:
            // Fail safe for origins written by a newer binary: never links,
            // and keeps the original token instead of permanently rewriting
            // it to "heuristic" on the next encode.
            self = .unknown(raw: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .declared:
            try container.encode("declared", forKey: .kind)
        case let .crosswalk(via):
            try container.encode("crosswalk", forKey: .kind)
            try container.encode(via, forKey: .via)
        case let .heuristic(confidence):
            try container.encode("heuristic", forKey: .kind)
            try container.encode(confidence, forKey: .confidence)
        case let .unknown(raw):
            try container.encode(raw, forKey: .kind)
        }
    }
}
