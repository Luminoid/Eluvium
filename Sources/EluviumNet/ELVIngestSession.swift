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
public actor ELVIngestSession {
    /// Session-lifetime bound: inputs arrive by hand (paste, share sheet),
    /// so the cap only guards a pathological session and a wholesale reset
    /// beats LRU bookkeeping (the TripDays session-cache rule).
    static let cacheCapacity = 64

    private let pack: ELVLoadedPack
    private let pipeline: ELVPipeline

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

    public init(pack: ELVLoadedPack, fetcher: any ELVFetching = ELVHTTPFetcher(), domRenderer: (any ELVDOMRendering)? = nil) {
        self.pack = pack
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
        let key = cacheKey(for: url)
        if var cached = cache[key] {
            cached.trace.servedFromCache = true
            ELVLog.debug(.fetch, "Ingest cache hit source=\(cached.trace.sourceIds.last ?? "-") host=\(ELVLogFormat.host(url))")
            return cached
        }
        if let running = inFlight[key] { return await running.value }
        return await mintTask(url: url, key: key, progress: progress).value
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
    private func mintTask(url: URL, key: String, progress: ELVPipeline.ProgressHandler?) -> Task<ELVPipelineRun, Never> {
        let minted = generation
        let task = Task { [pipeline, weak self] in
            let result = await pipeline.run(url: url, progress: progress)
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
        return !record.fields.isEmpty || record.collections.contains { !$0.value.isEmpty }
    }

    /// The cache key: the input URL after the matched source's
    /// canonicalization, before any fetch. Recognition here only
    /// derives the key — a cache miss re-enters the pipeline's own
    /// recognition unchanged, so hits and misses agree on what the URL
    /// means.
    private func cacheKey(for url: URL) -> String {
        guard let recognition = pack.registry.recognize(url),
              let source = pack.source(withId: recognition.sourceId),
              let canonicalize = source.canonicalize
        else { return url.absoluteString }
        return canonicalize.apply(to: url).absoluteString
    }
}
