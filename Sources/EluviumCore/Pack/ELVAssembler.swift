import Foundation

/// Stage ⑤: turn extraction results into an `ELVRecord` — fields, child
/// collections, declared identities, and the metadata conventions
/// (`externalId` is a field name convention: extracted as a field, promoted
/// to record metadata, and kept out of `fields`). Every entry point builds
/// through the one `makeRecord` core, so promotion, kind resolution, and
/// identity hygiene (trim, drop-empty, dedup) are identical whether a
/// record came from a page, a list item, an archive row, or a child
/// collection.
public enum ELVAssembler {
    /// Assembles the full-page record. `preExtracted` lets the pipeline
    /// hand over the field result it already computed for escalation
    /// checks, so fields are not extracted twice per record;
    /// `extraCollections` carries step-scoped collection results, which
    /// override the source-level collection of the same name (step-
    /// scoped is more specific than the source level evaluated against the
    /// final context).
    public static func assemble(source: ELVSource, context: ELVExtractionContext, preExtracted: ELVExtractor.FieldResult? = nil, extraCollections: [String: [ELVRecord]] = [:]) -> ELVRecord {
        var result = preExtracted ?? ELVExtractor.extract(fields: source.fields, context: context)
        applyLabel(source: source, paste: context.paste, to: &result)
        var context = context
        context.fields = result.values

        var collections = assembleCollections(source.collections, source: source, context: context)

        // A list source resolved as a single page (tapped or pasted
        // directly rather than walked by the enumerator): its `rows` specs
        // still describe this page's items, so surface them as a collection
        // instead of assembling an empty record.
        if collections["items"] == nil, let list = source.list,
           case let .json(path) = list.items, let root = context.document.json {
            let items = ELVJSONPath(path).evaluate(root).compactMap { assembleItem(source: source, itemJSON: $0, url: context.url) }
            if !items.isEmpty { collections["items"] = items }
        }

        for (name, records) in extraCollections {
            collections[name] = records
        }

        // Generic-floor fallback: a source with no externalId spec
        // would otherwise produce records that never dedup on re-import and
        // cannot join the entity graph. The URL is the only stable handle a
        // floor has, hashed so the key stays short and uniform, with its
        // tracking params stripped first (`ELVCanonicalizeRule
        // .trackingParams`) so one page shared through two campaigns keys
        // once. No emptiness guard here: floors legitimately return empty
        // records the pipeline's `isEmptyFloorRecord` inspects.
        return makeRecord(
            source: source,
            result: result,
            context: context,
            authoredKind: source.kind,
            sourceURL: context.url,
            collections: collections,
            fallbackExternalId: context.url.map { "url:" + ELVStableHash.fnv1a(ELVCanonicalizeRule.strippingTracking($0).absoluteString) }
        )
    }

    /// Assembles one JSON list/archive item into a shallow record using the
    /// source's `rows` specs (enumeration pages, JSON archives).
    public static func assembleItem(source: ELVSource, itemJSON: ELVRawJSON, url: URL? = nil) -> ELVRecord? {
        let context = ELVExtractionContext(url: url, document: ELVDocument(json: itemJSON))
        let result = ELVExtractor.extract(fields: source.rows, context: context)
        guard !result.values.isEmpty else { return nil }
        return makeRecord(source: source, result: result, context: context, authoredKind: source.kind, sourceURL: url)
    }

    /// Evaluates a bare selector against a context and returns its single
    /// string form — the public seam list drivers use for `total` counts.
    public static func evaluateString(_ selector: ELVSelector, context: ELVExtractionContext) -> String? {
        ELVSelectorEngine.evaluate(selector, context: context)?.singleString
    }

    /// Assembles one archive row into a child record using the
    /// source's `rows` specs.
    public static func assembleRow(source: ELVSource, row: [String: String], context: ELVExtractionContext) -> ELVRecord? {
        var rowContext = context
        rowContext.document.row = row
        let result = ELVExtractor.extract(fields: source.rows, context: rowContext)
        guard !result.values.isEmpty else { return nil }
        return makeRecord(source: source, result: result, context: rowContext, authoredKind: source.kind, sourceURL: rowContext.url)
    }

    /// Assembles collection specs against one context: the seam both
    /// `assemble` (source-level collections against the final context) and
    /// the pipeline (step-scoped collections against their own step's
    /// context) share. `context.fields` should already carry the field
    /// result so `$field` candidates in item ladders resolve.
    public static func assembleCollections(_ specs: [ELVCollectionSpec], source: ELVSource, context: ELVExtractionContext) -> [String: [ELVRecord]] {
        var collections: [String: [ELVRecord]] = [:]
        for spec in specs {
            let children = assembleCollection(spec, source: source, context: context)
            if !children.isEmpty { collections[spec.name] = children }
        }
        return collections
    }

    private static func assembleCollection(_ spec: ELVCollectionSpec, source: ELVSource, context: ELVExtractionContext) -> [ELVRecord] {
        let items: [ELVRawJSON]
        if let entries = spec.entries {
            // The pack IS the list (inline rankings): entries win over
            // `from`, which the validator flags when both are authored.
            items = entries
        } else {
            switch spec.rows {
            case let .json(path):
                guard let root = context.document.json else { return [] }
                items = ELVJSONPath(path).evaluate(root)
            case let .jsonld(path):
                // A JSON-LD collection selects array members under a typed node.
                guard let extracted = ELVSelectorEngine.evaluate(.jsonld(path), context: context),
                      case let .json(value) = extracted else { return [] }
                items = value.arrayValue ?? [value]
            case let .regexRows(pattern, after):
                items = regexRows(pattern: pattern, after: after, in: context.document.html ?? context.document.text)
            case .unresolvable:
                // A value selector or malformed `from` never drives rows;
                // the validator names it, the collection stays empty.
                return []
            }
        }

        return items.compactMap { item in
            let itemContext = ELVExtractionContext(url: context.url, params: context.params, document: ELVDocument(json: item))
            let result = ELVExtractor.extract(fields: spec.item, context: itemContext)
            guard !result.values.isEmpty else { return nil }
            // Per-collection identity specs only: the parent's specs
            // do not run for items — a URL-derived parent id (the album's
            // Spotify id) must never become every child's identity.
            return makeRecord(source: source, result: result, context: itemContext, authoredKind: spec.kind ?? source.kind, sourceURL: nil, identitySpecs: spec.identities)
        }
    }

    /// Rows regex-matched out of the document's raw markup: one row per
    /// match, capture groups keyed `g1`…`gN` plus a 1-based `rank` from
    /// document order, so item specs select with ordinary json paths.
    /// Bounded twice: the input is cut at `ELVRegexCache.inputCap` like
    /// every pack-regex evaluation, and the row count stops at
    /// `regexRowCap` via `enumerateMatches`' stop flag, so the scan ends at
    /// the cap instead of collecting every match first. An `after` anchor
    /// moves where the capped window starts (a server-rendered data blob
    /// past the cap on a large page), never how long it is.
    private static let regexRowCap = 500

    private static func regexRows(pattern: String, after: String?, in text: String?) -> [ELVRawJSON] {
        guard let text, let regex = ELVRegexCache.regex(pattern) else { return [] }
        let bounded: String
        if let after {
            guard !after.isEmpty, let anchor = text.range(of: after) else { return [] }
            // Cut before copying: the tail past the anchor can be megabytes.
            bounded = String(text[anchor.lowerBound...].prefix(ELVRegexCache.inputCap))
        } else {
            bounded = ELVRegexCache.boundedInput(text)
        }
        let nsText = bounded as NSString
        // A scan that runs out of the evaluation budget yields no rows rather
        // than a partial list that reads as the page's whole collection.
        guard let matches = ELVRegexCache.boundedMatches(of: regex, in: bounded, limit: regexRowCap) else { return [] }
        return matches.enumerated().map { index, match in
            var object: [String: ELVRawJSON] = ["rank": .number(Double(index + 1))]
            for group in 1 ..< match.numberOfRanges where match.range(at: group).location != NSNotFound {
                object["g\(group)"] = .string(nsText.substring(with: match.range(at: group)))
            }
            return .object(object)
        }
    }

    // MARK: - Helpers

    /// The label ladder: writes the winner to `label` (provenance
    /// `label:<origin>`). The brand is the record's own `brand` field when a
    /// multi-brand source extracts one, else the source title.
    private static func applyLabel(source: ELVSource, paste: ELVPasteContext?, to result: inout ELVExtractor.FieldResult) {
        guard !source.label.isEmpty else { return }
        let brand = result.values["brand"].flatMap { ELVSelectorEngine.stringForm(of: $0)?.singleString } ?? source.title
        let ladder = source.label.compactMap { name -> (field: String, value: String)? in
            guard let value = result.values[name], let text = ELVSelectorEngine.stringForm(of: value)?.singleString else { return nil }
            return (name, text)
        }
        guard let resolution = ELVLabelResolver.resolve(userLabel: paste?.userLabel, ladder: ladder, brand: brand) else { return }
        result.values["label"] = .text(resolution.value)
        result.provenance["label"] = ELVProvenance(origin: "label:\(resolution.origin)")
    }

    /// The one record constructor behind every entry point: enriches the
    /// context with the field result, promotes `externalId` (falling back to
    /// the caller's handle, e.g. the floor pass's URL hash), resolves the
    /// kind, and evaluates identities. Differences between entry points stay
    /// at their call sites by design — this core is the shared invariant.
    private static func makeRecord(
        source: ELVSource,
        result: ELVExtractor.FieldResult,
        context: ELVExtractionContext,
        authoredKind: String,
        sourceURL: URL?,
        collections: [String: [ELVRecord]] = [:],
        fallbackExternalId: String? = nil,
        identitySpecs: [ELVIdentitySpec]? = nil
    ) -> ELVRecord {
        var context = context
        context.fields = result.values

        var fields = result.values
        var provenance = result.provenance
        let externalId = promoteExternalId(fields: &fields, provenance: &provenance) ?? fallbackExternalId
        if source.imageReferer == "page", let referer = context.url ?? sourceURL {
            fields = fields.mapValues { stampMediaReferer($0, referer: referer) }
        }
        return ELVRecord(
            sourceId: source.id,
            sourceURL: sourceURL,
            externalId: externalId,
            kind: resolvedKind(authored: authoredKind, inference: source.inference, context: context),
            fields: fields,
            collections: collections,
            identities: makeIdentities(specs: identitySpecs ?? source.identities, context: context),
            provenance: provenance
        )
    }

    /// Kind inference: the pack's tables may suggest a kind from the
    /// extracted evidence, and the suggestion fills ONLY an absent kind —
    /// an authored `kind` always wins, and unmatched evidence leaves the
    /// kind empty rather than guessing (TripDays parity: never a wrong
    /// default). `context.fields` must already carry the extraction result,
    /// which `makeRecord` guarantees.
    private static func resolvedKind(authored: String, inference: ELVInferenceSpec?, context: ELVExtractionContext) -> String {
        guard authored.isEmpty, let inference else { return authored }
        return inference.suggestedKind(context: context) ?? authored
    }

    /// The `imageReferer: "page"` stamp: media refs gain the page URL as
    /// their fetch-time Referer so consumers can satisfy hotlink protection.
    /// Values already carrying one keep it.
    private static func stampMediaReferer(_ value: ELVValue, referer: URL) -> ELVValue {
        switch value {
        case var .media(ref) where ref.referer == nil:
            ref.referer = referer
            return .media(ref)
        case let .list(values):
            return .list(values.map { stampMediaReferer($0, referer: referer) })
        default:
            return value
        }
    }

    /// Pops the `externalId` convention field (and its provenance) out of
    /// the extracted set and returns its string form for record metadata.
    private static func promoteExternalId(fields: inout [String: ELVValue], provenance: inout [String: ELVProvenance]) -> String? {
        guard let idValue = fields.removeValue(forKey: "externalId") else { return nil }
        provenance.removeValue(forKey: "externalId")
        return ELVSelectorEngine.stringForm(of: idValue)?.singleString
    }

    /// Evaluates identity specs against `context`: trimmed, empty-dropped,
    /// deduplicated. One implementation for every entry point — an identity
    /// from a row must behave exactly like one from a page.
    private static func makeIdentities(specs: [ELVIdentitySpec], context: ELVExtractionContext) -> [ELVIdentity] {
        var identities: [ELVIdentity] = []
        for spec in specs {
            guard let value = ELVSelectorEngine.evaluate(spec.from, context: context)?.singleString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            let identity = ELVIdentity(namespace: spec.namespace, value: value, origin: .declared)
            if !identities.contains(identity) { identities.append(identity) }
        }
        return identities
    }
}
