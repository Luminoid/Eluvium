import Foundation
import Synchronization

/// The registry of named, versioned Swift functions callable from config
/// . This is how "everything lives in the framework" holds without
/// pretending prose heuristics are expressible in JSON: config owns
/// everything enumerable, ops own everything judgmental.
///
/// Ops are additive-only: changing behavior means registering `@2`;
/// `@1` stays. A pack pins the version it was written against
/// (`trail.statsFromText@2`), and a binary lacking the op skips that
/// candidate (or, with `requires`, the whole source).
public enum ELVNativeOps {
    // Fixed pattern compiled once (the static-pattern rule): text.digits
    // runs per computed-param URL template fill.
    // swiftlint:disable:next force_try
    private static let digitRunRegex = try! NSRegularExpression(pattern: "[0-9]+")

    /// A native op: named inputs in, named outputs out. Returns `nil` when
    /// the op cannot produce (which invalidates the calling candidate).
    public typealias NativeOp = @Sendable (_ input: [String: String], _ context: ELVExtractionContext) -> [String: ELVValue]?

    /// An async native op: platform lookups (MapKit, HealthKit, EventKit)
    /// that cannot answer synchronously. Registered by the platform modules
    /// (EluviumNet, EluviumPlaces); the sync extraction path never runs
    /// them — they serve enrichment stages and the capability gate.
    public typealias AsyncNativeOp = @Sendable (_ input: [String: String], _ context: ELVExtractionContext) async throws -> [String: ELVValue]?

    private static let registry = Mutex<[String: NativeOp]>([:])
    private static let asyncRegistry = Mutex<[String: AsyncNativeOp]>([:])

    /// Registers `op` as `name@version`. Re-registering an existing
    /// name+version replaces it (tests rely on this); production code should
    /// only ever add.
    ///
    /// Trust model: ops are registered by linked modules — binary code in
    /// the same trust domain as the host app, never pack content. The
    /// capability gate (`isRegistered`, `"requires": ["native:…"]`) is
    /// version negotiation, not a security boundary: replacing an op already
    /// requires code execution in-process, so there is no freeze mechanism.
    public static func register(_ name: String, version: Int = 1, op: @escaping NativeOp) {
        registry.withLock { $0["\(name)@\(version)"] = op }
    }

    /// Registers an async op as `name@version` (same additive-only rules and
    /// trust model as `register`).
    public static func registerAsync(_ name: String, version: Int = 1, op: @escaping AsyncNativeOp) {
        asyncRegistry.withLock { $0["\(name)@\(version)"] = op }
    }

    /// Looks up a sync op reference. A bare `name` resolves to `name@1`.
    public static func lookup(_ reference: String) -> NativeOp? {
        registry.withLock { $0[canonical(reference)] }
    }

    /// Looks up any op reference for an async caller: async ops directly,
    /// sync ops wrapped, so enrichment stages need one code path.
    public static func lookupAsync(_ reference: String) -> AsyncNativeOp? {
        let key = canonical(reference)
        if let asyncOp = asyncRegistry.withLock({ $0[key] }) { return asyncOp }
        guard let syncOp = registry.withLock({ $0[key] }) else { return nil }
        return { input, context in syncOp(input, context) }
    }

    /// Whether `reference` (`name@version` or bare `name`) is registered in
    /// either registry — the capability gate's native-op check
    /// (`"requires": ["native:x@2"]`).
    public static func isRegistered(_ reference: String) -> Bool {
        let key = canonical(reference)
        return registry.withLock { $0[key] != nil } || asyncRegistry.withLock { $0[key] != nil }
    }

    /// `name@version` for any reference; a bare `name` means `name@1`.
    static func canonical(_ reference: String) -> String {
        reference.contains("@") ? reference : "\(reference)@1"
    }

    /// Registers the built-in op roster. Called once by the pack loader;
    /// safe to call repeatedly.
    public static func registerBuiltins() {
        register("x.syndicationToken", version: 1) { input, context in
            let id = input["id"] ?? context.params["id"] ?? ""
            guard let token = ELVSyndicationToken.compute(tweetId: id) else { return nil }
            return ["token": .text(token)]
        }
        register("text.digits", version: 1) { input, _ in
            // The first run of decimal digits in the input — the
            // computed-param bridge for prefixed path ids (Apple Podcasts'
            // "id152249110" → the lookup API's "152249110"). The computed-param
            // caller passes one value keyed by the param name, so any single
            // input is accepted; "text" wins when both are present.
            guard let value = input["text"] ?? input.values.first,
                  let match = digitRunRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range, in: value) else { return nil }
            return ["digits": .text(String(value[range]))]
        }
        register("text.join", version: 1) { input, _ in
            // A composite key from values no single one identifies: an
            // eBird data-download row is its checklist (Submission ID) plus
            // the species. Joins the `part1`…`part9` inputs in order with
            // `separator` (default "|"). Input resolution already drops the
            // candidate when a `$field` part is missing, so a partial key
            // never forms; an empty part fails the same way.
            let parts = input.keys.filter { $0.hasPrefix("part") }.sorted().compactMap { input[$0] }
            guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }
            return ["text": .text(parts.joined(separator: input["separator"] ?? "|"))]
        }
        registerTravelOps()
        registerProductOps()
        registerArticleOps()
        registerNotePyramidOp()
        register("entity.placeMatch", version: 1) { input, _ in
            // Scores this record's place against a candidate's, emitting a
            // heuristic-confidence suggestion the consumer confirms.
            guard let name = input["name"], let candidateName = input["candidateName"] else { return nil }
            let thisCoordinate = validCoordinate(lat: input["lat"], lng: input["lng"])
            let candidateCoordinate = validCoordinate(lat: input["candidateLat"], lng: input["candidateLng"])
            let this = ELVPlaceMatcher.Place(name: name, latitude: thisCoordinate?.latitude, longitude: thisCoordinate?.longitude)
            let candidate = ELVPlaceMatcher.Place(name: candidateName, latitude: candidateCoordinate?.latitude, longitude: candidateCoordinate?.longitude)
            guard let match = ELVPlaceMatcher.score(this, candidate) else { return nil }
            return ["confidence": .rating(value: match.confidence, scale: 0 ... 1)]
        }
    }

    /// Coordinate inputs are pack-resolved strings and must be plausible
    /// before they feed the haversine: out-of-range values and null island
    /// degrade to "no coordinate", so the match falls back to name-only
    /// scoring instead of scoring garbage geometry.
    private static func validCoordinate(lat: String?, lng: String?) -> (latitude: Double, longitude: Double)? {
        guard let lat = lat.flatMap(Double.init), let lng = lng.flatMap(Double.init),
              (-90 ... 90).contains(lat), (-180 ... 180).contains(lng),
              !(lat == 0 && lng == 0) else { return nil }
        return (lat, lng)
    }
}
