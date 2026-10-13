import Foundation

/// When a composite fetch step fires: blocked statuses, the
/// challenge-shell case (2xx but zero metadata), or a shallow fast path —
/// plus URL-shape preconditions (`hostMatches`, `pathRegex`) that scope a
/// step to inputs of a given shape, so one composite plan can branch per
/// host or path instead of splitting into one source per shape.
public struct ELVEscalationTrigger: Sendable, Decodable, Equatable {
    public var status: [Int]
    public var emptyRecord: Bool
    public var missingAny: [String]
    /// Fires when any named field is missing or weak (schemaMinor 5): empty,
    /// the source's own brand, or a bare country name. A Maps link whose
    /// URL label is just "Japan" still fetches the page that names the
    /// place, where `missingAny` would stop at the country.
    public var weakAny: [String]
    public var anyOf: [Self]
    /// Exact-or-subdomain host patterns; when non-empty, the step runs only
    /// for input URLs whose host matches one. Top-level only — inside
    /// `anyOf` these keys are inert and the validator says so.
    public var hostMatches: [String]
    /// A regex the input URL's path must match. Same top-level-only rule.
    public var pathRegex: String?
    /// The string form (`"when": "blockedOrThin"`): a name into the pack's
    /// `triggers` table. The loader replaces the whole trigger with the
    /// named one; a dangling name never admits (skip beats wrong) and gets
    /// a diagnostic. Top-level `when` only — inside `anyOf` a reference is
    /// inert.
    public var ref: String?

    public init(
        status: [Int] = [],
        emptyRecord: Bool = false,
        missingAny: [String] = [],
        weakAny: [String] = [],
        anyOf: [Self] = [],
        hostMatches: [String] = [],
        pathRegex: String? = nil,
        ref: String? = nil
    ) {
        self.status = status
        self.emptyRecord = emptyRecord
        self.missingAny = missingAny
        self.weakAny = weakAny
        self.anyOf = anyOf
        self.hostMatches = hostMatches
        self.pathRegex = pathRegex
        self.ref = ref
    }

    public init(from decoder: Decoder) throws {
        // The string form decodes to a pure reference; it can carry no
        // sibling keys by construction, and it never throws.
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.init(ref: name)
            return
        }
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        try self.init(
            status: container.elvIntList(forKey: .init("status")),
            emptyRecord: container.decodeIfPresent(Bool.self, forKey: .init("emptyRecord")) ?? false,
            missingAny: container.elvStringList(forKey: .init("missingAny")),
            weakAny: container.elvStringList(forKey: .init("weakAny")),
            anyOf: container.decodeIfPresent([Self].self, forKey: .init("anyOf")) ?? [],
            hostMatches: container.elvStringList(forKey: .init("hostMatches")),
            pathRegex: container.decodeIfPresent(String.self, forKey: .init("pathRegex"))
        )
    }

    /// A trigger with no URL gate and no response condition can never fire;
    /// its step is dead weight. The validator surfaces this as a diagnostic.
    /// A reference is not vacuous — it gets its own dangling/unresolved
    /// diagnostics instead.
    public var isVacuous: Bool {
        ref == nil && hostMatches.isEmpty && pathRegex == nil && !hasResponseConditions
    }

    /// Whether any status/emptyRecord/missingAny/weakAny condition exists
    /// here or in `anyOf`. A trigger without them is a pure URL gate: its
    /// step runs whenever the shape permits, first step included.
    public var hasResponseConditions: Bool {
        !status.isEmpty || emptyRecord || !missingAny.isEmpty || !weakAny.isEmpty || anyOf.contains(where: \.hasResponseConditions)
    }

    /// Whether the URL-shape precondition admits `url`. Evaluated against
    /// the canonicalized input URL for every step; a trigger with no URL
    /// keys admits everything.
    public func urlPermits(_ url: URL) -> Bool {
        if !hostMatches.isEmpty {
            guard let host = url.host?.lowercased(),
                  hostMatches.contains(where: { ELVHostMatcher.hostMatches(host, pattern: $0) }) else { return false }
        }
        if let pathRegex {
            guard ELVRegexCache.matches(pathRegex, in: url.path) else { return false }
        }
        return true
    }

    /// Whether this trigger fires for the previous step's outcome. `brand`
    /// is the source's brand (its `title`), which `weakAny` treats as weak.
    public func fires(status previousStatus: Int, extractedFields: [String: ELVValue], brand: String? = nil) -> Bool {
        if !anyOf.isEmpty {
            return anyOf.contains { $0.fires(status: previousStatus, extractedFields: extractedFields, brand: brand) }
        }
        if status.contains(previousStatus) { return true }
        if emptyRecord, extractedFields.isEmpty { return true }
        if !missingAny.isEmpty, missingAny.contains(where: { extractedFields[$0] == nil }) { return true }
        if !weakAny.isEmpty, weakAny.contains(where: { name in
            guard let text = extractedFields[name].flatMap({ ELVSelectorEngine.stringForm(of: $0)?.singleString }) else { return true }
            return ELVLabelResolver.isWeak(text, brand: brand)
        }) { return true }
        return false
    }
}

/// One step of a fetch plan. `mode` is open (`http`, `json`, `dom`, `feed`,
/// `archive`); a binary without the mode skips the source through the
/// capability gate. A step that declares no `mode` decodes as
/// `ELVFetchModes.unsupported`, which no binary provides: the source is
/// skipped with a reason and the validator names the step, so a missing
/// transport never silently turns into an http fetch.
public struct ELVFetchStep: Sendable, Decodable, Equatable {
    public var mode: String
    /// A persona name from the binary-owned set (`ELVUAPersona`); an unknown
    /// name resolves to `mobileSafari` and the validator notes it.
    public var ua: String?
    /// URL template (`https://api.example.com/v1/{param.id}`); absent means
    /// "fetch the input URL".
    public var url: String?
    /// The only allowed value is `sourceOrigin`.
    public var referer: String?
    /// Archive format (`csv`, `json`, `jsJson`) when `mode` is `archive`.
    public var format: String?
    /// Escalation trigger; a step without one always runs (first step).
    public var when: ELVEscalationTrigger?
    /// `http` mode: the id of an embedded `<script id="…"
    /// type="application/json">` island (Next.js-style server data) whose
    /// body is promoted into the document's JSON, so ordinary `json` fields
    /// and collections work on script-hydrated pages. A missing or
    /// malformed island leaves the document HTML-only.
    public var jsonIsland: String?
    /// URL-transport modes: the step's byte budget. Giant-feed
    /// sources opt in past the transport default; the fetcher clamps the
    /// ceiling regardless.
    public var maxBytes: Int?
    /// Step-scoped extraction: when present, this step runs ONLY
    /// these fields and the source ladder is skipped for it; absent means
    /// the source ladder runs. Built for enrichment composites (an API
    /// lookup, an embed page) whose documents have nothing to do with the
    /// page's; fallback composites keep the flat source ladder.
    public var fields: [ELVFieldSpec]?
    /// Step-scoped collections: evaluated against THIS step's
    /// context, not whichever step runs last; a step-scoped name overrides
    /// the source-level collection of the same name.
    public var collections: [ELVCollectionSpec]?
    /// `dom` mode: the settle policy. Defaults apply when absent.
    public var settle: ELVSettlePolicy?
    /// `dom` mode: canonical-URL capture.
    public var captureCanonical: ELVCanonicalCapture?
    /// `dom` mode (schemaMinor 5): named rendered-text regions to read
    /// (`ELVDOMRegion`: `h1`, `header`, `body`), landing in the document's
    /// `cssResults` under `@h1` / `@header` / `@body` for native ops. Unknown
    /// names are ignored with a validator note.
    public var regions: [String]

    public init(
        mode: String,
        ua: String? = nil,
        url: String? = nil,
        referer: String? = nil,
        format: String? = nil,
        when: ELVEscalationTrigger? = nil,
        jsonIsland: String? = nil,
        maxBytes: Int? = nil,
        fields: [ELVFieldSpec]? = nil,
        collections: [ELVCollectionSpec]? = nil,
        settle: ELVSettlePolicy? = nil,
        captureCanonical: ELVCanonicalCapture? = nil,
        regions: [String] = []
    ) {
        self.mode = mode
        self.ua = ua
        self.url = url
        self.referer = referer
        self.format = format
        self.when = when
        self.jsonIsland = jsonIsland
        self.maxBytes = maxBytes
        self.fields = fields
        self.collections = collections
        self.settle = settle
        self.captureCanonical = captureCanonical
        self.regions = regions
    }

    private enum CodingKeys: String, CodingKey {
        case mode, ua, url, referer, format, when, jsonIsland, maxBytes, fields, collections, settle, captureCanonical, regions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? ELVFetchModes.unsupported
        ua = try container.decodeIfPresent(String.self, forKey: .ua)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        referer = try container.decodeIfPresent(String.self, forKey: .referer)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        when = try container.decodeIfPresent(ELVEscalationTrigger.self, forKey: .when)
        jsonIsland = try container.decodeIfPresent(String.self, forKey: .jsonIsland)
        maxBytes = try Self.clampedMaxBytes(container.decodeIfPresent(Int.self, forKey: .maxBytes))
        // Absent vs present-empty is meaningful for scoped fields ([] means
        // "extract nothing here"), so these stay optionals. Elements decode
        // leniently like their source-level twins.
        fields = try container.decodeIfPresent([ELVFieldSpec].self, forKey: .fields)
        collections = try container.decodeIfPresent([ELVCollectionSpec].self, forKey: .collections)
        settle = try container.decodeIfPresent(ELVSettlePolicy.self, forKey: .settle)
        // A malformed capture drops the capture, never the whole source
        //: the step still fetches, only the canonical-URL watch is lost.
        captureCanonical = (try? container.decodeIfPresent(ELVCanonicalCapture.self, forKey: .captureCanonical)) ?? nil
        regions = try container.elvStringList(forKey: .regions)
    }

    /// Whether this step runs for an input, given what the steps before it
    /// did: the URL-shape precondition (`when.hostMatches` / `pathRegex`)
    /// scopes the step from the first step on, and response conditions gate
    /// only a step after one that produced. A dangling named-trigger
    /// reference never admits. The one rule the pipeline and the offline
    /// preview share, so a preview's "a fetch would run" never disagrees
    /// with the run.
    public func permits(url: URL, didProduce: Bool, lastStatus: Int, extracted: [String: ELVValue], brand: String? = nil) -> Bool {
        guard let trigger = when else { return true }
        if trigger.ref != nil { return false }
        guard trigger.urlPermits(url) else { return false }
        if didProduce, trigger.hasResponseConditions {
            return trigger.fires(status: lastStatus, extractedFields: extracted, brand: brand)
        }
        return true
    }

    /// The pack-numeric clamp for byte budgets: non-positive degrades
    /// to absent, the ceiling is the transport's; the fetcher re-clamps as
    /// defense in depth. Shared by the step and plan decoders.
    static func clampedMaxBytes(_ authored: Int?) -> Int? {
        authored.flatMap { $0 <= 0 ? nil : min($0, 10_000_000) }
    }
}

/// A source's fetch plan: a single mode or an ordered `composite` of steps.
public struct ELVFetchPlan: Sendable, Decodable, Equatable {
    public var mode: String
    public var ua: String?
    public var url: String?
    public var referer: String?
    public var format: String?
    public var jsonIsland: String?
    /// Plan-level byte budget: lifted into the one resolved step of a
    /// single-mode plan, like `ua` and `jsonIsland`. Composite plans set it
    /// per step. (Scoped `fields`/`collections` are deliberately NOT
    /// mirrored here — a single-mode plan's scoped ladder would be
    /// indistinguishable from `source.fields`, i.e. dead surface.)
    public var maxBytes: Int?
    public var steps: [ELVFetchStep]
    public var settle: ELVSettlePolicy?
    public var captureCanonical: ELVCanonicalCapture?
    /// A single-mode dom plan's regions, lifted into its one step.
    public var regions: [String]

    public init(
        mode: String,
        ua: String? = nil,
        url: String? = nil,
        referer: String? = nil,
        format: String? = nil,
        jsonIsland: String? = nil,
        maxBytes: Int? = nil,
        steps: [ELVFetchStep] = [],
        settle: ELVSettlePolicy? = nil,
        captureCanonical: ELVCanonicalCapture? = nil,
        regions: [String] = []
    ) {
        self.mode = mode
        self.ua = ua
        self.url = url
        self.referer = referer
        self.format = format
        self.jsonIsland = jsonIsland
        self.maxBytes = maxBytes
        self.steps = steps
        self.settle = settle
        self.captureCanonical = captureCanonical
        self.regions = regions
    }

    /// `mode` is required in spirit: a plan that omits it decodes as
    /// `ELVFetchModes.unsupported` (see `ELVFetchStep`), never as a default
    /// transport.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        mode = try container.decodeIfPresent(String.self, forKey: .init("mode")) ?? ELVFetchModes.unsupported
        ua = try container.decodeIfPresent(String.self, forKey: .init("ua"))
        url = try container.decodeIfPresent(String.self, forKey: .init("url"))
        referer = try container.decodeIfPresent(String.self, forKey: .init("referer"))
        format = try container.decodeIfPresent(String.self, forKey: .init("format"))
        jsonIsland = try container.decodeIfPresent(String.self, forKey: .init("jsonIsland"))
        maxBytes = try ELVFetchStep.clampedMaxBytes(container.decodeIfPresent(Int.self, forKey: .init("maxBytes")))
        steps = try container.decodeIfPresent([ELVFetchStep].self, forKey: .init("steps")) ?? []
        settle = try container.decodeIfPresent(ELVSettlePolicy.self, forKey: .init("settle"))
        // Same containment as the step-level site: a bad capture costs the
        // capture only.
        captureCanonical = (try? container.decodeIfPresent(ELVCanonicalCapture.self, forKey: .init("captureCanonical"))) ?? nil
        regions = try container.elvStringList(forKey: .init("regions"))
    }

    /// The flat step list: a single-mode plan is one step.
    public var resolvedSteps: [ELVFetchStep] {
        if mode == ELVFetchModes.composite, !steps.isEmpty { return steps }
        let step = ELVFetchStep(
            mode: mode, ua: ua, url: url, referer: referer, format: format, jsonIsland: jsonIsland,
            maxBytes: maxBytes, settle: settle, captureCanonical: captureCanonical, regions: regions
        )
        return [step]
    }

    /// Every fetch mode this plan can use. `none` needs no capability:
    /// every binary can extract from the URL alone.
    public var requiredModes: Set<String> {
        Set(resolvedSteps.map(\.mode)).subtracting([ELVFetchModes.none])
    }

    /// The modes a binary must provide to load the source at all (capability
    /// gating): the first step's, and every step that always runs. A
    /// conditional step after the first (an escalation behind `when`) only
    /// degrades without its mode — the pipeline skips a step it cannot run,
    /// so a binary without WebKit keeps the source's http rung instead of
    /// losing the source. A step that declares no mode always gates
    /// (`ELVFetchModes.unsupported`, which no binary provides): a missing
    /// transport is an authoring error, never a silent skip.
    public var gatingModes: Set<String> {
        let gating = resolvedSteps.enumerated().filter { index, step in
            index == 0 || step.when == nil || step.mode == ELVFetchModes.unsupported
        }.map(\.element.mode)
        return Set(gating).subtracting([ELVFetchModes.none])
    }
}
