import EluviumCore

/// The Identity tab's canned corpus, beside `AnchorLadderDemo`: the
/// movie lists whose shared films collapse via declared + crosswalk ids,
/// and the Michelin/Swarm place pairs the matcher scores for confirm or
/// reject. Data, the pair scoring, and the pure index readings (the index
/// the screen renders, each pair's link state, the next pending pair); the
/// decisions themselves stay on the screen. The app tests exercise these
/// exact fixtures, so screen and tests cannot drift.
enum IdentityShowcase {
    /// A sample source record plus the per-source display line the entity
    /// view shows as a membership chip.
    struct Sample {
        var key: ELVRecordKey
        var title: String
        var identities: [ELVIdentity]
        var membership: String
        var place: ELVPlaceMatcher.Place?
    }

    /// One matcher-scored suggestion the screen offers to confirm or reject.
    struct PlacePair {
        var michelin: ELVRecordKey
        var swarm: ELVRecordKey
        var confidence: Double

        /// The order-free key the index keeps decisions under.
        var recordPair: ELVRecordPair {
            ELVRecordPair(michelin, swarm)
        }
    }

    /// A user's answer to one suggestion.
    enum LinkDecision: Equatable {
        case confirmed
        case rejected
    }

    /// Where a suggestion stands in the index: open with its score, linked,
    /// or rejected (a veto, which survives re-import).
    enum LinkState: Equatable {
        case suggested(percent: Int)
        case linked
        case rejected

        var label: String {
            switch self {
            case let .suggested(percent): "Suggested \(percent)%"
            case .linked: "Linked ✓"
            case .rejected: "Rejected"
            }
        }

        /// Linked or rejected: the user has answered.
        var isDecided: Bool {
            if case .suggested = self { false } else { true }
        }
    }

    // MARK: - Movies

    /// Star Wars (1977) appears on all three lists via declared + crosswalk
    /// ids; The Empire Strikes Back only on two; a Douban-only film stays
    /// solo — the lists must remain intact.
    static let movieSamples: [Sample] = [
        Sample(
            key: ELVRecordKey(sourceId: "douban.watched", externalId: "1292052"),
            title: "星球大战",
            identities: [
                ELVIdentity(namespace: "douban.film", value: "1292052", origin: .declared),
                ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .declared),
            ],
            membership: "Douban ★5 · watched 2019",
            place: nil
        ),
        Sample(
            key: ELVRecordKey(sourceId: "imdb.ratings", externalId: "tt0076759"),
            title: "Star Wars",
            identities: [ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .declared)],
            membership: "IMDb 9/10",
            place: nil
        ),
        Sample(
            key: ELVRecordKey(sourceId: "wikipedia.list", externalId: "Q17738"),
            title: "Star Wars (Wikipedia)",
            identities: [
                ELVIdentity(namespace: "wikidata", value: "Q17738", origin: .declared),
                ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .crosswalk(via: "wikidata")),
            ],
            membership: "Film 1 of 9",
            place: nil
        ),
        Sample(
            key: ELVRecordKey(sourceId: "imdb.ratings", externalId: "tt0080684"),
            title: "The Empire Strikes Back",
            identities: [ELVIdentity(namespace: "imdb", value: "tt0080684", origin: .declared)],
            membership: "IMDb 10/10",
            place: nil
        ),
        Sample(
            key: ELVRecordKey(sourceId: "wikipedia.list", externalId: "Q181803"),
            title: "The Empire Strikes Back (Wikipedia)",
            identities: [
                ELVIdentity(namespace: "wikidata", value: "Q181803", origin: .declared),
                ELVIdentity(namespace: "imdb", value: "tt0080684", origin: .crosswalk(via: "wikidata")),
            ],
            membership: "Film 2 of 9",
            place: nil
        ),
        Sample(
            key: ELVRecordKey(sourceId: "douban.watched", externalId: "1291560"),
            title: "龙猫",
            identities: [ELVIdentity(namespace: "douban.film", value: "1291560", origin: .declared)],
            membership: "Douban ★5 · watched 2020",
            place: nil
        ),
    ]

    // MARK: - Places

    private static let benuMichelinPlace = ELVPlaceMatcher.Place(name: "Benu", latitude: 37.7854, longitude: -122.3993)
    private static let benuSwarmPlace = ELVPlaceMatcher.Place(name: "Benu Restaurant", latitude: 37.7855, longitude: -122.3994)
    private static let crennMichelinPlace = ELVPlaceMatcher.Place(name: "Atelier Crenn", latitude: 37.7983, longitude: -122.4360)
    private static let crennSwarmPlace = ELVPlaceMatcher.Place(name: "Atelier Crenn", latitude: 37.7984, longitude: -122.4361)

    private static let michelinBenuKey = ELVRecordKey(sourceId: "michelin.favorite", externalId: "benu")
    private static let swarmBenuKey = ELVRecordKey(sourceId: "swarm.checkin", externalId: "c-benu")
    private static let michelinCrennKey = ELVRecordKey(sourceId: "michelin.favorite", externalId: "atelier-crenn")
    private static let swarmCrennKey = ELVRecordKey(sourceId: "swarm.checkin", externalId: "c-crenn")

    /// Michelin favorites vs Swarm check-ins: no shared id namespace, so
    /// only the heuristic tier can relate them.
    static let placeSamples: [Sample] = [
        Sample(
            key: michelinBenuKey,
            title: "Benu",
            identities: [ELVIdentity(namespace: "michelin.restaurant", value: "benu", origin: .declared)],
            membership: "Michelin ★★★",
            place: benuMichelinPlace
        ),
        Sample(
            key: swarmBenuKey,
            title: "Benu Restaurant",
            identities: [ELVIdentity(namespace: "fsq.venue", value: "4b0", origin: .declared)],
            membership: "Swarm check-in",
            place: benuSwarmPlace
        ),
        Sample(
            key: michelinCrennKey,
            title: "Atelier Crenn",
            identities: [ELVIdentity(namespace: "michelin.restaurant", value: "atelier-crenn", origin: .declared)],
            membership: "Michelin ★★★",
            place: crennMichelinPlace
        ),
        Sample(
            key: swarmCrennKey,
            title: "Atelier Crenn",
            identities: [ELVIdentity(namespace: "fsq.venue", value: "4c1", origin: .declared)],
            membership: "Swarm check-in",
            place: crennSwarmPlace
        ),
    ]

    static var allSamples: [Sample] { movieSamples + placeSamples }

    // MARK: - Index

    /// The index the Identity screen renders: every sample registered, the
    /// loaded pack's strong namespaces added (an index built for a loaded
    /// pack must know the pack's vocabulary, or pack-declared namespaces
    /// never link), and the user's decisions replayed. Rebuilt from scratch
    /// on every change, so undoing a decision is just dropping it.
    static func makeIndex(strongNamespaces: Set<String>, decisions: [ELVRecordPair: LinkDecision]) -> ELVEntityIndex {
        var index = ELVEntityIndex()
        index.addStrongNamespaces(strongNamespaces)
        for sample in allSamples {
            index.register(key: sample.key, identities: sample.identities)
        }
        for (pair, decision) in decisions {
            switch decision {
            case .confirmed: index.confirmLink(pair.a, pair.b)
            case .rejected: index.vetoLink(pair.a, pair.b)
            }
        }
        return index
    }

    /// `pair`'s standing in `index`: a veto reads as rejected, never as a
    /// still-open suggestion.
    static func linkState(of pair: PlacePair, in index: ELVEntityIndex) -> LinkState {
        if index.pairVetoes.contains(pair.recordPair) { return .rejected }
        if index.entity(for: pair.michelin)?.members.contains(pair.swarm) == true { return .linked }
        return .suggested(percent: Int((pair.confidence * 100).rounded()))
    }

    /// The first suggestion still waiting for an answer: the keyboard's
    /// confirm and reject act on this, so a decided pair (rejected included)
    /// is never decided again behind the user's back.
    static func firstPending(_ pairs: [PlacePair], in index: ELVEntityIndex) -> PlacePair? {
        pairs.first { !linkState(of: $0, in: index).isDecided }
    }

    /// The suggestion pairs, scored through the registered
    /// `entity.placeMatch@1` op — the exact call surface the screen's
    /// caption advertises. Ops register when the store loads its
    /// pack, so touch `ExampleStore.shared` before the first call.
    static func placePairs() -> [PlacePair] {
        [
            (michelinBenuKey, swarmBenuKey, benuMichelinPlace, benuSwarmPlace),
            (michelinCrennKey, swarmCrennKey, crennMichelinPlace, crennSwarmPlace),
        ]
        .compactMap { michelin, swarm, a, b in
            confidence(a, b).map { PlacePair(michelin: michelin, swarm: swarm, confidence: $0) }
        }
    }

    /// One pair through `entity.placeMatch@1`; the direct matcher is only
    /// the roster-missing fallback (an op returning nil means "no match",
    /// not "try again another way").
    private static func confidence(_ a: ELVPlaceMatcher.Place, _ b: ELVPlaceMatcher.Place) -> Double? {
        guard let op = ELVNativeOps.lookup("entity.placeMatch@1") else {
            return ELVPlaceMatcher.score(a, b)?.confidence
        }
        var input = ["name": a.name, "candidateName": b.name]
        if let latitude = a.latitude, let longitude = a.longitude {
            input["lat"] = String(latitude)
            input["lng"] = String(longitude)
        }
        if let latitude = b.latitude, let longitude = b.longitude {
            input["candidateLat"] = String(latitude)
            input["candidateLng"] = String(longitude)
        }
        guard case let .rating(value, _)? = op(input, ELVExtractionContext())?["confidence"] else { return nil }
        return value
    }
}
