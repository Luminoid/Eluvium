import Foundation

/// What a full pipeline run would still add to a preview.
public struct ELVPreviewPending: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A redirector must chase the link before its source is known.
    public static let redirect = Self(rawValue: 1 << 0)
    /// A fetch step (http, json, feed, dom) would run.
    public static let fetch = Self(rawValue: 1 << 1)
    /// An async platform lookup (MapKit) would fill a field the preview
    /// could not.
    public static let platformLookup = Self(rawValue: 1 << 2)
    /// No source recognized the link; a generic floor would fetch it.
    public static let floor = Self(rawValue: 1 << 3)
}

/// The synchronous, offline reading of an input: recognition plus every
/// field the URL and the paste alone can fill, assembled into a record
/// (label resolved), with what a full run would add. No I/O and no async
/// op runs, so a host can show the brand, kind, label, and URL-borne pin
/// the moment text is pasted, then `run` the same input for the rest.
public struct ELVPreview: Sendable, Equatable {
    /// The URL-and-paste record. For an unrecognized link it is a floor
    /// card whose label is the host.
    public var record: ELVRecord
    /// The source that recognized the link; nil for an unrecognized one.
    public var sourceId: String?
    /// For a redirector, the source its `previewAs` hint names for this
    /// short host (`abnb.me` → `airbnb.lodging`); `record` is that source's
    /// URL-only reading.
    public var provisionalSourceId: String?
    public var pending: ELVPreviewPending

    public init(record: ELVRecord, sourceId: String?, provisionalSourceId: String? = nil, pending: ELVPreviewPending) {
        self.record = record
        self.sourceId = sourceId
        self.provisionalSourceId = provisionalSourceId
        self.pending = pending
    }

    /// Whether running the input through the pipeline could add anything.
    public var needsFullRun: Bool {
        !pending.isEmpty
    }
}

public extension ELVLoadedPack {
    /// The paste policy for this pack: the standard one plus every app
    /// scheme its scheme-matched sources claim, so `ELVPastedInput.parse`
    /// accepts exactly the app links this pack can read.
    var pastePolicy: ELVPastePolicy {
        var policy = ELVPastePolicy.standard
        for scheme in sources.flatMap({ $0.match?.schemes ?? [] }) where !policy.schemes.contains(scheme) {
            policy.schemes.append(scheme)
        }
        return policy
    }

    /// The offline preview of `input`: synchronous, no network, no async
    /// ops. `userLabel` is a label the host's user typed; it wins the label
    /// ladder exactly as it would in a full run.
    func preview(_ input: ELVPastedInput, userLabel: String? = nil) -> ELVPreview {
        preview(url: ELVURLPolicy.httpsUpgraded(input.url), paste: ELVPasteContext(input: input, userLabel: userLabel))
    }

    /// The preview of an already-upgraded `url` under an existing paste
    /// context: the pipeline's reading of a link a redirector just expanded,
    /// with the original paste's name and stats still in play.
    package func preview(url: URL, paste: ELVPasteContext?) -> ELVPreview {
        guard let recognition = registry.recognize(url), let source = source(withId: recognition.sourceId) else {
            return floorPreview(url: url, paste: paste)
        }
        if source.resolvesVia != nil {
            let host = url.host?.lowercased() ?? ""
            let hinted = source.previewAs.first { ELVHostMatcher.hostMatches(host, pattern: $0.key) }
                .flatMap { self.source(withId: $0.value) }
            guard let hinted else {
                let record = ELVRecord(sourceId: source.id, sourceURL: url, kind: source.kind)
                return ELVPreview(record: record, sourceId: source.id, pending: .redirect)
            }
            // The hinted source reads the SHORT link: its path rules and
            // URL candidates mostly miss, so the record is its brand and
            // kind plus whatever the paste names.
            let reading = urlOnlyReading(source: hinted, url: url, params: [:], paste: paste)
            return ELVPreview(record: reading.record, sourceId: source.id, provisionalSourceId: hinted.id, pending: .redirect)
        }
        let reading = urlOnlyReading(source: source, url: url, params: recognition.params, paste: paste)
        return ELVPreview(record: reading.record, sourceId: source.id, pending: reading.pending)
    }

    /// Runs the source's leading `none` steps (or, for a source that
    /// fetches first, its ladder over an empty document) and reports which
    /// later steps and lookups a full run would add.
    private func urlOnlyReading(source: ELVSource, url: URL, params: [String: String], paste: ELVPasteContext?) -> (record: ELVRecord, pending: ELVPreviewPending) {
        let canonical = source.canonicalize?.apply(to: url) ?? url
        var paste = paste
        paste?.brand = source.title
        let context = ELVExtractionContext(url: canonical, params: params, paste: paste)
        let steps = source.fetch?.resolvedSteps ?? [ELVFetchStep(mode: ELVFetchModes.http)]

        var extracted = ELVExtractor.FieldResult()
        var didProduce = false
        var index = 0
        while index < steps.count, steps[index].mode == ELVFetchModes.none {
            let step = steps[index]
            index += 1
            guard step.permits(url: canonical, didProduce: didProduce, lastStatus: 200, extracted: extracted.values, brand: source.title) else { continue }
            let stepResult = ELVExtractor.extract(fields: step.fields ?? source.fields, context: context)
            extracted = didProduce ? Self.fillEmpty(extracted, with: stepResult) : stepResult
            didProduce = true
        }
        if !didProduce {
            // A source that fetches first still has URL- and paste-borne
            // candidates (a slug title, a share name); its page candidates
            // miss over the empty document.
            extracted = ELVExtractor.extract(fields: source.fields, context: context)
        }

        var pending: ELVPreviewPending = []
        let fetchModes = capabilities.fetchModes
        let wouldFetch = steps[index...].contains { step in
            step.mode != ELVFetchModes.none && fetchModes.contains(step.mode)
                && step.permits(url: canonical, didProduce: didProduce, lastStatus: 200, extracted: extracted.values, brand: source.title)
        }
        if wouldFetch { pending.insert(.fetch) }
        if hasPendingLookup(fields: source.fields, extracted: extracted, context: context) {
            pending.insert(.platformLookup)
        }

        var enriched = context
        enriched.fields = extracted.values
        let record = ELVAssembler.assemble(source: source, context: enriched, preExtracted: extracted)
        return (record, pending)
    }

    /// Whether some unfilled field has an async-only op candidate whose
    /// inputs already resolve: the lookup a full run would await.
    private func hasPendingLookup(fields: [ELVFieldSpec], extracted: ELVExtractor.FieldResult, context: ELVExtractionContext) -> Bool {
        var context = context
        context.fields = extracted.values
        for field in fields where extracted.values[field.name] == nil {
            for candidate in field.candidates {
                guard case let .native(op, input) = candidate.from,
                      ELVNativeOps.lookup(op) == nil, ELVNativeOps.lookupAsync(op) != nil,
                      ELVExtractor.resolveNativeInputs(input, context: context) != nil
                else { continue }
                return true
            }
        }
        return false
    }

    /// An unrecognized link: a card labeled by its host (`www.` dropped),
    /// keyed to the last generic floor (the OpenGraph card) when the pack
    /// has floors.
    private func floorPreview(url: URL, paste: ELVPasteContext?) -> ELVPreview {
        let floor = genericFloors.last
        var host = url.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let label = paste?.userLabel ?? host
        var fields: [String: ELVValue] = [:]
        var provenance: [String: ELVProvenance] = [:]
        if !label.isEmpty {
            fields["label"] = .text(label)
            provenance["label"] = ELVProvenance(origin: paste?.userLabel == nil ? "label:host" : "label:user")
        }
        let record = ELVRecord(sourceId: floor?.id ?? "", sourceURL: url, kind: floor?.kind ?? "link", fields: fields, provenance: provenance)
        return ELVPreview(record: record, sourceId: nil, pending: floor == nil ? [] : .floor)
    }

    /// The pipeline's composite merge: the later step wins where it
    /// produced; fields only the earlier one had carry forward.
    private static func fillEmpty(_ previous: ELVExtractor.FieldResult, with next: ELVExtractor.FieldResult) -> ELVExtractor.FieldResult {
        var result = next
        for (name, value) in previous.values where result.values[name] == nil {
            result.values[name] = value
            result.provenance[name] = previous.provenance[name]
        }
        return result
    }
}
