import Foundation
import Synchronization

/// The append-only strong-namespace registry. A namespace being
/// strong means two records sharing any `(namespace, value)` pair in it are
/// the same real-world thing and auto-link. The bit only ever goes from
/// unset to strong — a demotion would retroactively dissolve entities users
/// have built views on.
public enum ELVIdentityNamespaces {
    /// Binary-owned base set. Packs may add namespaces through their
    /// `strongNamespaces` key (`ELVLoadedPack.strongNamespaces`, fed to
    /// `ELVEntityIndex.addStrongNamespaces`); they can never remove one. The
    /// `aliasOf` rename table is not implemented: a renamed namespace
    /// is simply a new one.
    public static let builtinStrong: Set<String> = [
        "imdb", "wikidata", "tmdb.movie", "tmdb.person", "douban.film",
        "isbn10", "isbn13", "gtin", "fsq.venue",
        "podcast.guid", "itunes.podcast",
        "pokeapi.pokemon", "themeparks.entity", "alltrails.trail",
        // eBird's species code is the one key Merlin, All About Birds, and
        // eBird all print; iNaturalist ids are the same id on every network
        // host and in the user's own observation export.
        "ebird.species", "inat.taxon", "inat.observation",
    ]

    /// Namespace families where every member is strong (`musicbrainz.artist`,
    /// `musicbrainz.release`, …).
    static let builtinStrongPrefixes: [String] = ["musicbrainz."]

    public static func isStrong(_ namespace: String, extra: Set<String> = []) -> Bool {
        if builtinStrong.contains(namespace) || extra.contains(namespace) { return true }
        return builtinStrongPrefixes.contains { namespace.hasPrefix($0) }
    }
}

/// The stable handle of an indexed record: `sourceId` + `externalId`.
/// Records without an `externalId` have no stable handle and cannot join
/// the entity graph.
public struct ELVRecordKey: Sendable, Codable, Equatable, Hashable, Comparable {
    public var sourceId: String
    public var externalId: String

    public init(sourceId: String, externalId: String) {
        self.sourceId = sourceId
        self.externalId = externalId
    }

    public init?(_ record: ELVRecord) {
        guard let externalId = record.externalId, !externalId.isEmpty else { return nil }
        self.init(sourceId: record.sourceId, externalId: externalId)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.sourceId, lhs.externalId) < (rhs.sourceId, rhs.externalId)
    }

    var storageKey: String { "\(sourceId)|\(externalId)" }

    init?(storageKey: String) {
        // Split on the LAST separator: sourceIds are pack-authored strings
        // that may themselves carry "|". The cost is the mirror-image
        // ambiguity — an externalId containing "|" under a "|"-free sourceId
        // mis-splits — which is unresolvable without escaping; the
        // pack-authored side is the one the format keeps exact.
        guard let separator = storageKey.lastIndex(of: "|") else { return nil }
        sourceId = String(storageKey[..<separator])
        externalId = String(storageKey[storageKey.index(after: separator)...])
    }
}

/// A computed entity: the records that are one real-world thing, reached
/// through shared strong identities and confirmed links. A view over the
/// index — never a stored merged record (linking is an overlay).
public struct ELVEntity: Sendable, Equatable {
    /// Member record keys, sorted for determinism.
    public var members: [ELVRecordKey]
    /// The union of members' identities, deduplicated.
    public var identities: [ELVIdentity]
}

/// A persisted rejection: vetoes outrank crosswalks and stop a
/// heuristic suggestion from resurrecting on every re-import.
public struct ELVIdentityVeto: Sendable, Codable, Equatable, Hashable {
    /// The record the wrong identity landed on.
    public var record: ELVRecordKey
    public var namespace: String
    public var value: String

    public init(record: ELVRecordKey, namespace: String, value: String) {
        self.record = record
        self.namespace = namespace
        self.value = value
    }
}

/// A persisted record-pair decision: a confirmed heuristic link, or a
/// rejected suggestion. Stored with the pair normalized (a ≤ b).
public struct ELVRecordPair: Sendable, Codable, Equatable, Hashable {
    public var a: ELVRecordKey
    public var b: ELVRecordKey

    public init(_ first: ELVRecordKey, _ second: ELVRecordKey) {
        if first <= second {
            a = first
            b = second
        } else {
            a = second
            b = first
        }
    }
}

/// The cross-source identity index: identity → entity, union-find
/// style, with declared/crosswalk identities in strong namespaces linking
/// automatically, heuristics linking only when confirmed, and vetoes
/// persisting. `Codable`, `formatVersion`-ed, and unknown-preserving like
/// every persisted Eluvium shape.
public struct ELVEntityIndex: Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// Registered identities per record key (linking and display both).
    public private(set) var identitiesByRecord: [ELVRecordKey: [ELVIdentity]]
    /// Strong namespaces added by pack vocabulary (append-only).
    public private(set) var extraStrongNamespaces: Set<String>
    /// Keys written by a newer binary, preserved verbatim.
    public var unknown: [String: ELVRawJSON]

    /// Decisions are Set-backed: `contains` runs inside the per-identity
    /// linking loop, so membership must be O(1).
    private var confirmedLinkSet: Set<ELVRecordPair>
    private var pairVetoSet: Set<ELVRecordPair>
    private var identityVetoSet: Set<ELVIdentityVeto>

    /// Memoized connected components and the lookups derived from them.
    /// Every mutation that can change linking installs a *fresh* box rather
    /// than clearing the shared one, so a copied index keeps its still-valid
    /// cache (value semantics hold).
    private var componentsCache = ELVEntityComponentsCache()

    /// Confirmed links, deterministically ordered.
    public var confirmedLinks: [ELVRecordPair] {
        confirmedLinkSet.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
    }

    /// Rejected pairs, deterministically ordered.
    public var pairVetoes: [ELVRecordPair] {
        pairVetoSet.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
    }

    /// Severed identities, deterministically ordered.
    public var identityVetoes: [ELVIdentityVeto] {
        identityVetoSet.sorted { ($0.record, $0.namespace, $0.value) < ($1.record, $1.namespace, $1.value) }
    }

    public init(extraStrongNamespaces: Set<String> = []) {
        formatVersion = Self.currentFormatVersion
        identitiesByRecord = [:]
        confirmedLinkSet = []
        pairVetoSet = []
        identityVetoSet = []
        self.extraStrongNamespaces = extraStrongNamespaces
        unknown = [:]
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.formatVersion == rhs.formatVersion
            && lhs.identitiesByRecord == rhs.identitiesByRecord
            && lhs.confirmedLinkSet == rhs.confirmedLinkSet
            && lhs.pairVetoSet == rhs.pairVetoSet
            && lhs.identityVetoSet == rhs.identityVetoSet
            && lhs.extraStrongNamespaces == rhs.extraStrongNamespaces
            && lhs.unknown == rhs.unknown
    }

    // MARK: - Registration

    /// Registers (or re-registers) a record's identities. Idempotent:
    /// re-importing the same record replaces its identity set.
    public mutating func register(_ record: ELVRecord) {
        guard let key = ELVRecordKey(record) else { return }
        register(key: key, identities: record.identities)
    }

    public mutating func register(key: ELVRecordKey, identities: [ELVIdentity]) {
        var deduplicated: [ELVIdentity] = []
        for identity in identities where !deduplicated.contains(identity) {
            deduplicated.append(identity)
        }
        identitiesByRecord[key] = deduplicated
        componentsCache = ELVEntityComponentsCache()
    }

    public mutating func unregister(_ key: ELVRecordKey) {
        identitiesByRecord.removeValue(forKey: key)
        componentsCache = ELVEntityComponentsCache()
    }

    /// Grows the strong-namespace set (pack vocabulary). Append-only by
    /// construction: there is no removal API. Hosts call it with each loaded
    /// pack's set, `index.addStrongNamespaces(pack.strongNamespaces)`, after
    /// every load or merge; the set persists with the index.
    public mutating func addStrongNamespaces(_ namespaces: some Sequence<String>) {
        extraStrongNamespaces.formUnion(namespaces)
        componentsCache = ELVEntityComponentsCache()
    }

    // MARK: - Decisions

    /// Confirms a suggested link between two records. Overrides an earlier
    /// rejection of the same pair.
    public mutating func confirmLink(_ first: ELVRecordKey, _ second: ELVRecordKey) {
        let pair = ELVRecordPair(first, second)
        pairVetoSet.remove(pair)
        confirmedLinkSet.insert(pair)
        componentsCache = ELVEntityComponentsCache()
    }

    /// Rejects a suggested link. Persists so the suggestion cannot
    /// resurrect on re-import; removes an earlier confirmation.
    ///
    /// A pair veto cuts only a confirmed link. Records that share a linking
    /// strong identity (or reach each other through other records) stay one
    /// entity, so the veto is stored but cannot separate them: the result is
    /// `false` then, and the caller severs the shared identity with
    /// `vetoIdentity` instead. `true` means the two are apart afterwards.
    @discardableResult
    public mutating func vetoLink(_ first: ELVRecordKey, _ second: ELVRecordKey) -> Bool {
        let pair = ELVRecordPair(first, second)
        confirmedLinkSet.remove(pair)
        pairVetoSet.insert(pair)
        componentsCache = ELVEntityComponentsCache()
        return entity(for: first)?.members.contains(second) != true
    }

    /// Severs one identity on one record — the recovery for a wrong
    /// crosswalk (Wikidata does carry occasional wrong external ids). The
    /// identity stays visible on the record; it just stops linking.
    public mutating func vetoIdentity(record: ELVRecordKey, namespace: String, value: String) {
        identityVetoSet.insert(ELVIdentityVeto(record: record, namespace: namespace, value: value))
        componentsCache = ELVEntityComponentsCache()
    }

    // MARK: - Queries

    /// The entity containing `key`, or a singleton entity when nothing
    /// links to it. `nil` when the key is unregistered.
    public func entity(for key: ELVRecordKey) -> ELVEntity? {
        guard identitiesByRecord[key] != nil else { return nil }
        let computed = componentsCache.computed(computeComponents)
        let members = computed.componentIndex[key].map { computed.components[$0] } ?? [key]
        return makeEntity(members: members)
    }

    /// Every entity, singletons included, deterministically ordered by
    /// their first member. Memoized per mutation generation like the
    /// components it derives from.
    public func entities() -> [ELVEntity] {
        if let cached = componentsCache.cachedEntities { return cached }
        let placeholder = ELVRecordKey(sourceId: "", externalId: "")
        let entities = componentsCache.computed(computeComponents).components
            .map(makeEntity(members:))
            .sorted { ($0.members.first ?? placeholder) < ($1.members.first ?? placeholder) }
        return componentsCache.store(entities: entities)
    }

    /// Whether an identity is eligible to auto-link from this record:
    /// strong namespace, declared or crosswalk origin, and not vetoed.
    func isLinking(_ identity: ELVIdentity, on key: ELVRecordKey) -> Bool {
        switch identity.origin {
        case .declared, .crosswalk:
            break
        case .heuristic, .unknown:
            // Heuristics link only through confirmation; an origin written
            // by a newer binary is unjudgeable here, so it never auto-links.
            return false
        }
        guard ELVIdentityNamespaces.isStrong(identity.namespace, extra: extraStrongNamespaces) else { return false }
        return !identityVetoSet.contains(ELVIdentityVeto(record: key, namespace: identity.namespace, value: identity.value))
    }

    // MARK: - Component computation

    /// Connected components over record nodes: records share an edge when
    /// they share a linking identity key or a confirmed pair.
    private func computeComponents() -> [Set<ELVRecordKey>] {
        var parent: [ELVRecordKey: ELVRecordKey] = [:]
        for key in identitiesByRecord.keys {
            parent[key] = key
        }

        func find(_ key: ELVRecordKey) -> ELVRecordKey {
            var root = key
            while let next = parent[root], next != root {
                root = next
            }
            var current = key
            while let next = parent[current], next != root {
                parent[current] = root
                current = next
            }
            return root
        }
        func union(_ first: ELVRecordKey, _ second: ELVRecordKey) {
            let rootA = find(first)
            let rootB = find(second)
            if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
        }

        var byIdentityKey: [String: ELVRecordKey] = [:]
        for (key, identities) in identitiesByRecord.sorted(by: { $0.key < $1.key }) {
            for identity in identities where isLinking(identity, on: key) {
                let identityKey = "\(identity.namespace)|\(identity.value)"
                if let existing = byIdentityKey[identityKey] {
                    union(existing, key)
                } else {
                    byIdentityKey[identityKey] = key
                }
            }
        }
        for pair in confirmedLinkSet where !pairVetoSet.contains(pair) {
            guard identitiesByRecord[pair.a] != nil, identitiesByRecord[pair.b] != nil else { continue }
            union(pair.a, pair.b)
        }

        var components: [ELVRecordKey: Set<ELVRecordKey>] = [:]
        for key in identitiesByRecord.keys {
            components[find(key), default: []].insert(key)
        }
        return Array(components.values)
    }

    private func makeEntity(members: Set<ELVRecordKey>) -> ELVEntity {
        let sorted = members.sorted()
        var identities: [ELVIdentity] = []
        var seen = Set<ELVIdentity>()
        // Set-backed dedup keeps the union linear in the member identity
        // count; order is member-sorted, then declaration order.
        for member in sorted {
            for identity in identitiesByRecord[member] ?? [] where seen.insert(identity).inserted {
                identities.append(identity)
            }
        }
        return ELVEntity(members: sorted, identities: identities)
    }
}

/// Copy-on-mutate memo for the component computation and its derived
/// views: components, a record → component index (so `entity(for:)` is
/// one lookup instead of a scan over every component), and the sorted
/// entity list. Vetoes make incremental union-find non-monotonic, so
/// the full recompute stays; it runs once per mutation generation. The
/// box is immutable-once-filled and lock-guarded, so sharing it between
/// copies of the struct is sound.
private final class ELVEntityComponentsCache: Sendable {
    struct Computed {
        var components: [Set<ELVRecordKey>]
        var componentIndex: [ELVRecordKey: Int]
    }

    private struct State {
        var computed: Computed?
        var entities: [ELVEntity]?
    }

    private let storage = Mutex(State())

    func computed(_ compute: () -> [Set<ELVRecordKey>]) -> Computed {
        storage.withLock { state in
            if let cached = state.computed { return cached }
            let components = compute()
            var index: [ELVRecordKey: Int] = [:]
            for (position, component) in components.enumerated() {
                for key in component {
                    index[key] = position
                }
            }
            let computed = Computed(components: components, componentIndex: index)
            state.computed = computed
            return computed
        }
    }

    var cachedEntities: [ELVEntity]? {
        storage.withLock { $0.entities }
    }

    /// Stores the sorted entity list unless another caller already did
    /// (the first writer wins; both computed the same list).
    func store(entities: [ELVEntity]) -> [ELVEntity] {
        storage.withLock { state in
            if let cached = state.entities { return cached }
            state.entities = entities
            return entities
        }
    }
}

// MARK: - Codable

extension ELVEntityIndex: Codable {
    private static let knownKeys: Set<String> = [
        "formatVersion", "records", "confirmedLinks", "pairVetoes", "identityVetoes", "extraStrongNamespaces",
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .init("formatVersion")) ?? 1
        let rawRecords = try container.decodeIfPresent([String: [ELVIdentity]].self, forKey: .init("records")) ?? [:]
        var records: [ELVRecordKey: [ELVIdentity]] = [:]
        for (storageKey, identities) in rawRecords {
            guard let key = ELVRecordKey(storageKey: storageKey) else { continue }
            records[key] = identities
        }
        identitiesByRecord = records
        confirmedLinkSet = try Set(container.decodeIfPresent([ELVRecordPair].self, forKey: .init("confirmedLinks")) ?? [])
        pairVetoSet = try Set(container.decodeIfPresent([ELVRecordPair].self, forKey: .init("pairVetoes")) ?? [])
        identityVetoSet = try Set(container.decodeIfPresent([ELVIdentityVeto].self, forKey: .init("identityVetoes")) ?? [])
        extraStrongNamespaces = try Set(container.decodeIfPresent([String].self, forKey: .init("extraStrongNamespaces")) ?? [])

        unknown = try container.elvUnknownKeys(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ELVDynamicKey.self)
        try container.encode(formatVersion, forKey: .init("formatVersion"))
        let rawRecords = Dictionary(uniqueKeysWithValues: identitiesByRecord.map { ($0.key.storageKey, $0.value) })
        try container.encode(rawRecords, forKey: .init("records"))
        // The sorted array views keep the persisted form deterministic.
        if !confirmedLinkSet.isEmpty { try container.encode(confirmedLinks, forKey: .init("confirmedLinks")) }
        if !pairVetoSet.isEmpty { try container.encode(pairVetoes, forKey: .init("pairVetoes")) }
        if !identityVetoSet.isEmpty { try container.encode(identityVetoes, forKey: .init("identityVetoes")) }
        if !extraStrongNamespaces.isEmpty { try container.encode(extraStrongNamespaces.sorted(), forKey: .init("extraStrongNamespaces")) }
        try container.elvEncodeUnknown(unknown)
    }
}
