import EluviumCore
import Foundation

/// Staged progress a host can render while the pipeline runs (Paste
/// screen).
public enum ELVPipelineStage: String, Sendable {
    case recognize
    case fetch
    case extract
    case assemble
}

/// The outcome of running an input through the pipeline.
public enum ELVPipelineResult: Sendable {
    case record(ELVRecord)
    /// Nothing matched — the caller may fall to a generic floor.
    case unrecognized
    /// `sourceId` names the source that claimed the URL before failing, so
    /// hosts can log which parser owned the miss.
    case failed(ELVFetchFailure, sourceId: String?)
}

/// Stages ①→⑤ for a single URL input: recognition, the source's fetch plan
/// over the `http` / `json` / `feed` transports (with `dom` steps run
/// through the injected renderer and composite plans escalating step by
/// step), extraction, and assembly. Native escalation (MapKit lookups) is
/// the Places layer's job; the pipeline only awaits the ops a host
/// registered.
///
/// Every run returns an `ELVPipelineRun`: the result plus an `ELVRunTrace`
/// of what ran (each step's host, status, bytes, truncation, settle state,
/// duration, and outcome; declined and skipped steps; missed fields with
/// the candidates tried). The run's log line is rendered from that trace.
public struct ELVPipeline: Sendable {
    private let pack: ELVLoadedPack
    private let fetcher: any ELVFetching
    /// The DOM engine, injected by the host app (EluviumDOM). Absent means
    /// `dom` steps are skipped — a binary without WebKit degrades cleanly.
    private let domRenderer: (any ELVDOMRendering)?

    /// The floor pass's combined Accept header: one request serves
    /// every floor, preferring feed documents when the server negotiates
    /// and taking HTML otherwise.
    private static let floorAccept = "application/rss+xml,application/atom+xml,application/feed+json,text/html;q=0.9,application/xhtml+xml;q=0.9,application/json;q=0.8,text/xml;q=0.7,*/*;q=0.5"

    /// The failure a cancelled run reports. `run` doesn't throw, so
    /// cancellation can't propagate as an error; this typed marker stands
    /// in for it instead of a misleading timeout.
    public static let cancelledMarker = ELVFetchFailure.formatDrift("cancelled")

    public init(pack: ELVLoadedPack, fetcher: any ELVFetching = ELVHTTPFetcher(), domRenderer: (any ELVDOMRendering)? = nil) {
        self.pack = pack
        self.fetcher = fetcher
        self.domRenderer = domRenderer
    }

    /// A progress callback fired as each stage begins.
    public typealias ProgressHandler = @Sendable (ELVPipelineStage) -> Void

    /// Fired once when a redirector expands the input, with the offline
    /// preview of the expanded link (the paste's name and `userLabel` still
    /// ranked): the place a short link hides, readable while the rest of
    /// the run fetches.
    public typealias ExpansionHandler = @Sendable (ELVPreview) -> Void

    /// Share sheets hand out `http://` links (Xiaohongshu's xhslink does);
    /// the egress policy is https-only and ATS refuses plain http inside an
    /// app anyway, so the front door upgrades the scheme instead of failing
    /// every such paste with an opaque transport error.
    public func run(url inputURL: URL, progress: ProgressHandler? = nil) async -> ELVPipelineRun {
        await run(input: ELVPastedInput(url: inputURL), progress: progress)
    }

    /// Runs pasted input: its link through the stages, with the blurb
    /// around it (`ELVPastedInput.leadingText` / `blurb`) and `userLabel`
    /// riding every step's context, so `paste` candidates read the share
    /// name and the stats a blurb spells out, and the label ladder ranks a
    /// typed label first. `expanded` hears about a redirector's expansion.
    public func run(
        input: ELVPastedInput,
        userLabel: String? = nil,
        progress: ProgressHandler? = nil,
        expanded: ExpansionHandler? = nil
    ) async -> ELVPipelineRun {
        let started = ContinuousClock.now
        let upgraded = ELVURLPolicy.httpsUpgraded(input.url)
        var trace = ELVRunTrace(inputHost: ELVLogFormat.traceHost(upgraded))
        let paste = ELVPasteContext(input: input, userLabel: userLabel)
        let result = await run(url: upgraded, chased: false, captured: false, origin: nil, paste: paste, progress: progress, expanded: expanded, trace: &trace)
        return finish(result, trace: trace, started: started, input: upgraded)
    }

    /// The offline preview of `input` against this pipeline's pack: the
    /// synchronous half a host shows while `run` does the rest.
    public func preview(input: ELVPastedInput, userLabel: String? = nil) -> ELVPreview {
        pack.preview(input, userLabel: userLabel)
    }

    /// Runs a seeded source's fetch plan from its pack-authored `seed` URL,
    /// skipping recognition: how hosts start browsable inventory (rankings)
    /// that has no recognizable input URL. The seed is pack-authored text
    /// under the same egress review as any step URL, and every fetch it
    /// triggers still passes the egress policy.
    public func runSeed(sourceId: String, progress: ProgressHandler? = nil) async -> ELVPipelineRun {
        let started = ContinuousClock.now
        var trace = ELVRunTrace()
        guard let source = pack.source(withId: sourceId), let seed = source.seed,
              let seedURL = URL(string: seed)
        else {
            trace.notes.append(pack.source(withId: sourceId) == nil ? "no active source \(sourceId)" : "source \(sourceId) has no seed URL")
            return finish(.failed(.invalidURL, sourceId: sourceId), trace: trace, started: started, input: nil)
        }
        let upgraded = ELVURLPolicy.httpsUpgraded(seedURL)
        trace.inputHost = ELVLogFormat.traceHost(upgraded)
        trace.sourceIds.append(source.id)
        let result = await run(source: source, params: [:], inputURL: upgraded, chased: false, origin: nil, paste: nil, progress: progress, trace: &trace)
        return finish(result, trace: trace, started: started, input: upgraded)
    }

    /// Stamps the run's duration, writes its log lines, and pairs the
    /// result with its trace.
    private func finish(_ result: ELVPipelineResult, trace: ELVRunTrace, started: ContinuousClock.Instant, input: URL?) -> ELVPipelineRun {
        var trace = trace
        trace.duration = ContinuousClock.now - started
        ELVRunLog.resolve(result, trace: trace, input: input)
        return ELVPipelineRun(result: result, trace: trace)
    }

    /// `origin` is the URL a canonical capture rewrote (nil before any
    /// capture): what an `{origin}` step URL fetches.
    private func run(
        url inputURL: URL,
        chased: Bool,
        captured: Bool,
        origin: URL?,
        paste: ELVPasteContext?,
        progress: ProgressHandler?,
        expanded onExpanded: ExpansionHandler? = nil,
        trace: inout ELVRunTrace
    ) async -> ELVPipelineResult {
        progress?(.recognize)
        if let recognition = pack.registry.recognize(inputURL), let matched = pack.source(withId: recognition.sourceId) {
            trace.sourceIds.append(matched.id)
            // Loop guard: a captured canonical URL re-enters recognition
            // exactly once. Landing back on a source that itself declares a
            // capture is a loop, not a place — fail, never re-render.
            if captured, declaresCapture(matched) {
                return .failed(.formatDrift("canonical capture landed on a capturing source (loop)"), sourceId: matched.id)
            }
            // A redirector source's whole job is the chase — run its
            // declared op and re-enter recognition with the expanded URL,
            // exactly once (a chase landing on another redirector is a loop,
            // not a place).
            if let opReference = matched.resolvesVia {
                guard !chased else {
                    return .failed(.formatDrift("chase landed on another redirector (loop)"), sourceId: matched.id)
                }
                guard let op = ELVNativeOps.lookupAsync(opReference) else {
                    // Capability gating normally drops the source at load; a
                    // host registering ops after loading reaches here, so the
                    // message names what to register.
                    return .failed(.formatDrift("redirector op \(opReference) is not registered"), sourceId: matched.id)
                }
                let started = ContinuousClock.now
                var chase = ELVStepTrace(sourceId: matched.id, index: 0, mode: "native", host: ELVLogFormat.traceHost(inputURL), notes: ["resolvesVia \(opReference)"])
                let failure: ELVFetchFailure
                do {
                    guard let outputs = try await op(["url": inputURL.absoluteString], ELVExtractionContext(url: inputURL)),
                          case let .url(expanded)? = outputs["url"]
                    else {
                        // The chain never moved: a share token that no longer
                        // redirects, or a redirector serving its own page.
                        throw ELVFetchFailure.formatDrift("redirector \(opReference) produced no expanded URL")
                    }
                    chase.finalURL = expanded
                    chase.outcome = .redirected
                    chase.duration = ContinuousClock.now - started
                    chase.notes.append("expanded to \(ELVLogFormat.host(expanded))")
                    trace.steps.append(chase)
                    trace.notes.append("redirector \(matched.id) chased to \(ELVLogFormat.host(expanded))")
                    onExpanded?(pack.preview(url: ELVURLPolicy.httpsUpgraded(expanded), paste: paste))
                    return await run(url: expanded, chased: true, captured: captured, origin: origin, paste: paste, progress: progress, trace: &trace)
                } catch is CancellationError {
                    failure = Self.cancelledMarker
                } catch {
                    // The chase's typed failure (a dead token's 404, an
                    // egress refusal) survives to the host, not a bare -1.
                    failure = ELVFetchFailure.folding(error)
                }
                chase.outcome = failure == Self.cancelledMarker ? .cancelled : .failed(failure)
                chase.duration = ContinuousClock.now - started
                trace.steps.append(chase)
                return .failed(failure, sourceId: matched.id)
            }
            return await run(source: matched, params: recognition.params, inputURL: inputURL, chased: chased, origin: origin, paste: paste, progress: progress, trace: &trace)
        }
        return await runFloors(inputURL: inputURL, paste: paste, progress: progress, trace: &trace)
    }

    /// The paste as one source sees it: stamped with that source's brand, so
    /// a share name derives against the brand the link landed on.
    private func paste(_ paste: ELVPasteContext?, for source: ELVSource) -> ELVPasteContext? {
        guard var paste else { return nil }
        paste.brand = source.title
        return paste
    }

    /// Whether any of the source's fetch steps declares a canonical-URL
    /// capture — the capture re-entry loop guard's predicate.
    private func declaresCapture(_ source: ELVSource) -> Bool {
        (source.fetch?.resolvedSteps ?? []).contains { $0.captureCanonical != nil }
    }

    /// No exact source matched, so fall through the generic floors in
    /// pack order (feed-shaped first, OG floor last). The floors differ in
    /// how they parse the page, not in what they fetch, so the page is
    /// requested ONCE with a combined Accept header and every floor reads
    /// the shared response. The first floor producing a non-empty record
    /// wins; a floor that comes up empty yields to the next. A floor claims
    /// only what the shared fetch actually parses — the feed floor takes
    /// feed documents, never a homepage via autodiscovery, so pasted
    /// homepages land on the OG card.
    ///
    /// When every floor comes up empty the last floor's empty record is
    /// still returned (a link card with the URL and its hash id): floors
    /// are the "every URL produces something" contract, so the empty-record
    /// drift rule for recognized sources deliberately does not apply here.
    private func runFloors(inputURL: URL, paste pasted: ELVPasteContext?, progress: ProgressHandler?, trace: inout ELVRunTrace) async -> ELVPipelineResult {
        guard !pack.genericFloors.isEmpty else { return .unrecognized }
        trace.usedFloors = true

        progress?(.fetch)
        let started = ContinuousClock.now
        var shared = ELVStepTrace(sourceId: nil, index: 0, mode: ELVFetchModes.http, host: ELVLogFormat.traceHost(inputURL))
        let response: ELVFetchResponse
        do {
            response = try await fetcher.fetch(inputURL, persona: .mobileSafari, accept: Self.floorAccept)
        } catch {
            // One shared fetch means the failure belongs to no single floor.
            let failure = error is CancellationError ? Self.cancelledMarker : ELVFetchFailure.folding(error)
            shared.outcome = failure == Self.cancelledMarker ? .cancelled : .failed(failure)
            shared.duration = ContinuousClock.now - started
            trace.steps.append(shared)
            // A refused fetch (a 403 wall) may still render: the last floor's
            // dom rung, when it declares one whose `when` admits the status.
            if failure != Self.cancelledMarker, let floor = pack.genericFloors.last,
               let rendered = await renderFloor(floor, url: inputURL, status: failureStatus(failure) ?? 0, prior: nil, paste: pasted, progress: progress, trace: &trace) {
                return rendered
            }
            return .failed(failure, sourceId: nil)
        }
        shared.status = response.status
        shared.finalURL = response.finalURL
        shared.bytes = response.data.count
        shared.truncated = response.truncated

        progress?(.extract)
        var lastResult: ELVPipelineResult = .unrecognized
        var lastFloor: String?
        for floor in pack.genericFloors {
            guard let step = floorStep(for: floor),
                  var context = try? makeContext(step: step, source: floor, response: response, params: [:]) else { continue }
            context.paste = paste(pasted, for: floor)
            guard let extracted = try? await ELVExtractor.extractAsync(fields: floor.fields, context: context) else {
                // `extractAsync` throws only on cancellation.
                shared.outcome = .cancelled
                shared.duration = ContinuousClock.now - started
                trace.steps.append(shared)
                return .failed(Self.cancelledMarker, sourceId: nil)
            }
            var enriched = context
            enriched.fields = extracted.values
            let record = ELVAssembler.assemble(source: floor, context: enriched, preExtracted: extracted)
            if !isEmptyFloorRecord(record) {
                shared.outcome = .produced
                shared.extracted = extracted.values.count
                shared.duration = ContinuousClock.now - started
                trace.steps.append(shared)
                trace.sourceIds.append(floor.id)
                trace.fieldMisses = ELVExtractor.misses(fields: floor.fields, result: extracted)
                trace.nativeOpFailures = extracted.nativeOpFailures
                if let rendered = await renderFloor(floor, url: inputURL, status: response.status, prior: extracted, paste: pasted, progress: progress, trace: &trace) {
                    return rendered
                }
                progress?(.assemble)
                return .record(record)
            }
            trace.notes.append("floor \(floor.id) extracted nothing")
            lastResult = .record(record)
            lastFloor = floor.id
        }
        shared.duration = ContinuousClock.now - started
        // Every floor came up empty on a capped body: the fields likely
        // lived past the cap, so surface the truncation instead of
        // silently returning emptiness.
        if response.truncated {
            let failure = ELVFetchFailure.formatDrift("body truncated at byte cap")
            shared.outcome = .failed(failure)
            trace.steps.append(shared)
            return .failed(failure, sourceId: nil)
        }
        shared.outcome = .produced
        shared.extracted = 0
        trace.steps.append(shared)
        if let floor = pack.genericFloors.last,
           let rendered = await renderFloor(floor, url: inputURL, status: response.status, prior: nil, paste: pasted, progress: progress, trace: &trace) {
            return rendered
        }
        if let lastFloor { trace.sourceIds.append(lastFloor) }
        return lastResult
    }

    /// A floor's dom rung: when the floor declares a `dom` step whose `when`
    /// admits the shared fetch's outcome (its status, the fields the floor
    /// extracted from it) and a renderer is injected, the page is rendered
    /// and the floor's ladder re-runs over the render, fill-empty over what
    /// the fetch gave. Nil when there is no rung, it declined, or the render
    /// produced nothing, so the caller keeps the fetch's own outcome.
    private func renderFloor(
        _ floor: ELVSource,
        url: URL,
        status: Int,
        prior: ELVExtractor.FieldResult?,
        paste pasted: ELVPasteContext?,
        progress: ProgressHandler?,
        trace: inout ELVRunTrace
    ) async -> ELVPipelineResult? {
        guard let renderer = domRenderer,
              let step = floor.fetch?.resolvedSteps.first(where: { $0.mode == ELVFetchModes.dom }),
              step.permits(url: url, didProduce: true, lastStatus: status, extracted: prior?.values ?? [:], brand: floor.title)
        else { return nil }
        var stepTrace = ELVStepTrace(sourceId: floor.id, index: 1, mode: ELVFetchModes.dom, host: ELVLogFormat.traceHost(url))
        let started = ContinuousClock.now
        do {
            let rendered = try await renderDOM(step: step, source: floor, url: url, params: [:], renderer: renderer, trace: &stepTrace)
            var context = rendered.context
            context.paste = paste(pasted, for: floor)
            progress?(.extract)
            let extracted = try await ELVExtractor.extractAsync(fields: step.fields ?? floor.fields, context: context)
            let combined = prior.map { merged(previous: $0, with: extracted) } ?? extracted
            stepTrace.duration = ContinuousClock.now - started
            guard !extracted.values.isEmpty else {
                stepTrace.outcome = .failed(.formatDrift("render extracted nothing"))
                trace.steps.append(stepTrace)
                return nil
            }
            stepTrace.outcome = .produced
            stepTrace.extracted = extracted.values.count
            trace.steps.append(stepTrace)
            if !trace.sourceIds.contains(floor.id) { trace.sourceIds.append(floor.id) }
            trace.fieldMisses = ELVExtractor.misses(fields: floor.fields, result: combined)
            trace.nativeOpFailures += extracted.nativeOpFailures
            var enriched = context
            enriched.fields = combined.values
            progress?(.assemble)
            return .record(ELVAssembler.assemble(source: floor, context: enriched, preExtracted: combined))
        } catch is CancellationError {
            stepTrace.outcome = .cancelled
            stepTrace.duration = ContinuousClock.now - started
            trace.steps.append(stepTrace)
            return .failed(Self.cancelledMarker, sourceId: floor.id)
        } catch {
            stepTrace.outcome = .failed(ELVFetchFailure.folding(error))
            stepTrace.duration = ContinuousClock.now - started
            trace.steps.append(stepTrace)
            return nil
        }
    }

    /// The floor's transport step: floors parse the shared response, so
    /// only the URL-transport modes apply here.
    private func floorStep(for floor: ELVSource) -> ELVFetchStep? {
        (floor.fetch?.resolvedSteps ?? [ELVFetchStep(mode: ELVFetchModes.http)]).first { ELVFetchModes.urlTransports.contains($0.mode) }
    }

    /// A floor "missed" when it produced no fields and no children — e.g. a
    /// feed source handed a plain HTML page with no discoverable feed.
    private func isEmptyFloorRecord(_ record: ELVRecord) -> Bool {
        record.fields.isEmpty && record.collections.allSatisfy(\.value.isEmpty)
    }

    /// One step's execution result. The step loop in `run(source:...)` owns
    /// every piece of cross-step state (fill-empty merge, `lastStatus`
    /// threading, escalation, capture accumulation); `execute(step:...)`
    /// owns one step's transport + extraction, and fills in the step's
    /// trace facts (host, status, bytes, truncation, settle state). Per-step
    /// grammar (scoped fields/collections, byte budgets) lands in the
    /// helper, nowhere else.
    private enum StepOutcome {
        /// Transport + extraction ran; `collections` carries step-scoped
        /// collection results (nil when the step declares none), and
        /// `missedCapture` is a declared-but-missed canonical capture (the
        /// timeout diagnostic rider).
        case produced(context: ELVExtractionContext, status: Int, extracted: ELVExtractor.FieldResult, collections: [String: [ELVRecord]]?, missedCapture: ELVCanonicalCapture?)
        /// A dom step captured the canonical URL — the caller re-enters
        /// recognition with it.
        case capturedCanonical(URL)
        case failed(ELVFetchFailure)
        case cancelled
    }

    private func run(
        source: ELVSource,
        params paramsIn: [String: String],
        inputURL: URL,
        chased: Bool,
        origin: URL?,
        paste pasted: ELVPasteContext?,
        progress: ProgressHandler?,
        trace: inout ELVRunTrace
    ) async -> ELVPipelineResult {
        let recognition = ELVRecognition(sourceId: source.id, params: paramsIn)
        let paste = paste(pasted, for: source)

        // Canonicalize before fetching: the share variant may serve
        // lighter metas; a keep-token must survive.
        let canonicalURL = source.canonicalize?.apply(to: inputURL) ?? inputURL

        let steps = source.fetch?.resolvedSteps ?? [ELVFetchStep(mode: ELVFetchModes.http)]
        var lastFailure: ELVFetchFailure?
        var skippedModes: [String] = []
        var didProduce = false
        var lastStatus = 0
        var extracted = ELVExtractor.FieldResult(values: [:], provenance: [:])
        var context = ELVExtractionContext(url: canonicalURL, params: recognition.params, paste: paste)
        var timedOutCapture: ELVCanonicalCapture?
        var stepCollections: [String: [ELVRecord]] = [:]
        // Each producing step's misses and op failures, merged against the
        // final field set once the loop ends.
        var stepMisses: [ELVFieldMiss] = []
        var opFailures: [ELVNativeOpFailure] = []

        progress?(.fetch)
        for (index, step) in steps.enumerated() {
            var stepTrace = ELVStepTrace(sourceId: source.id, index: index, mode: step.mode, host: ELVLogFormat.traceHost(canonicalURL))
            // Runs none / http / json / feed, and dom when a renderer is
            // injected; native escalation is the Places layer's job.
            let runnable = ELVFetchModes.coreExecutable.contains(step.mode) || (step.mode == ELVFetchModes.dom && domRenderer != nil)
            guard runnable else {
                skippedModes.append(step.mode)
                stepTrace.outcome = .skipped
                trace.steps.append(stepTrace)
                continue
            }
            guard step.permits(url: canonicalURL, didProduce: didProduce, lastStatus: lastStatus, extracted: extracted.values, brand: source.title) else {
                stepTrace.outcome = .declined
                trace.steps.append(stepTrace)
                continue
            }

            let started = ContinuousClock.now
            let outcome = await execute(step: step, source: source, canonicalURL: canonicalURL, origin: origin, params: recognition.params, paste: paste, progress: progress, trace: &stepTrace)
            stepTrace.duration = ContinuousClock.now - started
            switch outcome {
            case let .produced(stepContext, status, stepExtracted, collections, missedCapture):
                stepTrace.outcome = .produced
                stepTrace.extracted = stepExtracted.values.count
                trace.steps.append(stepTrace)
                stepMisses += ELVExtractor.misses(fields: step.fields ?? source.fields, result: stepExtracted)
                opFailures += stepExtracted.nativeOpFailures
                lastStatus = status
                context = stepContext
                // Composite escalation merges fill-empty: the new
                // step wins where it produced; fields only an earlier step
                // extracted carry forward, so a thinner escalated page can't
                // discard step 1's summary or image.
                extracted = didProduce ? merged(previous: extracted, with: stepExtracted) : stepExtracted
                didProduce = true
                if let collections {
                    // Name-granularity mirror of the field merge: a later
                    // step's non-empty collection replaces the earlier one
                    // (assembleCollections already drops empty results).
                    for (name, records) in collections {
                        stepCollections[name] = records
                    }
                }
                if let missedCapture { timedOutCapture = missedCapture }
            case let .capturedCanonical(canonical):
                stepTrace.outcome = .capturedCanonical
                trace.steps.append(stepTrace)
                trace.notes.append("source \(source.id) captured a canonical URL on \(ELVLogFormat.host(canonical))")
                // The captured canonical re-enters recognition exactly
                // like a redirector's expansion — the iOS share
                // becomes the desktop share, and the re-recognized source
                // (gmaps.place), not the capturing one, owns the pin.
                return await run(url: canonical, chased: chased, captured: true, origin: canonicalURL, paste: pasted, progress: progress, trace: &trace)
            case let .failed(failure):
                stepTrace.outcome = .failed(failure)
                trace.steps.append(stepTrace)
                lastFailure = failure
                // A later step's `when.status` trigger tests the thrown
                // step's status, not a stale one from an earlier step.
                if let status = failureStatus(failure) { lastStatus = status }
            case .cancelled:
                stepTrace.outcome = .cancelled
                trace.steps.append(stepTrace)
                // `run` doesn't throw, so cancellation can't propagate as an
                // error; stop fetching and surface it as a typed failure
                // instead of a misleading timeout.
                return .failed(Self.cancelledMarker, sourceId: source.id)
            }
        }

        guard didProduce else {
            if let lastFailure { return .failed(lastFailure, sourceId: source.id) }
            if !skippedModes.isEmpty {
                return .failed(.formatDrift("no runnable fetch step (modes: \(skippedModes.joined(separator: ", ")))"), sourceId: source.id)
            }
            // Nothing failed and nothing was skipped for capability, so every
            // step's `when` declined this input (or the plan declared none).
            return .failed(.formatDrift("no fetch step ran: every step's when condition declined the input"), sourceId: source.id)
        }

        progress?(.assemble)
        var enriched = context
        enriched.fields = extracted.values
        var record = ELVAssembler.assemble(source: source, context: enriched, preExtracted: extracted, extraCollections: stepCollections)
        if let capture = timedOutCapture {
            // The timeout diagnostic: extraction fell through without the
            // canonical URL. Rides provenance — the model's attribution
            // channel, like the Flighty drift sentinel — so hosts and tests
            // see WHY the record has no pin without a logging dependency.
            record.provenance["captureCanonical"] = ELVProvenance(
                origin: "capture timed out (maxPolls \(capture.maxPolls) exhausted); extracted without a canonical URL"
            )
            trace.notes.append("canonical capture timed out after \(capture.maxPolls) polls")
        }
        trace.fieldMisses = mergedMisses(stepMisses, filled: extracted.values)
        trace.nativeOpFailures = opFailures
        // A recognized source that answered and yielded nothing at all (no
        // field, no child) has drifted: the page format moved out from under
        // the pack. Fail typed instead of handing back an empty record that
        // reads as success; a partially filled record stays a record, with
        // its gaps in `trace.fieldMisses`. A URL-only plan (`none`) never
        // fetched, so nothing could drift: a non-detail URL on its host (a
        // Tripadvisor Tourism page, a GetYourGuide city page) is the host
        // prior with no label, the kind-only record the corpus pins.
        let fetched = !(source.fetch?.requiredModes.isEmpty ?? true)
        if fetched, extracted.values.isEmpty, record.collections.allSatisfy(\.value.isEmpty) {
            return .failed(.formatDrift("no fields extracted"), sourceId: source.id)
        }
        return .record(record)
    }

    /// Folds the producing steps' misses into the run's: a field any step
    /// filled is no miss; a field several steps missed lists every
    /// candidate they tried, in step order, once.
    private func mergedMisses(_ misses: [ELVFieldMiss], filled: [String: ELVValue]) -> [ELVFieldMiss] {
        var merged: [ELVFieldMiss] = []
        var position: [String: Int] = [:]
        for miss in misses where filled[miss.field] == nil {
            if let index = position[miss.field] {
                for candidate in miss.candidates where !merged[index].candidates.contains(candidate) {
                    merged[index].candidates.append(candidate)
                }
            } else {
                position[miss.field] = merged.count
                merged.append(miss)
            }
        }
        return merged
    }

    /// Executes one fetch step end to end: URL template resolution, the
    /// mode's transport, and the awaited field extraction. Cross-step
    /// concerns stay with the caller; the step's trace facts land in
    /// `stepTrace`.
    private func execute(
        step: ELVFetchStep,
        source: ELVSource,
        canonicalURL: URL,
        origin: URL?,
        params: [String: String],
        paste: ELVPasteContext?,
        progress: ProgressHandler?,
        trace stepTrace: inout ELVStepTrace
    ) async -> StepOutcome {
        do {
            let stepURL = try resolvedURL(step: step, base: canonicalURL, origin: origin, params: params)
            stepTrace.host = ELVLogFormat.traceHost(stepURL)
            var stepContext: ELVExtractionContext
            var stepTruncated = false
            var missedCapture: ELVCanonicalCapture?
            var status = 200
            var unsettledRender: ELVDOMResult?
            if step.mode == ELVFetchModes.none {
                // A URL-shaped source (Swarm, Maps `?q=` shares):
                // everything extractable lives in the URL and params, so
                // no request leaves the device.
                stepContext = ELVExtractionContext(url: canonicalURL, params: params)
            } else if step.mode == ELVFetchModes.dom, let renderer = domRenderer {
                // The step loop admits a dom step only with a renderer
                // injected; binding it here states that fact where the type
                // system can see it, and a dom step that somehow reached the
                // URL-transport branch below fails typed in `makeContext`.
                let rendered = try await renderDOM(step: step, source: source, url: stepURL, params: params, renderer: renderer, trace: &stepTrace)
                let result = rendered.result
                if let canonical = result.canonicalURL {
                    // Every capture result passes egress before being
                    // surfaced: the renderer already refuses
                    // violating captures, but the renderer is an
                    // injected seam, so the pipeline re-checks.
                    if let reason = ELVEgressPolicy.violation(canonical) {
                        throw ELVFetchFailure.egressBlocked(reason)
                    }
                    return .capturedCanonical(canonical)
                }
                stepContext = rendered.context
                if !result.settled { unsettledRender = result }
                // Capture declared, applicable (the input lacked the
                // target data), and missed: fall through to what the
                // step extracted, remembering the miss for the record's
                // diagnostic.
                if let capture = step.captureCanonical,
                   !ELVRegexCache.matches(capture.untilURLRegex, in: stepURL.absoluteString) {
                    missedCapture = capture
                    stepTrace.notes.append("canonical capture missed after \(capture.maxPolls) polls")
                }
            } else {
                let fetched = try await httpStepContext(step: step, source: source, url: stepURL, pageURL: canonicalURL, params: params, trace: &stepTrace)
                stepContext = fetched.context
                status = fetched.status
                stepTruncated = fetched.truncated
            }
            stepContext.paste = paste
            progress?(.extract)
            // Step-scoped extraction: a step that declares `fields`
            // runs ONLY those, so an enrichment endpoint (API lookup, embed
            // page) cannot overwrite page fields it never declared. Absent,
            // the source ladder runs against every step as always. Awaited
            // so async native ops (place.mapKitLookup) serve field
            // candidates; sync-only sources behave identically.
            let extracted = try await ELVExtractor.extractAsync(fields: step.fields ?? source.fields, context: stepContext)
            // Step-scoped collections evaluate against THIS step's context,
            // not whichever step happens to run last.
            var stepCollections: [String: [ELVRecord]]?
            if let specs = step.collections {
                var enriched = stepContext
                enriched.fields = extracted.values
                stepCollections = ELVAssembler.assembleCollections(specs, source: source, context: enriched)
            }
            let producedNothing = extracted.values.isEmpty && stepCollections?.isEmpty ?? true
            // A render that never settled and yielded nothing is a load
            // that did not happen (a failed navigation, a challenge that
            // never cleared, a final evaluate that timed out): fail the
            // step with the reason rather than extract an empty record.
            if let unsettledRender, producedNothing {
                throw ELVFetchFailure.formatDrift(Self.unsettledReason(unsettledRender))
            }
            // A truncated body that still extracted is partial output by
            // design; one whose whole step surface (fields plus step
            // collections) produced nothing means the content lived past
            // the byte cap — fail the step rather than silently extracting
            // from half a document.
            if stepTruncated, producedNothing {
                throw ELVFetchFailure.formatDrift("body truncated at byte cap")
            }
            return .produced(context: stepContext, status: status, extracted: extracted, collections: stepCollections, missedCapture: missedCapture)
        } catch is CancellationError {
            return .cancelled
        } catch {
            // A WKError or decode error survives to the host as its
            // domain and code, not a bare -1.
            return .failed(ELVFetchFailure.folding(error))
        }
    }

    /// Why an unsettled render that produced nothing failed.
    private static func unsettledReason(_ result: ELVDOMResult) -> String {
        var reason = "render did not settle"
        if let loadError = result.loadError {
            reason += "; load failed: \(loadError)"
        }
        if let extractionError = result.extractionError {
            reason += "; final evaluate failed: \(extractionError)"
        }
        if result.loadError == nil, result.extractionError == nil {
            reason += " and nothing extracted"
        }
        return reason
    }

    /// The status a thrown step observed, feeding later steps' `when.status`
    /// triggers.
    private func failureStatus(_ failure: ELVFetchFailure) -> Int? {
        switch failure {
        case let .blocked(status), let .httpError(status):
            status
        case .unauthenticated:
            401
        default:
            nil
        }
    }

    /// Fill-empty merge of two extraction passes: `next` wins where it
    /// produced; fields only `previous` had carry forward, provenance
    /// travelling with each value.
    private func merged(previous: ELVExtractor.FieldResult, with next: ELVExtractor.FieldResult) -> ELVExtractor.FieldResult {
        var result = next
        for (name, value) in previous.values where result.values[name] == nil {
            result.values[name] = value
            result.provenance[name] = previous.provenance[name]
        }
        return result
    }

    /// An http / json / feed step: fetch, build the extraction context, and
    /// follow one feed-autodiscovery hop. Returns the context, the HTTP
    /// status (for escalation triggers), and whether the byte cap truncated
    /// the body the context was built from. Each response's transport facts
    /// land in `stepTrace` as soon as it arrives, so a step that then fails
    /// still reports what it received. Autodiscovery serves recognized
    /// feed sources only — the floor pass never calls this, so a homepage
    /// advertising a feed link still falls through to the OG floor.
    ///
    /// A `json` step whose body does not parse as JSON, and a `feed` step
    /// that ends with no feed (none served, none advertised, or an
    /// advertised link that is not one), fail as `formatDrift`: extracting
    /// json paths from HTML can only produce an empty record.
    private func httpStepContext(
        step: ELVFetchStep,
        source: ELVSource,
        url stepURL: URL,
        pageURL: URL,
        params: [String: String],
        trace stepTrace: inout ELVStepTrace
    ) async throws -> (context: ELVExtractionContext, status: Int, truncated: Bool) {
        let referer = step.referer == "sourceOrigin" ? sourceOrigin(stepURL) : nil
        let persona = ELVUAPersona.resolve(step.ua)
        let accept = acceptHeader(for: step.mode)
        // The step's byte budget: giant-feed sources opt in past the
        // transport default; the budget's own init re-clamps the ceiling.
        let budget = ELVFetchBudget(maxBytes: step.maxBytes ?? ELVFetchBudget.standard.maxBytes)
        let fetched = try await fetcher.fetch(stepURL, persona: persona, referer: referer, accept: accept, budget: budget)
        record(fetched, into: &stepTrace)

        // A template step fetched an API endpoint, not the recognized page:
        // the context (and so the record's sourceURL, and every url*
        // candidate) must keep the page URL — the endpoint is transport.
        let contextURL = step.url == nil ? nil : pageURL
        let stepContext = try makeContext(step: step, source: source, response: fetched, params: params, overrideURL: contextURL)
        if step.mode == ELVFetchModes.json, stepContext.document.json == nil {
            throw ELVFetchFailure.formatDrift(fetched.truncated ? "json step: body truncated at byte cap before it parsed" : "json step: response is not JSON")
        }
        if step.mode == ELVFetchModes.feed, stepContext.document.json == nil {
            guard let discovered = feedURL(advertisedBy: stepContext.document, base: fetched.finalURL) else {
                throw ELVFetchFailure.formatDrift("feed step: response is not a feed and advertises none")
            }
            // The autodiscovery follow inherits the step's budget: the real
            // feed is the document the budget was raised for.
            let followed = try await fetcher.fetch(discovered, persona: persona, accept: accept, budget: budget)
            record(followed, into: &stepTrace)
            stepTrace.notes.append("followed the advertised feed link to \(ELVLogFormat.host(discovered))")
            let followedContext = try makeContext(step: step, source: source, response: followed, params: params, overrideURL: contextURL)
            guard followedContext.document.json != nil else {
                throw ELVFetchFailure.formatDrift("feed step: the advertised feed link is not a feed")
            }
            return (followedContext, followed.status, followed.truncated)
        }
        return (stepContext, fetched.status, fetched.truncated)
    }

    /// A response's transport facts, as the step's trace reports them.
    private func record(_ response: ELVFetchResponse, into stepTrace: inout ELVStepTrace) {
        stepTrace.status = response.status
        stepTrace.finalURL = response.finalURL
        stepTrace.bytes = response.data.count
        stepTrace.truncated = response.truncated
    }

    /// A dom step: compile the source's CSS queries into one JS program, let
    /// the injected renderer run it in a headless webview, and build a
    /// context from the settled HTML + resolved CSS values. The render
    /// itself is returned alongside (its captured canonical URL drives
    /// the caller's recognition re-entry); its settle state, byte count, and
    /// errors land in `stepTrace` as soon as it returns, so a render that
    /// then fails a check below still reports what it saw. When a declared
    /// capture missed, the context keeps the STEP URL (not the render's
    /// landing), so the `?q=` the URL-derived fallback fields read survives
    /// whatever the page navigated to.
    private func renderDOM(
        step: ELVFetchStep,
        source: ELVSource,
        url stepURL: URL,
        params: [String: String],
        renderer: any ELVDOMRendering,
        trace stepTrace: inout ELVStepTrace
    ) async throws -> (context: ELVExtractionContext, result: ELVDOMResult) {
        // The DOM engine is a fetch path like any other: the egress policy
        // vets the pack-built URL before the webview ever loads it. Without
        // this, a dom step is the one door a pack can point at an internal
        // host (169.254.169.254 and friends).
        if let reason = ELVEgressPolicy.violation(stepURL) {
            throw ELVFetchFailure.egressBlocked(reason)
        }
        let request = ELVDOMRequest(
            url: stepURL,
            userAgent: ELVUAPersona.resolve(step.ua ?? "desktopSafari").headerValue,
            settle: step.settle ?? ELVSettlePolicy(),
            css: source.cssQueries(for: step),
            captureCanonical: step.captureCanonical
        )
        let result = try await renderer.render(request)
        stepTrace.settled = result.settled
        stepTrace.bytes = result.html.utf8.count
        stepTrace.finalURL = result.canonicalURL ?? result.finalURL
        if let loadError = result.loadError { stepTrace.notes.append("load failed: \(loadError)") }
        if let extractionError = result.extractionError { stepTrace.notes.append("final evaluate failed: \(extractionError)") }
        // The render's own landing must pass egress too: an in-page redirect
        // to a private host must not have its DOM extracted.
        if let reason = ELVEgressPolicy.violation(result.finalURL) {
            throw ELVFetchFailure.egressBlocked(reason)
        }
        // A settled render whose final evaluate failed came back empty
        // because the extraction never ran, not because the page was a
        // challenge shell: say so instead of reporting a bot wall. (An
        // unsettled one fails later, with the evaluate error in its reason,
        // only if nothing extracted.)
        if result.canonicalURL == nil, result.settled, result.html.isEmpty, result.cssResults.isEmpty,
           let extractionError = result.extractionError {
            throw ELVFetchFailure.formatDrift("final evaluate failed: \(extractionError)")
        }
        // A settled-but-empty render (a challenge shell) throws so escalation
        // and typed failures see it as blocked rather than a bare record —
        // unless a canonical was captured: a mid-rewrite page is legitimately
        // empty, and the caller re-enters recognition instead of extracting.
        if result.canonicalURL == nil, result.settled, result.html.isEmpty, result.cssResults.isEmpty {
            throw ELVFetchFailure.blocked(status: 200)
        }
        var document = ELVDocument(html: result.html)
        document.text = result.html
        document.cssResults = result.cssResults
        let effectiveURL: URL = if let canonical = result.canonicalURL {
            canonical
        } else if step.captureCanonical != nil {
            stepURL
        } else {
            result.finalURL
        }
        return (ELVExtractionContext(url: effectiveURL, params: params, document: document), result)
    }

    /// Fills a step's URL template. `{param.x}` substitutes a recognition
    /// param; `{host}` the canonicalized input's host and `{query.x}` one
    /// of its query items (so a `canonicalize` rule decides which items a
    /// template can ever see, and a per-language host reaches its own API);
    /// `{native:op(param.x)}` substitutes a registered SYNC op's
    /// single output computed from that param (computed *params*,
    /// never computed URLs: the template's host is pack-authored text, so
    /// egress and review still see where the request goes; ask 18's
    /// syndication token is the motivating case). A template that cannot be
    /// filled fails the step — falling back to the source URL would fetch
    /// the wrong host with the step's Accept and parse mode.
    private func resolvedURL(step: ELVFetchStep, base: URL, origin: URL?, params: [String: String]) throws -> URL {
        guard let template = step.url else { return base }
        if template == ELVURLTemplate.originPlaceholder { return origin ?? base }
        // Native placeholders first, then the shared `{param.x}` filler: one
        // percent-encoding rule for the pipeline and the enumerator.
        let filledParams = try ELVURLTemplate.fill(substituteNativePlaceholders(in: template, base: base, params: params), params: params)
        guard let filled = ELVURLTemplate.fillInput(filledParams, from: base) else {
            throw ELVFetchFailure.formatDrift("url template input placeholder missing")
        }
        guard let url = URL(string: filled) else {
            throw ELVFetchFailure.formatDrift("url template did not resolve to a URL")
        }
        return url
    }

    /// `{native:op(param.x)}` placeholders, longest-first mechanics not
    /// needed: each match is replaced by the op's single string-formed
    /// output, percent-encoded. Sync ops only — a fetch URL is built, not
    /// awaited — and a missing op, param, or output is a typed step failure.
    private func substituteNativePlaceholders(in template: String, base: URL, params: [String: String]) throws -> String {
        guard template.contains("{native:") else { return template }
        let regex = ELVURLTemplate.nativePlaceholderRegex
        let nsTemplate = template as NSString
        var filled = template
        for match in regex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length)).reversed() {
            let placeholder = nsTemplate.substring(with: match.range)
            let opReference = nsTemplate.substring(with: match.range(at: 1))
            let paramName = nsTemplate.substring(with: match.range(at: 2))
            guard let op = ELVNativeOps.lookup(opReference) else {
                throw ELVFetchFailure.formatDrift("url template op \(opReference) unavailable (sync ops only)")
            }
            guard let value = params[paramName] else {
                throw ELVFetchFailure.formatDrift("url template param \(paramName) missing")
            }
            let context = ELVExtractionContext(url: base, params: params)
            guard let outputs = op([paramName: value], context), outputs.count == 1,
                  let output = outputs.values.first, let string = templateValueString(output)
            else {
                throw ELVFetchFailure.formatDrift("url template op \(opReference) produced no value")
            }
            let encoded = string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
            filled = filled.replacingOccurrences(of: placeholder, with: encoded)
        }
        return filled
    }

    /// The string form a computed template param may take: text, an integral
    /// number, or a URL — nothing structured belongs in a query value.
    private func templateValueString(_ value: ELVValue) -> String? {
        switch value {
        case let .text(string):
            string
        case let .number(number):
            if number == number.rounded(), abs(number) < 1e15 { String(Int64(number)) } else { String(number) }
        case let .url(url):
            url.absoluteString
        default:
            nil
        }
    }

    private func acceptHeader(for mode: String) -> String? {
        switch mode {
        case ELVFetchModes.json: "application/json,*/*;q=0.8"
        case ELVFetchModes.feed: "application/rss+xml,application/atom+xml,application/feed+json,application/json;q=0.9,text/xml;q=0.8,*/*;q=0.5"
        default: nil
        }
    }

    /// Discovers a feed URL from a homepage's `<link rel="alternate">`,
    /// preferring JSON Feed → Atom → RSS. Returns an absolute URL.
    /// Reads the links the document's own HTML scan already collected, so
    /// a homepage on a feed step is scanned once, not twice.
    private func feedURL(advertisedBy document: ELVDocument, base: URL) -> URL? {
        let links = document.links.filter { $0.rel == "alternate" }
        let preference = ["application/feed+json", "application/json", "application/atom+xml", "application/rss+xml", "text/xml"]
        let ranked = links.sorted { lhs, rhs in
            (preference.firstIndex(of: lhs.type ?? "") ?? preference.count) < (preference.firstIndex(of: rhs.type ?? "") ?? preference.count)
        }
        for link in ranked where link.type?.contains("xml") == true || link.type?.contains("json") == true {
            // The scheme-allowlisted resolution: a `javascript:` or
            // `data:` href in the link tag must never become a fetch.
            if let url = ELVURLPolicy.resolve(link.href, relativeTo: base), url != base {
                return url
            }
        }
        return nil
    }

    private func sourceOrigin(_ url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return URL(string: "\(scheme)://\(host)/")
    }

    private func makeContext(step: ELVFetchStep, source: ELVSource, response: ELVFetchResponse, params: [String: String], overrideURL: URL? = nil) throws -> ELVExtractionContext {
        var document: ELVDocument
        switch step.mode {
        case ELVFetchModes.json:
            document = ELVDocument(json: ELVRawJSON.parse(response.data))
        case ELVFetchModes.feed:
            // The feed engine normalizes RSS / Atom / JSON Feed to one
            // envelope; packs then select from it with ordinary json paths.
            if let envelope = ELVFeedNormalizer.normalize(response.data) {
                document = ELVDocument(json: envelope.asRawJSON())
            } else {
                // Not a feed (likely a homepage): keep the HTML so
                // autodiscovery can find the feed link.
                document = ELVDocument(html: response.bodyText)
                document.text = response.bodyText
            }
        case ELVFetchModes.http:
            document = ELVDocument(html: response.bodyText)
            document.text = response.bodyText
            // A declared JSON island (Next.js-style server data) promotes
            // into the document's JSON so ordinary `json` fields and
            // collections work on script-hydrated pages; the HTML document
            // (metas, JSON-LD) stays intact beside it. Missing or malformed
            // islands leave the document HTML-only, so a `missingAny`
            // trigger can escalate.
            if let island = step.jsonIsland {
                document.json = ELVHTMLScanner.jsonIsland(id: island, in: response.bodyText)
            }
        default:
            // `none` and `dom` build their contexts upstream; anything else
            // has no business becoming a URL transport here.
            throw ELVFetchFailure.formatDrift("mode \(step.mode) is not a URL transport")
        }
        // The context URL is re-pointed at the redirect-resolved final URL
        // , re-canonicalized so the same page reached two ways
        // produces one sourceURL — recognition ran once on the input and is
        // not re-entered. The params travel with the source that matched.
        // `overrideURL` (a template step's page URL) wins over the final
        // URL: an API endpoint must never become a record's sourceURL.
        let contextURL = overrideURL ?? source.canonicalize?.apply(to: response.finalURL) ?? response.finalURL
        return ELVExtractionContext(url: contextURL, params: params, document: document)
    }
}
