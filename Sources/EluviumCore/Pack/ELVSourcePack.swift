import Foundation

/// A child-collection spec: a selector that yields the item list and
/// per-item field specs.
public struct ELVCollectionSpec: Sendable, Decodable, Equatable {
    public var name: String
    public var from: ELVSelector
    public var item: [ELVFieldSpec]
    /// Child record kind; defaults to the parent source's kind.
    public var kind: String?
    /// Inline config rows: when present, each entry object IS an item's
    /// document JSON and `from` never runs — the pack itself is the list
    /// (editorial rankings with no fetchable API).
    public var entries: [ELVRawJSON]?
    /// Per-item identity specs, evaluated against each ITEM's
    /// context. The parent source's identity specs deliberately do not run
    /// for items: a track is not its album, so a URL-derived album id must
    /// never become every track's identity — explicit beats accidental.
    public var identities: [ELVIdentitySpec]

    public init(name: String, from: ELVSelector, item: [ELVFieldSpec], kind: String? = nil, entries: [ELVRawJSON]? = nil, identities: [ELVIdentitySpec] = []) {
        self.name = name
        self.from = from
        self.item = item
        self.kind = kind
        self.entries = entries
        self.identities = identities
    }

    private enum CodingKeys: String, CodingKey {
        case name, from, item, kind, entries, identities
    }

    /// Lenient like `ELVSource` itself: a missing key degrades this
    /// collection — no items, an unsupported selector the validator flags —
    /// instead of killing the whole source through synthesized `decode`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        from = try container.decodeIfPresent(ELVSelector.self, forKey: .from) ?? .unsupported(key: "(missing from)")
        item = try container.decodeIfPresent([ELVFieldSpec].self, forKey: .item) ?? []
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        entries = try container.decodeIfPresent([ELVRawJSON].self, forKey: .entries)
        identities = try container.decodeIfPresent([ELVIdentitySpec].self, forKey: .identities) ?? []
    }
}

/// The typed rows driver behind a collection's `from`. The wire form
/// stays `ELVSelector`'s single-key objects; this union is what the
/// assembler executes, so a value-shaped selector (`css`, `meta`, …) becomes
/// a named `unresolvable` the validator reports instead of a silent empty
/// collection.
enum ELVCollectionRows: Equatable {
    case json(path: String)
    case jsonld(path: String)
    case regexRows(pattern: String, after: String?)
    case unresolvable(reason: String)
}

extension ELVCollectionSpec {
    /// The rows driver `from` resolves to (`entries` still wins over it at
    /// assembly time).
    var rows: ELVCollectionRows {
        switch from {
        case let .json(path): .json(path: path)
        case let .jsonld(path): .jsonld(path: path)
        case let .regexRows(pattern, after): .regexRows(pattern: pattern, after: after)
        case let .unsupported(key): .unresolvable(reason: "unsupported selector \"\(key)\"")
        default: .unresolvable(reason: from.provenanceTag)
        }
    }
}

/// A declared identity extraction: namespace + where its value comes
/// from on this source's pages.
public struct ELVIdentitySpec: Sendable, Decodable, Equatable {
    public var namespace: String
    public var from: ELVSelector

    public init(namespace: String, from: ELVSelector) {
        self.namespace = namespace
        self.from = from
    }

    private enum CodingKeys: String, CodingKey {
        case namespace = "ns"
        case from
    }

    /// Lenient like `ELVSource` itself: a missing `ns` or `from`
    /// degrades this identity spec — it extracts nothing and the validator
    /// flags it — instead of killing the whole source.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try container.decodeIfPresent(String.self, forKey: .namespace) ?? ""
        from = try container.decodeIfPresent(ELVSelector.self, forKey: .from) ?? .unsupported(key: "(missing from)")
    }
}

/// One example input with its shallow expectation: resolved kind plus
/// a few key fields non-empty — deliberately not full golden output, so
/// examples survive cosmetic site changes.
public struct ELVExample: Sendable, Decodable, Equatable {
    public var input: String
    public var expectedKind: String?
    public var expectedNonEmpty: [String]
    /// Child collections (`expect.nonEmptyCollections`) the record must
    /// carry with at least one item: a list page's `items`, an album's
    /// `tracks`. Fields alone cannot say a collection driver still finds
    /// its rows.
    public var expectedNonEmptyCollections: [String]

    public init(input: String, expectedKind: String? = nil, expectedNonEmpty: [String] = [], expectedNonEmptyCollections: [String] = []) {
        self.input = input
        self.expectedKind = expectedKind
        self.expectedNonEmpty = expectedNonEmpty
        self.expectedNonEmptyCollections = expectedNonEmptyCollections
    }

    private enum CodingKeys: String, CodingKey {
        case input
        case expect
    }

    private enum ExpectKeys: String, CodingKey {
        case kind
        case nonEmpty
        case nonEmptyCollections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decode(String.self, forKey: .input)
        if let expect = try? container.nestedContainer(keyedBy: ExpectKeys.self, forKey: .expect) {
            expectedKind = try expect.decodeIfPresent(String.self, forKey: .kind)
            expectedNonEmpty = try expect.elvStringList(forKey: .nonEmpty)
            expectedNonEmptyCollections = try expect.elvStringList(forKey: .nonEmptyCollections)
        } else {
            expectedKind = nil
            expectedNonEmpty = []
            expectedNonEmptyCollections = []
        }
    }

    /// The declared expectations `record` fails, one readable line each
    /// (`kind trail (got product)`, `non-empty distance (missing)`,
    /// `non-empty collection tracks (empty)`); empty means the example
    /// passed. The one check behind the health run, a host's corpus screen,
    /// and its log, so they can never disagree.
    ///
    /// `externalId` reads the record's promoted id rather than `fields`
    /// (the assembler moves it out), and a `url:` hash id does not satisfy
    /// it: that is the floor's no-extraction fallback, not an extracted id.
    public func unmetExpectations(for record: ELVRecord) -> [String] {
        var unmet: [String] = []
        if let expectedKind, record.kind != expectedKind {
            unmet.append("kind \(expectedKind) (got \(record.kind))")
        }
        for key in expectedNonEmpty {
            if key == "externalId" {
                let id = record.externalId ?? ""
                if id.isEmpty || id.hasPrefix("url:") {
                    unmet.append("non-empty externalId (missing)")
                }
                continue
            }
            guard let value = record.fields[key] else {
                unmet.append("non-empty \(key) (missing)")
                continue
            }
            if value.isEmpty {
                unmet.append("non-empty \(key) (empty)")
            }
        }
        for name in expectedNonEmptyCollections {
            guard let children = record.collections[name] else {
                unmet.append("non-empty collection \(name) (missing)")
                continue
            }
            if children.isEmpty {
                unmet.append("non-empty collection \(name) (empty)")
            }
        }
        return unmet
    }
}

/// One source definition: match rules, fetch plan, extraction specs,
/// identities, capability requirements, and the example corpus. Unknown
/// keys are ignored on decode (additive schema evolution).
///
/// The whole pack grammar is `Decodable`-only: this binary tolerates keys it
/// does not model (that is the contract), so re-encoding a decoded
/// source would silently strip everything a newer author wrote. Packs flow
/// one way — authored, compiled, decoded here. Records (`ELVRecord` /
/// `ELVValue`) are the round-trip types and keep full `Codable` with
/// explicit unknown-preservation.
public struct ELVSource: Sendable, Decodable, Equatable {
    public var id: String
    /// Human-readable name for host UI ("Google Maps"); `id` is the stable
    /// machine handle. Optional — display falls back to `id`.
    public var title: String?
    public var kind: String
    public var match: ELVMatchRule?
    public var canonicalize: ELVCanonicalizeRule?
    public var fetch: ELVFetchPlan?
    public var fields: [ELVFieldSpec]
    /// Per-row field specs for archive sources.
    public var rows: [ELVFieldSpec]
    public var collections: [ELVCollectionSpec]
    public var identities: [ELVIdentitySpec]
    /// Kind-inference tables: extracted evidence → suggested kind,
    /// consulted only when this source authors no `kind`.
    public var inference: ELVInferenceSpec?
    /// Capabilities this source needs (`fetch:dom`, `native:op@2`). A binary
    /// that cannot meet one skips the source rather than half-working.
    public var requires: [String]
    /// Pack-level fragment names this source pulls in: the loader
    /// resolves them before validation and gating — the fragment's fetch
    /// plan fills an absent one, its fields append after the source's own
    /// (same-name fields merge candidate lists source-first). The names stay
    /// here after resolution so the validator can flag unknown references.
    public var use: [String]
    public var minBinary: String?
    public var examples: [ELVExample]
    /// Enumeration spec: this source produces a paginated list.
    public var list: ELVListSpec?
    /// A native-op reference (`shortlink.expand`) marking this source as a
    /// pure redirector: stage ② runs the op on the URL and the expanded URL
    /// re-enters recognition. Redirector sources extract nothing
    /// themselves.
    public var resolvesVia: String?
    /// A pack-authored browse entry URL (egress-reviewed like any step
    /// URL): hosts list seeded sources as browsable inventory and start
    /// them via `runSeed` without recognition. A seeded source with no
    /// `match` is browse-only — never a generic floor.
    public var seed: String?
    /// Hotlink-protection escape hatch: `"page"` stamps the record's page
    /// URL as `referer` on every assembled media ref, so consumers fetching
    /// the image can send the Referer the origin demands (Douban 418s bare
    /// image fetches). Unknown values are ignored with a validator note.
    public var imageReferer: String?
    /// The label ladder (schemaMinor 5): field names in precedence order.
    /// When declared, the assembler writes the winning value to the
    /// record's `label` field (`ELVLabelResolver`); absent, the source's
    /// records carry no `label`.
    public var label: [String]
    /// A redirector's offline stand-in (schemaMinor 5): short-link host →
    /// the source its links expand to (`abnb.me` → `airbnb.lodging`), so a
    /// preview can show the brand and kind before the chase runs.
    public var previewAs: [String: String]

    public init(
        id: String,
        title: String? = nil,
        kind: String,
        match: ELVMatchRule? = nil,
        canonicalize: ELVCanonicalizeRule? = nil,
        fetch: ELVFetchPlan? = nil,
        fields: [ELVFieldSpec] = [],
        rows: [ELVFieldSpec] = [],
        collections: [ELVCollectionSpec] = [],
        identities: [ELVIdentitySpec] = [],
        inference: ELVInferenceSpec? = nil,
        requires: [String] = [],
        use: [String] = [],
        minBinary: String? = nil,
        examples: [ELVExample] = [],
        list: ELVListSpec? = nil,
        resolvesVia: String? = nil,
        seed: String? = nil,
        imageReferer: String? = nil,
        label: [String] = [],
        previewAs: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.match = match
        self.canonicalize = canonicalize
        self.fetch = fetch
        self.fields = fields
        self.rows = rows
        self.collections = collections
        self.identities = identities
        self.inference = inference
        self.requires = requires
        self.use = use
        self.minBinary = minBinary
        self.examples = examples
        self.list = list
        self.resolvesVia = resolvesVia
        self.seed = seed
        self.imageReferer = imageReferer
        self.label = label
        self.previewAs = previewAs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        id = try container.decode(String.self, forKey: .init("id"))
        title = try container.decodeIfPresent(String.self, forKey: .init("title"))
        kind = try container.decodeIfPresent(String.self, forKey: .init("kind")) ?? ""
        match = try container.decodeIfPresent(ELVMatchRule.self, forKey: .init("match"))
        canonicalize = try container.decodeIfPresent(ELVCanonicalizeRule.self, forKey: .init("canonicalize"))
        fetch = try container.decodeIfPresent(ELVFetchPlan.self, forKey: .init("fetch"))
        fields = try container.decodeIfPresent([ELVFieldSpec].self, forKey: .init("fields")) ?? []
        rows = try container.decodeIfPresent([ELVFieldSpec].self, forKey: .init("rows")) ?? []
        collections = try container.decodeIfPresent([ELVCollectionSpec].self, forKey: .init("collections")) ?? []
        identities = try container.decodeIfPresent([ELVIdentitySpec].self, forKey: .init("identities")) ?? []
        // A structurally malformed inference (not an object) costs the
        // inference only, never the source — the captureCanonical
        // containment. Malformation inside the object degrades per table
        // with notes the validator surfaces.
        inference = (try? container.decodeIfPresent(ELVInferenceSpec.self, forKey: .init("inference"))) ?? nil
        requires = try container.elvStringList(forKey: .init("requires"))
        use = try container.elvStringList(forKey: .init("use"))
        minBinary = try container.decodeIfPresent(String.self, forKey: .init("minBinary"))
        examples = try container.decodeIfPresent([ELVExample].self, forKey: .init("examples")) ?? []
        list = try container.decodeIfPresent(ELVListSpec.self, forKey: .init("list"))
        resolvesVia = try container.decodeIfPresent(String.self, forKey: .init("resolvesVia"))
        seed = try container.decodeIfPresent(String.self, forKey: .init("seed"))
        imageReferer = try container.decodeIfPresent(String.self, forKey: .init("imageReferer"))
        label = try container.elvStringList(forKey: .init("label"))
        // A malformed table (not a string map) costs the hint only.
        previewAs = (try? container.decodeIfPresent([String: String].self, forKey: .init("previewAs"))) ?? [:]
    }
}

/// A reusable slice of source config a pack declares once under
/// `"fragments"` and sources pull in by name via `"use"`. Carries only the
/// pieces that repeat across sources today (a fetch plan, field ladders);
/// grows keys as duplication appears, never speculatively (schema honesty).
public struct ELVSourceFragment: Sendable, Decodable, Equatable {
    public var fetch: ELVFetchPlan?
    public var fields: [ELVFieldSpec]

    public init(fetch: ELVFetchPlan? = nil, fields: [ELVFieldSpec] = []) {
        self.fetch = fetch
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        fetch = try container.decodeIfPresent(ELVFetchPlan.self, forKey: .init("fetch"))
        fields = try container.decodeIfPresent([ELVFieldSpec].self, forKey: .init("fields")) ?? []
    }

    /// A fragment providing nothing resolves to nothing; the validator
    /// surfaces it.
    public var isEmpty: Bool {
        fetch == nil && fields.isEmpty
    }
}

/// The compiled pack: schema version pair, pack version, and sources in
/// declaration order (which is evaluation order everywhere).
///
/// `Decodable`-only, like `ELVSource` and for the same reason: the decoder
/// drops unknown future keys by design, so an encode would produce a pack
/// that lies about what its author wrote. Nothing load-bearing re-encodes
/// packs; persistence keeps the verified original bytes.
public struct ELVSourcePack: Sendable, Decodable, Equatable {
    /// The grammar major: a pack whose major this binary does not know is
    /// rejected whole by the loader (a major bump means existing keys
    /// changed meaning).
    public var schemaVersion: Int
    /// The grammar minor: additive vocabulary. A pack declaring a minor
    /// newer than `ELVPackLoader.supportedSchemaMinor` still loads (the
    /// unknown vocabulary degrades per source) and the loader notes it once.
    public var schemaMinor: Int
    /// The pack's own version string, required: it names the pack in
    /// diagnostics, merges (the overlay's wins), and remote-pack caching.
    public var packVersion: String
    /// Named config fragments sources reference via `use` (resolved by the
    /// loader before validation and capability gating).
    public var fragments: [String: ELVSourceFragment]
    /// Named escalation triggers steps reference via the string form of
    /// `when` (resolved by the loader like fragments). One shared
    /// blocked-or-thin condition beats eleven verbatim copies drifting.
    public var triggers: [String: ELVEscalationTrigger]
    /// Identity namespaces this pack declares strong: two records
    /// sharing a declared or crosswalk identity in one of them are the same
    /// thing and auto-link. Append-only by construction: a pack can only add
    /// namespaces to the binary's `ELVIdentityNamespaces.builtinStrong`,
    /// never demote one. Hosts feed the loaded set to their index with
    /// `index.addStrongNamespaces(pack.strongNamespaces)` on the
    /// `ELVLoadedPack`. (The `aliasOf` rename table is not
    /// implemented: a renamed namespace is a new one.)
    public var strongNamespaces: [String]
    public var sources: [ELVSource]
    /// Sources dropped during decode, one note each (a structurally
    /// broken source costs itself, never the pack). Decode-only bookkeeping;
    /// not part of the wire format.
    public var decodeIssues: [String]

    public init(
        schemaVersion: Int,
        schemaMinor: Int = 0,
        packVersion: String,
        fragments: [String: ELVSourceFragment] = [:],
        triggers: [String: ELVEscalationTrigger] = [:],
        strongNamespaces: [String] = [],
        sources: [ELVSource],
        decodeIssues: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.schemaMinor = schemaMinor
        self.packVersion = packVersion
        self.fragments = fragments
        self.triggers = triggers
        self.strongNamespaces = strongNamespaces
        self.sources = sources
        self.decodeIssues = decodeIssues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        schemaVersion = try container.decode(Int.self, forKey: .init("schemaVersion"))
        schemaMinor = try container.decodeIfPresent(Int.self, forKey: .init("schemaMinor")) ?? 0
        packVersion = try container.decode(String.self, forKey: .init("packVersion"))

        var fragmentIssues: [String] = []
        do {
            fragments = try container.decodeIfPresent([String: ELVSourceFragment].self, forKey: .init("fragments")) ?? [:]
        } catch {
            // The sources containment, one level up: a structurally broken
            // fragments block costs the fragments, never the pack. Sources
            // that `use` a lost fragment keep their own config and the
            // validator flags the dangling names.
            fragments = [:]
            fragmentIssues.append("fragments dropped: \(Self.describe(error))")
        }
        do {
            triggers = try container.decodeIfPresent([String: ELVEscalationTrigger].self, forKey: .init("triggers")) ?? [:]
        } catch {
            // Same containment: a broken triggers block costs the block;
            // steps referencing a lost name stay conditional-and-unresolved,
            // which never admits, and the loader names them.
            triggers = [:]
            fragmentIssues.append("triggers dropped: \(Self.describe(error))")
        }
        do {
            strongNamespaces = try container.elvStringList(forKey: .init("strongNamespaces"))
        } catch {
            // A malformed list (an object, mixed types) costs the list,
            // never the pack: no namespace is promoted, which only means
            // fewer auto-links (skip beats wrong).
            strongNamespaces = []
            fragmentIssues.append("strongNamespaces dropped: \(Self.describe(error))")
        }

        var decoded: [ELVSource] = []
        var issues: [String] = fragmentIssues
        if container.contains(.init("sources")), var list = try? container.nestedUnkeyedContainer(forKey: .init("sources")) {
            while !list.isAtEnd {
                let index = list.currentIndex
                do {
                    try decoded.append(list.decode(ELVSource.self))
                } catch {
                    // Consume the bad element as raw JSON (which always
                    // succeeds and advances the container), salvage its id
                    // for the note, and move on.
                    let raw = try? list.decode(ELVRawJSON.self)
                    guard list.currentIndex > index else { break }
                    let id = raw?.objectValue?["id"]?.stringValue.map { " (id \"\($0)\")" } ?? ""
                    issues.append("sources[\(index)]\(id) dropped: \(Self.describe(error))")
                }
            }
        }
        sources = decoded
        decodeIssues = issues
    }

    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return String(describing: error) }
        switch decodingError {
        case let .keyNotFound(key, _): return "missing key \"\(key.stringValue)\""
        case let .typeMismatch(_, context), let .dataCorrupted(context), let .valueNotFound(_, context): return context.debugDescription
        @unknown default: return String(describing: decodingError)
        }
    }
}
