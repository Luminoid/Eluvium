import EluviumCore
import Foundation

/// Session-scoped ingestion over `ELVPipeline`: a per-session result cache
/// plus in-flight coalescing ("caching and retry are policy, not
/// accident"). A live-preview resolve and the post-save enrichment of the
/// same pasted URL share one chase, and re-pasting a link the session
/// already resolved returns instantly instead of redoing the fetch.
///
/// Cache policy: only a run that finished and gained something is
/// pinned — failed (blocked, offline), unrecognized, and empty outcomes are
/// deliberately never cached, so the next paste retries. Keys are the input
/// URL after the matched source's canonicalization, derived before
/// any fetch, so tracking-param variants share one entry while a keep-token
/// still keys distinctly. A cache hit performs no request at all; a miss
/// runs the full pipeline — recognition, egress policy, redirect chase —
/// untouched.
/// Which finished runs a session pins.
public enum ELVPinPolicy: Sendable, Equatable {
    /// A record that carries any field or child (the default).
    case gainedSomething
    /// Also refuses a record that came out of an impaired run: a native op
    /// threw (a MapKit lookup timed out), a canonical capture timed out, or
    /// a producing step was cut at the byte cap or never settled. The next
    /// paste of the same link retries instead of replaying the partial
    /// result for the rest of the session.
    case completeOnly
}

public actor ELVIngestSession {
    /// Session-lifetime bound: inputs arrive by hand (paste, share sheet),
    /// so the cap only guards a pathological session and a wholesale reset
    /// beats LRU bookkeeping (the TripDays session-cache rule).
    static let cacheCapacity = 64

    private let pack: ELVLoadedPack
    private let pipeline: ELVPipeline
    private let pinPolicy: ELVPinPolicy

    /// Completed runs keyed by the canonicalized input URL.
    private var cache: [String: ELVPipelineRun] = [:]
    /// In-flight runs keyed the same way. An awaiter's own cancellation
    /// never cancels the shared task (`Task.value` on a non-throwing task
    /// does not propagate it), so a dismissed preview leaves the enrich's
    /// await — and the eventual cache pin — intact.
    private var inFlight: [String: Task<ELVPipelineRun, Never>] = [:]
    /// Bumped by `reset()`: a run minted before the reset completes for its
    /// awaiters but never pins into the fresh cache.
    private var generation = 0

    public init(pack: ELVLoadedPack, fetcher: any ELVFetching = ELVHTTPFetcher(), domRenderer: (any ELVDOMRendering)? = nil, pinPolicy: ELVPinPolicy = .gainedSomething) {
        self.pack = pack
        self.pinPolicy = pinPolicy
        pipeline = ELVPipeline(pack: pack, fetcher: fetcher, domRenderer: domRenderer)
    }

    deinit {
        // Orphaned chases die with the session: nothing can be awaiting
        // them here, because an executing `ingest` call keeps the actor
        // alive.
        for task in inFlight.values {
            task.cancel()
        }
    }

    /// Runs `url` through the pipeline, consulting the session cache first
    /// and joining (or minting) the shared in-flight run. A cache hit
    /// returns before any stage fires; `progress` fires only for the call
    /// that mints the run — a joiner awaits silently. A cache hit returns
    /// the original run with `trace.servedFromCache` set: the trace
    /// describes the run that produced the record, and no request left.
    public func ingest(url: URL, progress: ELVPipeline.ProgressHandler? = nil) async -> ELVPipelineRun {
        await ingest(input: ELVPastedInput(url: url), progress: progress)
    }

    /// `ingest(url:)` for pasted input. The cache key adds the paste's
    /// blurb and `userLabel` to the canonical URL: two pastes of one link
    /// with different blurbs are different inputs (one may carry stats the
    /// other lacks), while a preview and the post-save enrich of the same
    /// paste still share one run.
    public func ingest(input: ELVPastedInput, userLabel: String? = nil, progress: ELVPipeline.ProgressHandler? = nil) async -> ELVPipelineRun {
        let url = ELVURLPolicy.httpsUpgraded(input.url)
        let key = cacheKey(for: url, input: input, userLabel: userLabel)
        if var cached = cache[key] {
            cached.trace.servedFromCache = true
            ELVLog.debug(.fetch, "Ingest cache hit source=\(cached.trace.sourceIds.last ?? "-") host=\(ELVLogFormat.host(url))")
            return cached
        }
        if let running = inFlight[key] { return await running.value }
        return await mintTask(input: input, userLabel: userLabel, key: key, progress: progress).value
    }

    /// The offline preview of `input` (`ELVLoadedPack.preview`): synchronous
    /// and isolation-free, so a host can call it on the main thread as the
    /// text lands.
    public nonisolated func preview(input: ELVPastedInput, userLabel: String? = nil) -> ELVPreview {
        pack.preview(input, userLabel: userLabel)
    }

    /// Wholesale cache reset. Runs already in flight complete for their
    /// current awaiters but are dropped from the join table and never pin,
    /// so a stale result can't outlive the reset.
    public func reset() {
        generation += 1
        cache.removeAll()
        inFlight.removeAll()
    }

    // MARK: - Helpers

    /// Mints the shared run for `key`. Actor isolation makes the
    /// check-then-insert atomic (`ingest` reaches here without suspending);
    /// the minted task runs the uncached pipeline, pins a pinnable result,
    /// and clears its own slot on the way out.
    private func mintTask(input: ELVPastedInput, userLabel: String?, key: String, progress: ELVPipeline.ProgressHandler?) -> Task<ELVPipelineRun, Never> {
        let minted = generation
        let task = Task { [pipeline, weak self] in
            let result = await pipeline.run(input: input, userLabel: userLabel, progress: progress)
            await self?.finish(key: key, mintedIn: minted, result: result)
            return result
        }
        inFlight[key] = task
        return task
    }

    private func finish(key: String, mintedIn minted: Int, result: ELVPipelineRun) {
        // A reset between mint and finish orphans the run: its slot is
        // already gone and a post-reset re-mint under the new generation
        // must not be clobbered or shadowed by the stale result.
        guard minted == generation else { return }
        inFlight[key] = nil
        guard shouldPin(result) else { return }
        if cache.count >= Self.cacheCapacity { cache.removeAll() }
        cache[key] = result
    }

    /// Only a run that finished and gained something is worth pinning: a
    /// failure (offline, bot wall), an unrecognized input, and a record
    /// with no fields and no children all stay uncached so the next paste
    /// retries. Recognized sources can no longer hand back an empty record (the
    /// pipeline fails those as `formatDrift`), but the generic floors still
    /// return an empty link card when every floor misses, so the emptiness
    /// check stays.
    private func shouldPin(_ run: ELVPipelineRun) -> Bool {
        guard let record = run.record else { return false }
        guard !record.fields.isEmpty || record.collections.contains(where: { !$0.value.isEmpty }) else { return false }
        switch pinPolicy {
        case .gainedSomething:
            return true
        case .completeOnly:
            let impairedStep = run.trace.steps.contains { step in
                guard case .produced = step.outcome else { return false }
                return step.truncated || step.settled == false
            }
            return run.trace.nativeOpFailures.isEmpty && record.provenance["captureCanonical"] == nil && !impairedStep
        }
    }

    /// The cache key: the input URL after the matched source's
    /// canonicalization, before any fetch. Recognition here only
    /// derives the key — a cache miss re-enters the pipeline's own
    /// recognition unchanged, so hits and misses agree on what the URL
    /// means.
    private func cacheKey(for url: URL, input: ELVPastedInput, userLabel: String?) -> String {
        var key = url.absoluteString
        if let recognition = pack.registry.recognize(url),
           let source = pack.source(withId: recognition.sourceId),
           let canonicalize = source.canonicalize {
            key = canonicalize.apply(to: url).absoluteString
        }
        guard let paste = ELVPasteContext(input: input, userLabel: userLabel) else { return key }
        // In-memory keys only, and a paste is capped at
        // `ELVPastePolicy.maxLength`, so the raw text keys as is.
        return [key, paste.leading ?? "", paste.blurb ?? "", paste.userLabel ?? ""].joined(separator: "\u{1F}")
    }
}
