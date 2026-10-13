import Foundation

/// What this binary can do: the capability half of pack↔binary version
/// negotiation.
public struct ELVCapabilities: Sendable {
    /// Fetch modes the linked modules provide (`http`, `json`, `archive`
    /// from EluviumNet/Core; `dom` only when EluviumDOM is present; …).
    public var fetchModes: Set<String>
    /// The Eluvium binary version, dotted numerals (`0.1`).
    public var binaryVersion: String

    public init(fetchModes: Set<String>, binaryVersion: String) {
        self.fetchModes = fetchModes
        self.binaryVersion = binaryVersion
    }

    /// What EluviumCore alone provides: pure parsing plus archive import.
    public static let core = Self(fetchModes: [ELVFetchModes.archive], binaryVersion: ELVBinary.version)
}

/// The binary version constant shared by capability checks.
public enum ELVBinary {
    public static let version = "0.2"

    /// Compares dotted numeric versions: `isAtLeast("1.3", required: "1.10")`
    /// is false; missing components are zero.
    public static func isAtLeast(_ version: String, required: String) -> Bool {
        let lhs = version.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = required.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }
}

/// A source the loader set aside, with the reason (skipped, never
/// half-working).
public struct ELVSkippedSource: Sendable, Equatable {
    public var id: String
    public var reason: String
}

/// A pack after load: decoded, negotiated, filtered to the sources this
/// binary can actually run, with a registry built over them.
public struct ELVLoadedPack: Sendable {
    public let pack: ELVSourcePack
    /// Sources this binary can run, in pack order.
    public let sources: [ELVSource]
    public let skipped: [ELVSkippedSource]
    /// Stage ① registry over the active host/brand/path-matched sources.
    public let registry: ELVSourceRegistry
    /// Generic-floor sources: a catch-all match (no host/brand/path/
    /// file) over an `http`/`json` fetch, so every URL produces at least
    /// something. Ordered by pack order; the pipeline uses the first when
    /// no exact source recognizes.
    public let genericFloors: [ELVSource]
    /// File-input sources, for archive recognition.
    public let fileSources: [ELVSource]
    /// Sources with a pack-authored `seed` URL, in pack order: the
    /// browsable inventory (rankings) hosts list and start via `runSeed`.
    public let seededSources: [ELVSource]
    /// Sources with a `list` enumeration spec, in pack order: the
    /// walkable catalogs hosts surface and drive through `ELVEnumerator`.
    /// The roster is pack config — a hosting app never hardcodes catalog ids.
    public let enumerableSources: [ELVSource]
    /// Load-time authoring diagnostics: constructs that decoded but
    /// cannot work, plus sources dropped during decode. Empty for a clean
    /// pack; never affects which sources run.
    public let diagnostics: [ELVPackDiagnostic]
    /// The identity namespaces this pack declares strong (`strongNamespaces`
    /// in the pack, blank entries dropped), unioned across merged layers. A
    /// host feeds them to its entity index once per load:
    /// `index.addStrongNamespaces(pack.strongNamespaces)`. Append-only
    /// : packs add strong namespaces, never remove the binary's.
    public let strongNamespaces: Set<String>
    /// What the binary that loaded this pack can do: the fetch modes its
    /// sources were gated against. The offline preview reads it to say
    /// whether a full run would fetch.
    public let capabilities: ELVCapabilities

    private let sourcesById: [String: ELVSource]

    init(pack: ELVSourcePack, sources: [ELVSource], skipped: [ELVSkippedSource], capabilities: ELVCapabilities, diagnostics: [ELVPackDiagnostic] = [], strongNamespaces: Set<String>? = nil) {
        self.pack = pack
        self.capabilities = capabilities
        self.sources = sources
        self.skipped = skipped
        self.diagnostics = diagnostics
        self.strongNamespaces = strongNamespaces ?? Set(pack.strongNamespaces.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        registry = ELVSourceRegistry(sources: sources.compactMap { source in
            guard let match = source.match, !match.hosts.isEmpty || !match.brands.isEmpty || !match.schemes.isEmpty || !match.paths.isEmpty else { return nil }
            return ELVMatchableSource(id: source.id, match: match)
        })
        genericFloors = sources.filter { source in
            // A seeded source is browsable inventory: even without a
            // match rule it must never become a fallback for unrecognized
            // pastes.
            guard source.seed == nil else { return false }
            guard source.match == nil || source.match?.isCatchAll == true else { return false }
            let modes = source.fetch?.requiredModes ?? []
            return !modes.isDisjoint(with: ELVFetchModes.urlTransports)
        }
        seededSources = sources.filter { $0.seed != nil }
        enumerableSources = sources.filter { $0.list != nil }
        fileSources = sources.filter { $0.match?.file != nil }
        sourcesById = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func source(withId id: String) -> ELVSource? {
        sourcesById[id]
    }
}

public enum ELVPackError: Error, Equatable {
    /// The pack's `schemaVersion` is outside `1...supportedSchemaVersion`: a
    /// newer major this binary cannot interpret, or a non-positive value no
    /// pack has ever carried. Minor versions are additive and never rejected.
    case unsupportedSchemaVersion(Int)
    case malformed(String)
    /// Two sources share an id. Duplication is ambiguity (registry order,
    /// skip reporting, `source(withId:)` lookups), not degradation, so the
    /// pack is rejected whole.
    case duplicateSourceId(String)
}

/// Decode → negotiate → filter. The loader itself is pure schema
/// work, but it only accepts `ELVVerifiedPackBytes`: remote packs must pass
/// `ELVPackVerifier.verify` first, and compiled-in bytes claim their trust
/// explicitly via `load(embedded:)` / `.embedded(_:)`. There is no unlabeled
/// raw-`Data` entry point — a pack drives fetch URLs, personas, regexes, and
/// native-op selection, so unauthenticated bytes must be unrepresentable
/// here, not merely discouraged.
public enum ELVPackLoader {
    public static let supportedSchemaVersion = 1
    /// The newest additive grammar minor this binary executes in full. A
    /// pack declaring a newer minor still loads (forward compatibility: its
    /// unknown vocabulary degrades per source with the usual diagnostics)
    /// and gets one pack-level note saying so.
    public static let supportedSchemaMinor = 5

    /// One-time builtin-op registration: `static let` initialization gives
    /// the thread-safe once semantics, so repeated pack loads stop re-taking
    /// two locks per op and re-allocating every closure.
    private static let builtinsRegistered: Bool = {
        ELVNativeOps.registerBuiltins()
        return true
    }()

    /// Loads compiled-in pack bytes (the starter pack, test fixtures). The
    /// argument label is the trust claim — bytes that crossed the network go
    /// through `ELVPackVerifier.verify` instead.
    public static func load(embedded data: Data, capabilities: ELVCapabilities = .core) throws -> ELVLoadedPack {
        try load(.embedded(data), capabilities: capabilities)
    }

    /// Decodes, negotiates, and filters `verified`, logging one outcome line:
    /// a notice with the counts on success (plus a warning per diagnostic,
    /// which a clean pack never has), an error on rejection.
    public static func load(_ verified: ELVVerifiedPackBytes, capabilities: ELVCapabilities = .core) throws -> ELVLoadedPack {
        try load(verified, capabilities: capabilities, failureLevel: .error)
    }

    /// `load` for a caller that logs a rejection itself at its own boundary
    /// (a remote refresh, the cached-pack store): the loader's failure line
    /// drops to `failureLevel`, so one failure is one error line.
    package static func load(_ verified: ELVVerifiedPackBytes, capabilities: ELVCapabilities, failureLevel: ELVLogLevel) throws -> ELVLoadedPack {
        let loaded: ELVLoadedPack
        do {
            loaded = try decodeAndFilter(verified, capabilities: capabilities)
        } catch {
            ELVLog.log(failureLevel, .pack, "Pack load failed bytes=\(verified.data.count)", error: error)
            throw error
        }
        logLoaded(loaded)
        return loaded
    }

    private static func logLoaded(_ loaded: ELVLoadedPack) {
        let pack = loaded.pack
        ELVLog.notice(
            .pack,
            "Pack loaded version=\(pack.packVersion) schema=\(pack.schemaVersion).\(pack.schemaMinor) "
                + "sources=\(loaded.sources.count) skipped=\(loaded.skipped.count) diagnostics=\(loaded.diagnostics.count)"
        )
        for skip in loaded.skipped {
            ELVLog.debug(.pack, "Pack \(pack.packVersion) skipped source=\(skip.id): \(skip.reason)")
        }
        for diagnostic in loaded.diagnostics {
            ELVLog.warning(.pack, "Pack \(pack.packVersion) diagnostic: \(diagnostic.description)")
        }
    }

    private static func decodeAndFilter(_ verified: ELVVerifiedPackBytes, capabilities: ELVCapabilities) throws -> ELVLoadedPack {
        _ = builtinsRegistered
        var pack: ELVSourcePack
        do {
            pack = try JSONDecoder().decode(ELVSourcePack.self, from: verified.data)
        } catch {
            throw ELVPackError.malformed(String(describing: error))
        }
        guard (1 ... supportedSchemaVersion).contains(pack.schemaVersion) else {
            throw ELVPackError.unsupportedSchemaVersion(pack.schemaVersion)
        }
        var resolutionNotes: [ELVPackDiagnostic] = []
        if pack.schemaMinor > supportedSchemaMinor {
            resolutionNotes.append(ELVPackDiagnostic(
                message: "pack declares schemaMinor \(pack.schemaMinor); this binary knows \(supportedSchemaMinor); unknown vocabulary degrades per source"
            ))
        }
        // Resolve fragments before gating and validation so both see the
        // sources as they will run (a fragment-supplied fetch plan counts
        // toward capability requirements). The contributes-nothing check
        // must run HERE: after resolution the validator cannot tell a
        // source-authored fetch from a fragment-filled one.
        if !pack.fragments.isEmpty {
            for source in pack.sources {
                for name in source.use {
                    guard let fragment = pack.fragments[name] else { continue }
                    if fragment.fields.isEmpty, fragment.fetch != nil, source.fetch != nil {
                        resolutionNotes.append(ELVPackDiagnostic(
                            sourceId: source.id,
                            message: "use \"\(name)\" contributes nothing: the source authors its own fetch and the fragment has no fields"
                        ))
                    }
                }
            }
            pack.sources = pack.sources.map { resolved($0, fragments: pack.fragments) }
        }
        // Named triggers resolve the same way (whole-trigger replacement;
        // the string form cannot carry sibling keys). Dangling names stay
        // set — `ELVFetchStep.permits` never admits them — and both directions get
        // diagnostics here, where reference and table are still visible.
        var referencedTriggers = Set<String>()
        for source in pack.sources {
            for step in source.fetch?.resolvedSteps ?? [] {
                guard let ref = step.when?.ref else { continue }
                referencedTriggers.insert(ref)
                if pack.triggers[ref] == nil {
                    resolutionNotes.append(ELVPackDiagnostic(sourceId: source.id, message: "when references trigger \"\(ref)\", which the pack does not declare; its step can never run"))
                }
            }
        }
        for name in pack.triggers.keys.sorted() where !referencedTriggers.contains(name) {
            resolutionNotes.append(ELVPackDiagnostic(message: "trigger \"\(name)\" is declared but no step references it"))
        }
        if !pack.triggers.isEmpty {
            pack.sources = pack.sources.map { resolvedTriggers($0, triggers: pack.triggers) }
        }
        var seen = Set<String>()
        for source in pack.sources where !seen.insert(source.id).inserted {
            throw ELVPackError.duplicateSourceId(source.id)
        }

        var active: [ELVSource] = []
        var skipped: [ELVSkippedSource] = []
        for source in pack.sources {
            if let reason = skipReason(for: source, capabilities: capabilities) {
                skipped.append(ELVSkippedSource(id: source.id, reason: reason))
            } else {
                active.append(source)
            }
        }
        return ELVLoadedPack(pack: pack, sources: active, skipped: skipped, capabilities: capabilities, diagnostics: resolutionNotes + ELVPackValidator.diagnose(pack))
    }

    /// Applies the source's `use` list: a fragment's fetch plan fills an
    /// absent one (first `use` entry with a plan wins), fragment fields
    /// append after the source's own, and a field both declare merges
    /// candidate lists source-first — the extractor takes the first winning
    /// candidate, so a source override always outranks the shared ladder.
    /// Unknown names resolve to nothing; the validator flags them.
    static func resolved(_ source: ELVSource, fragments: [String: ELVSourceFragment]) -> ELVSource {
        guard !source.use.isEmpty else { return source }
        var source = source
        for name in source.use {
            guard let fragment = fragments[name] else { continue }
            if source.fetch == nil { source.fetch = fragment.fetch }
            for field in fragment.fields {
                if let index = source.fields.firstIndex(where: { $0.name == field.name }) {
                    source.fields[index].candidates.append(contentsOf: field.candidates)
                } else {
                    source.fields.append(field)
                }
            }
        }
        return source
    }

    /// Replaces steps' named-trigger references with the pack's `triggers`
    /// entries. Dangling names keep their `ref` so the pipeline treats the
    /// step as conditional-and-unresolvable (never admits).
    static func resolvedTriggers(_ source: ELVSource, triggers: [String: ELVEscalationTrigger]) -> ELVSource {
        guard var fetch = source.fetch, !fetch.steps.isEmpty else { return source }
        fetch.steps = fetch.steps.map { step in
            guard let ref = step.when?.ref, let named = triggers[ref] else { return step }
            var step = step
            step.when = named
            return step
        }
        var source = source
        source.fetch = fetch
        return source
    }

    /// `nil` means the source runs. Every declared requirement must be met;
    /// unknown requirement shapes skip conservatively.
    static func skipReason(for source: ELVSource, capabilities: ELVCapabilities) -> String? {
        if let minBinary = source.minBinary, !ELVBinary.isAtLeast(capabilities.binaryVersion, required: minBinary) {
            return "requires binary \(minBinary), this is \(capabilities.binaryVersion)"
        }
        if let fetch = source.fetch {
            for mode in fetch.gatingModes.sorted() where !capabilities.fetchModes.contains(mode) {
                return mode == ELVFetchModes.unsupported ? "fetch plan declares no mode" : "fetch mode \(mode) unavailable"
            }
        }
        for requirement in source.requires {
            if requirement.hasPrefix("fetch:") {
                let mode = String(requirement.dropFirst("fetch:".count))
                if !capabilities.fetchModes.contains(mode) { return "fetch mode \(mode) unavailable" }
            } else if requirement.hasPrefix("native:") {
                let op = String(requirement.dropFirst("native:".count))
                if !ELVNativeOps.isRegistered(op) { return "native op \(op) unavailable" }
            } else {
                return "unknown requirement \(requirement)"
            }
        }
        // A redirector's op is an implicit requirement: without it the
        // source could claim its hosts and then fail every resolve.
        if let op = source.resolvesVia, !ELVNativeOps.isRegistered(op) {
            return "native op \(op) unavailable"
        }
        return nil
    }
}
