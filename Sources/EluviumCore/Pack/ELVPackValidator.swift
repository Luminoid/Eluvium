import Foundation

/// A non-fatal pack authoring problem found at load time: the pack still
/// loads, the flagged construct degrades at its own granularity, and
/// the author gets a precise pointer instead of silently dead behavior at
/// runtime.
public struct ELVPackDiagnostic: Sendable, Equatable, CustomStringConvertible {
    /// The source the problem lives in; `nil` for pack-level notes (a
    /// dropped undecodable source).
    public var sourceId: String?
    public var message: String

    public init(sourceId: String? = nil, message: String) {
        self.sourceId = sourceId
        self.message = message
    }

    public var description: String {
        sourceId.map { "\($0): \(message)" } ?? message
    }
}

/// Walks a decoded pack and reports everything that decoded but cannot
/// work: unsupported selectors and pipes, regexes and JSON paths that do
/// not parse, unknown coercion kinds and personas, vacuous escalation
/// triggers, dangling references, dead declarations. Pure hygiene;
/// activation and skipping stay in the loader. Pack regexes compile through
/// `ELVRegexCache` here, so a clean load also warms the cache the
/// extraction hot path reads.
enum ELVPackValidator {
    static func diagnose(_ pack: ELVSourcePack) -> [ELVPackDiagnostic] {
        var diagnostics = pack.decodeIssues.map { ELVPackDiagnostic(message: $0) }
        for source in pack.sources {
            diagnose(source, into: &diagnostics)
            for name in source.use where pack.fragments[name] == nil {
                diagnostics.append(ELVPackDiagnostic(sourceId: source.id, message: "use references fragment \"\(name)\", which the pack does not declare"))
            }
        }
        if pack.strongNamespaces.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            diagnostics.append(ELVPackDiagnostic(message: "strongNamespaces lists an empty namespace; it is ignored"))
        }
        let used = Set(pack.sources.flatMap(\.use))
        for (name, fragment) in pack.fragments.sorted(by: { $0.key < $1.key }) {
            if fragment.isEmpty {
                diagnostics.append(ELVPackDiagnostic(message: "fragment \"\(name)\" declares no fetch and no fields; it resolves to nothing"))
            }
            if !used.contains(name) {
                diagnostics.append(ELVPackDiagnostic(message: "fragment \"\(name)\" is declared but no source uses it"))
            }
        }
        return diagnostics
    }

    private static func diagnose(_ source: ELVSource, into diagnostics: inout [ELVPackDiagnostic]) {
        func note(_ message: String) {
            diagnostics.append(ELVPackDiagnostic(sourceId: source.id.isEmpty ? "(empty id)" : source.id, message: message))
        }
        if source.id.trimmingCharacters(in: .whitespaces).isEmpty {
            note("empty source id")
        }
        if !source.kind.isEmpty, !isPlausibleKindToken(source.kind) {
            note("kind \"\(source.kind)\" is not a lowercase kind token (vocabulary: trail, food, feed.item)")
        }
        if source.resolvesVia != nil, !(source.fields.isEmpty && source.collections.isEmpty) {
            note("a redirector resolves via its op; its fields and collections never run")
        }
        if let referer = source.imageReferer, referer != "page" {
            note("imageReferer \"\(referer)\" is not a known policy (only \"page\"); it is ignored")
        }
        // Recognition requires a host or brand hit before it consults the
        // path, so a path-only rule is admitted to the registry and then
        // ignored forever (file rules match separately and are exempt).
        if let match = source.match, !match.paths.isEmpty, match.hosts.isEmpty, match.brands.isEmpty, match.file == nil {
            note("a match rule with a path but no host or brand can never match")
        }
        if let match = source.match, match.paths.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            note("a match rule lists an empty path pattern, which can never match")
        }
        diagnoseRequires(source, note: note)
        if let fetch = source.fetch {
            diagnose(fetch, requires: source.requires, note: note)
            diagnoseStepScopes(of: fetch, source: source, note: note)
        }
        if let seed = source.seed, URL(string: seed)?.host == nil {
            note("seed \"\(seed)\" does not parse as a URL; runSeed can only fail")
        }
        if let seed = source.seed, seed.contains(ELVURLTemplate.hostPlaceholder) || seed.contains("{query.") {
            note("seed \"\(seed)\" carries an input-URL placeholder ({host} / {query.x}); a seed has no input URL, so runSeed can only fail")
        }
        for field in source.fields {
            // Top-level fields run through the pipeline's awaited extraction,
            // so async-registered ops are live there.
            diagnose(field, requires: source.requires, at: "field \"\(field.name)\"", asyncRuns: true, note: note)
        }
        for row in source.rows {
            diagnose(row, requires: source.requires, at: "row \"\(row.name)\"", note: note)
        }
        for collection in source.collections {
            diagnoseCollection(collection, requires: source.requires, note: note)
        }
        for identity in source.identities {
            if identity.namespace.trimmingCharacters(in: .whitespaces).isEmpty {
                note("an identity spec with an empty namespace never links")
            }
            diagnose(identity.from, requires: source.requires, at: "identity \"\(identity.namespace)\"", note: note)
        }
        if let inference = source.inference {
            diagnose(inference, source: source, note: note)
        }
        if let list = source.list {
            diagnose(list, requires: source.requires, note: note)
        }
    }

    /// `requires` hygiene: a `fetch:` entry the plan's own steps already
    /// imply gates nothing extra (the loader derives step modes itself), and
    /// a `native:` entry without `@version` pins whatever `@1` happens to
    /// be, where the candidates it guards name their version.
    private static func diagnoseRequires(_ source: ELVSource, note: (String) -> Void) {
        let stepModes = source.fetch?.requiredModes ?? []
        for requirement in source.requires {
            if requirement.hasPrefix("fetch:"), stepModes.contains(String(requirement.dropFirst("fetch:".count))) {
                note("requires \"\(requirement)\" is redundant: the plan's steps already require it")
            } else if requirement.hasPrefix("native:"), !requirement.contains("@") {
                note("requires \"\(requirement)\" names no version; pin it as \"\(requirement)@1\" like the candidates that call it")
            }
        }
    }

    private static func diagnose(_ list: ELVListSpec, requires: [String], note: (String) -> Void) {
        diagnose(list.items, requires: requires, at: "list.items", note: note)
        if let total = list.total { diagnose(total, requires: requires, at: "list.total", note: note) }
        if case let .nextURL(selector) = list.next { diagnose(selector, requires: requires, at: "list.next", note: note) }
        for issue in list.decodeIssues {
            note("list.next: \(issue)")
        }
    }

    /// `resolvedSteps` returns the steps verbatim for a composite, so
    /// plan-level keys are silently discarded — name them instead of letting
    /// an authored `jsonIsland`/`maxBytes` vanish without a trace.
    private static func diagnoseCompositeOrphans(_ fetch: ELVFetchPlan, note: (String) -> Void) {
        guard fetch.mode == ELVFetchModes.composite, !fetch.steps.isEmpty else { return }
        var orphaned: [String] = []
        if fetch.ua != nil { orphaned.append("ua") }
        if fetch.url != nil { orphaned.append("url") }
        if fetch.referer != nil { orphaned.append("referer") }
        if fetch.format != nil { orphaned.append("format") }
        if fetch.jsonIsland != nil { orphaned.append("jsonIsland") }
        if fetch.maxBytes != nil { orphaned.append("maxBytes") }
        if fetch.settle != nil { orphaned.append("settle") }
        if fetch.captureCanonical != nil { orphaned.append("captureCanonical") }
        if !orphaned.isEmpty {
            note("a composite plan's top-level \(orphaned.joined(separator: ", ")) \(orphaned.count == 1 ? "is" : "are") discarded; composite plans configure per step")
        }
    }

    private static func diagnose(_ fetch: ELVFetchPlan, requires: [String], note: (String) -> Void) {
        if fetch.mode == ELVFetchModes.composite, fetch.steps.isEmpty {
            note("a composite fetch plan with no steps")
        }
        diagnoseCompositeOrphans(fetch, note: note)
        for step in fetch.resolvedSteps {
            if step.mode == ELVFetchModes.unsupported {
                note("a fetch step declares no mode; the source is skipped")
            }
            if let ua = step.ua, !ELVUAPersona.knownNames.contains(ua) {
                note("persona \"\(ua)\" is not one this binary knows; mobileSafari is used")
            }
            if let referer = step.referer, referer != "sourceOrigin" {
                note("referer \"\(referer)\" is not a policy; only \"sourceOrigin\" exists")
            }
            if let when = step.when, when.isVacuous {
                note("an escalation trigger with no condition never fires; its step is dead")
            }
            if let when = step.when {
                if carriesURLKeys(when.anyOf) {
                    note("hostMatches/pathRegex inside anyOf are inert; URL preconditions are top-level only")
                }
                if when.anyOf.contains(where: { $0.ref != nil }) {
                    note("a trigger reference inside anyOf is inert; the string form is top-level `when` only")
                }
                if let pattern = when.pathRegex, ELVRegexCache.regex(pattern) == nil {
                    note("pathRegex \"\(pattern)\" does not compile; its step can never run")
                }
                if when.hostMatches.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    note("an empty hostMatches pattern can never admit a host; its step can never run")
                }
            }
            if step.format != nil, step.mode != ELVFetchModes.archive {
                note("a \"\(step.mode)\" step declares \"format\", which only archive steps read")
            }
            if step.jsonIsland != nil, step.mode != ELVFetchModes.http {
                note("a \"\(step.mode)\" step declares \"jsonIsland\", which only http steps read")
            }
            if step.maxBytes != nil, !ELVFetchModes.urlTransports.contains(step.mode) {
                note("a \"\(step.mode)\" step declares \"maxBytes\", which only URL-transport steps read")
            }
            if let url = step.url {
                diagnoseURLTemplate(url, requires: requires, note: note)
            }
        }
    }

    /// One collection's full diagnosis, shared by the source-level loop and
    /// the step-scoped loop: item specs, entries/from collisions, the
    /// rows-driver check, and per-item field diagnostics.
    private static func diagnoseCollection(_ collection: ELVCollectionSpec, requires: [String], note: (String) -> Void) {
        if collection.item.isEmpty {
            note("collection \"\(collection.name)\" has no item specs")
        }
        if let kind = collection.kind, !kind.isEmpty, !isPlausibleKindToken(kind) {
            note("collection \"\(collection.name)\": kind \"\(kind)\" is not a lowercase kind token (vocabulary: trail, food, feed.item)")
        }
        if let entries = collection.entries {
            if entries.isEmpty {
                note("collection \"\(collection.name)\" declares empty inline entries; it never yields items")
            }
            if collection.from != .unsupported(key: "(missing from)") {
                note("collection \"\(collection.name)\" declares both inline entries and from; entries win")
            }
        } else {
            diagnose(collection.from, requires: requires, at: "collection \"\(collection.name)\"", rowsPosition: true, note: note)
            // A VALUE selector (`css`, `meta`, `field`, …) decodes clean
            // but can never drive rows; without this note the collection
            // dies silently at runtime. `.unsupported` selectors already
            // got their own note above.
            if case .unresolvable = collection.rows, !isUnsupported(collection.from) {
                note("collection \"\(collection.name)\": \(collection.from.provenanceTag) is not a rows driver (json, jsonld, regexRows); the collection never yields items")
            }
        }
        for item in collection.item {
            diagnose(item, requires: requires, at: "collection \"\(collection.name)\" field \"\(item.name)\"", note: note)
        }
        for identity in collection.identities {
            if identity.namespace.trimmingCharacters(in: .whitespaces).isEmpty {
                note("collection \"\(collection.name)\": an identity spec with an empty namespace never links")
            }
            diagnose(identity.from, requires: requires, at: "collection \"\(collection.name)\" identity \"\(identity.namespace)\"", note: note)
        }
    }

    /// Step-scoped surfaces: scoped fields run through the pipeline's
    /// awaited walk (async ops live there), scoped collections through the
    /// sync assembler like source-level ones.
    private static func diagnoseStepScopes(of fetch: ELVFetchPlan, source: ELVSource, note: (String) -> Void) {
        let sourceCollectionNames = Set(source.collections.map(\.name))
        for (index, step) in fetch.resolvedSteps.enumerated() {
            let at = "step \(index)"
            if let stepFields = step.fields {
                if stepFields.isEmpty, step.collections?.isEmpty ?? true {
                    note("\(at) declares fields: [] and no collections; the step fetches and extracts nothing")
                }
                for field in stepFields {
                    diagnose(field, requires: source.requires, at: "\(at) field \"\(field.name)\"", asyncRuns: true, note: note)
                }
            }
            for collection in step.collections ?? [] {
                if sourceCollectionNames.contains(collection.name) {
                    note("collection \"\(collection.name)\" is declared on both the source and \(at); the step-scoped result wins where it produced")
                }
                diagnoseCollection(collection, requires: source.requires, note: note)
            }
        }
    }

    private static func isUnsupported(_ selector: ELVSelector) -> Bool {
        if case .unsupported = selector { return true }
        return false
    }

    private static func carriesURLKeys(_ triggers: [ELVEscalationTrigger]) -> Bool {
        triggers.contains { !$0.hostMatches.isEmpty || $0.pathRegex != nil || carriesURLKeys($0.anyOf) }
    }

    private static func diagnose(_ field: ELVFieldSpec, requires: [String], at location: String, asyncRuns: Bool = false, note: (String) -> Void) {
        if field.candidates.isEmpty {
            note("\(location) has no candidates")
        }
        for (index, candidate) in field.candidates.enumerated() {
            let at = field.candidates.count == 1 ? location : "\(location) candidate \(index)"
            diagnose(candidate.from, requires: requires, at: at, asyncRuns: asyncRuns, note: note)
            for pipe in candidate.pipes {
                diagnose(pipe, at: at, note: note)
            }
            guard let coercion = candidate.coercion else { continue }
            if !ELVCoercion.knownKinds.contains(coercion.kind) {
                note("\(at): unknown coercion kind \"\(coercion.kind)\"")
            }
            if let currencyFrom = coercion.currencyFrom {
                // Currency selectors resolve inside the coercion engine,
                // which is sync even under the awaited field walk.
                diagnose(currencyFrom, requires: requires, at: "\(at) currencyFrom", note: note)
            }
            if let min = coercion.scaleMin, let max = coercion.scaleMax, min >= max {
                note("\(at): rating scale \(min) to \(max) is empty")
            }
        }
    }

    private static func diagnose(_ selector: ELVSelector, requires: [String], at location: String, asyncRuns: Bool = false, rowsPosition: Bool = false, note: (String) -> Void) {
        switch selector {
        case let .unsupported(key):
            note("\(location): unsupported selector \"\(key)\"")
        case let .urlRegex(pattern):
            // The runtime compiles these with the case-insensitive prefix;
            // the same key here means the load-time compile is the one the
            // hot path hits.
            if ELVRegexCache.regex("(?i)" + pattern) == nil {
                note("\(location): regex does not compile: \(pattern)")
            }
        case let .textRegex(pattern, after):
            if ELVRegexCache.regex("(?i)" + pattern) == nil {
                note("\(location): regex does not compile: \(pattern)")
            }
            if after?.isEmpty == true {
                note("\(location): textRegex `after` is empty; an empty anchor never matches, so the candidate never produces")
            }
        case let .regexRows(pattern, after):
            if ELVRegexCache.regex(pattern) == nil {
                note("\(location): regex does not compile: \(pattern)")
            }
            if after?.isEmpty == true {
                note("\(location): regexRows `after` is empty; an empty anchor never matches, so the collection yields no rows")
            }
            // regexRows is a COLLECTION rows driver; in any value position
            // (fields, rows, identities, list selectors) the candidate can
            // never produce — the async-only-op note's structural twin.
            if !rowsPosition {
                note("\(location): regexRows drives collections only; a value candidate here never produces")
            }
        case let .json(path):
            if !ELVJSONPath(path).isValid {
                note("\(location): json path does not parse: \(path)")
            }
        case let .jsonld(path):
            // The first dotted component is the @type filter (`*` for any);
            // with none the engine has no node to select from.
            if path.isEmpty || path.hasPrefix(".") {
                note("\(location): jsonld selector \"\(path)\" has an empty type filter (use * for any node); the candidate never produces")
            }
        case let .native(op, _):
            // Registered ops run; required-but-unavailable ops skip the
            // whole source through the gate. An op that is neither can only
            // be a dead candidate (typically a typo).
            if !isRequired(op, in: requires), !ELVNativeOps.isRegistered(op) {
                note("\(location): native op \"\(op)\" is neither registered nor required; the candidate never produces")
            }
            // `isRegistered` consults both registries (correct for the
            // capability gate), but only the pipeline's top-level field walk
            // awaits async ops — everywhere else (rows, collections,
            // identities, list drivers) the sync path runs and an async-only
            // op never produces.
            if !asyncRuns, ELVNativeOps.isRegistered(op), ELVNativeOps.lookup(op) == nil {
                note("\(location): native op \"\(op)\" is only registered async; the sync extraction path never runs it")
            }
        default:
            break
        }
    }

    private static func diagnoseURLTemplate(_ template: String, requires: [String], note: (String) -> Void) {
        guard template.contains("{native:") else { return }
        let nsTemplate = template as NSString
        for match in ELVURLTemplate.nativePlaceholderRegex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length)) {
            let reference = nsTemplate.substring(with: match.range(at: 1))
            if !isRequired(reference, in: requires), !ELVNativeOps.isRegistered(reference) {
                note("url template: native op \"\(reference)\" is neither registered nor required; the step can never build its URL")
            } else if ELVNativeOps.isRegistered(reference), ELVNativeOps.lookup(reference) == nil {
                note("url template: native op \"\(reference)\" is only registered async; url templates run sync ops")
            }
        }
    }

    private static func isRequired(_ op: String, in requires: [String]) -> Bool {
        let reference = op.contains("@") ? op : "\(op)@1"
        return requires.contains { requirement in
            guard requirement.hasPrefix("native:") else { return false }
            let declared = String(requirement.dropFirst("native:".count))
            return (declared.contains("@") ? declared : "\(declared)@1") == reference
        }
    }

    private static func diagnose(_ inference: ELVInferenceSpec, source: ELVSource, note: (String) -> Void) {
        // Decode-time degradations: unknown table keys, malformed or
        // declared-empty tables, cap truncations.
        for issue in inference.decodeIssues {
            note("inference: \(issue)")
        }
        if inference.isEmpty {
            note("an inference block with no entries never suggests a kind")
        } else if !source.kind.isEmpty, !source.collections.contains(where: { ($0.kind ?? source.kind).isEmpty }) {
            // A suggestion only fills an absent kind, so with every record
            // kind authored the tables are dead weight.
            note("inference never runs: the source authors kind \"\(source.kind)\", and a suggestion only fills an absent kind")
        }
        for (table, entries) in inference.namedTables {
            for key in entries.keys.sorted() {
                guard let kind = entries[key] else { continue }
                if kind.trimmingCharacters(in: .whitespaces).isEmpty {
                    note("inference.\(table)[\"\(key)\"] maps to an empty kind and can never suggest")
                } else if !isPlausibleKindToken(kind) {
                    note("inference.\(table)[\"\(key)\"] targets \"\(kind)\", which is not a lowercase kind token (vocabulary); check for a swapped key and value")
                }
            }
        }
    }

    /// Kinds live in the append-only lowercase-token vocabulary:
    /// `trail`, `food`, `feed.item`. Anything else — on a source, a
    /// collection, or an inference table value — is a note, never a
    /// rejection: kinds are open strings by contract, so a consumer
    /// keeps working, but the author learns the token is off-vocabulary.
    private static func isPlausibleKindToken(_ kind: String) -> Bool {
        kind.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private static func diagnose(_ pipe: ELVPipe, at location: String, note: (String) -> Void) {
        switch pipe {
        case let .unsupported(name):
            note("\(location): unsupported pipe \"\(name)\"")
        case let .regexReplace(pattern, _):
            if ELVRegexCache.regex(pattern) == nil {
                note("\(location): regexReplace pattern does not compile: \(pattern)")
            }
        case let .take(count) where count <= 0:
            note("\(location): take \(count) yields nothing; the candidate never produces")
        default:
            break
        }
    }
}
