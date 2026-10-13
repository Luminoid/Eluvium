import EluviumCatalog
import EluviumCore
import EluviumDOM
import EluviumNet
import EluviumPlaces
import Foundation
import LumiKitCore

/// The app's single entry point to the framework: it loads the bundled
/// starter pack once and runs inputs through the pipeline. Everything else
/// in the app is a thin front end over this.
///
/// Launch design: the singleton itself is cheap to create (op registration
/// plus an empty fallback pack), so view controllers may resolve it whenever
/// they like, as long as they do it lazily (from `viewDidLoad`, never from a
/// stored-property initializer). The expensive part, the starter pack's
/// JSONDecoder decode and `ELVPackValidator` regex compilation, runs in a
/// detached task kicked off at init; call `ready()` before reading
/// `loadedPack`. The `WKWebView` DOM renderer is heavier still (it spins up
/// WebKit) and is MainActor-bound, so the pipeline is only assembled on the
/// MainActor at the first `resolve`, never at launch.
@MainActor
final class ExampleStore {
    // MARK: - Properties

    static let shared = ExampleStore()

    /// This binary's capabilities: EluviumCore + EluviumNet + EluviumDOM give
    /// http / json / archive / feed / dom, so every starter source is active.
    /// The one source of truth — the starter-pack load and the empty
    /// fallback both read it.
    nonisolated static let capabilities = ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: ELVBinary.version)

    /// The loaded pack: the empty fallback until the background load lands.
    /// Await `ready()` first to observe the real starter pack.
    private(set) var loadedPack: ELVLoadedPack

    /// The bundled file pack (`KayaPack.json`), loaded alongside the
    /// starter; the empty fallback when the resource is missing or bad.
    private(set) var filePack: ELVLoadedPack

    /// True once the starter pack failed to load and the app is running on
    /// the empty fallback for good: a build-time bug surfaced at runtime,
    /// which the Sources screen shows instead of an empty list.
    private(set) var loadFailed = false

    /// Every recognizable source for display surfaces (the examples
    /// browser): starter first, file pack after, matching resolve order.
    var allSources: [ELVSource] { loadedPack.sources + filePack.sources }

    /// One HTTP pool for everything the app fetches through the framework:
    /// both pipelines and the catalog walker share it, so the app runs one
    /// connection pool and one egress implementation instead of one per
    /// component. Cheap to create (a URLSession), so it lives from init.
    private let fetcher = ELVHTTPFetcher()
    /// The walker, on the shared fetcher.
    private let enumerator: ELVEnumerator

    /// Built lazily at first `resolve` (see `activePipeline()`); both
    /// pipelines share one renderer.
    private var pipeline: ELVPipeline?
    private var filePipeline: ELVPipeline?
    private var renderer: ELVWebViewRenderer?
    private var loadTask: Task<Void, Never>?

    // MARK: - Init

    private init() {
        // Platform-module ops register before the pack loads so the
        // capability gate sees the binary's real roster. EluviumPlaces
        // contributes geo.anchorLadder@1 (the Identity tab's demo) and
        // place.mapKitLookup, which gmaps.place.mapkit and
        // applemaps.place.mapkit run on a live Maps resolve; registering
        // both keeps every starter source active. A binary that never
        // resolves places would call registerAnchorLadder() alone and let
        // the gate skip those sources. No geocoder is injected: a host
        // passes one through its own rate pacer, and without it a pinless
        // Maps link's street-address anchor is simply skipped.
        ELVNetOps.register()
        ELVPlacesOps.register()
        enumerator = ELVEnumerator(fetcher: fetcher)
        loadedPack = LoadedPackFallback.empty
        filePack = LoadedPackFallback.empty
        loadTask = Task { [capabilities = Self.capabilities] in
            // Detached so the decode + validate never touch the main thread
            // (a plain Task here would inherit the MainActor).
            let packs = await Task.detached(priority: .userInitiated) { () -> (starter: ELVLoadedPack?, file: ELVLoadedPack?) in
                let starter: ELVLoadedPack?
                do {
                    // The bundled pack is authored to load clean; a failure
                    // here is a build-time bug, not a runtime state.
                    starter = try ELVStarterPack.load(capabilities: capabilities)
                } catch {
                    // A build-time bug must not be a silent one: without
                    // this line the app runs forever on the empty fallback
                    // with nothing in the log to say why.
                    LMKLogger.error("Starter pack failed to load; running on the empty fallback", error: error, category: .error)
                    starter = nil
                }
                return (starter, Self.loadBundledFilePack(capabilities: capabilities))
            }.value
            // The framework logs each pack load (version, counts, and a
            // warning per diagnostic) under the dev.luminoid.eluvium
            // subsystem, so those lines anchor a session's log without
            // help from here.
            if let filePack = packs.file {
                self.filePack = filePack
            }
            guard let pack = packs.starter else {
                loadFailed = true
                return
            }
            self.loadedPack = pack
            // The opt-in commerce pack (Amazon/Chewy, `ELVOptInPacks.commerce`)
            // is deliberately not loaded here: those targets' terms restrict
            // automated access (LEGAL.md). A host that wants them opts in.
        }
    }

    // MARK: - Actions

    /// Suspends until the starter pack has finished loading. View
    /// controllers await this (from `viewDidLoad`) before reading
    /// `loadedPack`; after the first completion it returns immediately.
    func ready() async {
        await loadTask?.value
    }

    /// The paste box's policy: the standard one plus the app schemes the
    /// starter pack claims (`comgooglemaps://`, `maps://`, `flighty://`).
    var pastePolicy: ELVPastePolicy {
        loadedPack.pastePolicy
    }

    /// The offline reading of a paste: recognition plus every field the
    /// link and its share text fill, with no network. Routed like
    /// `resolve`, so a file-pack link previews against the file pack.
    func preview(_ input: ELVPastedInput) -> ELVPreview {
        usesFilePack(for: input.url) ? filePack.preview(input) : loadedPack.preview(input)
    }

    /// Runs one URL through the pipeline (an example, a record's link).
    func resolve(url: URL, example: ELVExample? = nil, progress: @escaping @Sendable (ELVPipelineStage) -> Void) async -> ELVPipelineResult {
        await resolve(input: ELVPastedInput(url: url), example: example, progress: progress)
    }

    /// Runs one paste through the pipeline: the link and any share text
    /// around it, which the pack reads for labels and stats. The framework
    /// logs the run's outcome from its trace; corpus runs pass their
    /// `example` so the app adds the expectation verdict, the one thing
    /// only it knows.
    func resolve(input: ELVPastedInput, example: ELVExample? = nil, progress: @escaping @Sendable (ELVPipelineStage) -> Void) async -> ELVPipelineResult {
        await ready()
        var result: ELVPipelineResult
        if usesFilePack(for: input.url) {
            result = await activeFilePipeline().run(input: input, progress: progress).result
        } else {
            result = await activePipeline().run(input: input, progress: progress).result
            // The residual seam for a starter pack without generic floors:
            // a truly unrecognized input still tries the file pack.
            if case .unrecognized = result {
                result = await activeFilePipeline().run(input: input, progress: progress).result
            }
        }
        if let example {
            ParseLog.log(example: example, result: result, url: input.url)
        }
        return result
    }

    /// Runs a seeded list source (browse): recognition is skipped, the
    /// pack-authored seed is the input. The framework logs the outcome,
    /// including an invalid seed's `.failed(.invalidURL)`.
    func resolveSeed(sourceId: String) async -> ELVPipelineResult {
        await ready()
        return await activePipeline().runSeed(sourceId: sourceId).result
    }

    /// Walks a catalog source from `resumeFrom` through the shared
    /// enumerator, pausing where `onPage` says. The framework logs the walk
    /// (a summary line, a debug line per page, and a warning per skipped
    /// page with its failure).
    func enumerate(source: ELVSource, resumeFrom: ELVEnumerationState, onPage: @Sendable (ELVEnumerationPage) -> Bool) async -> ELVEnumerationResult {
        await ready()
        return await enumerator.enumerate(source: source, resumeFrom: resumeFrom, onPage: onPage)
    }

    /// Whether `url` routes to the bundled file pack's pipeline. The corpus
    /// log caught the original "fall back on .unrecognized" funnel never
    /// firing: the starter's generic floor answers EVERY URL, so a file-pack
    /// source could never win. A URL the file pack recognizes specifically,
    /// and the starter does not, runs the file pipeline instead — a file
    /// source outranks the starter's floor, never its real sources.
    /// Internal so the app tests can pin the routing.
    func usesFilePack(for url: URL) -> Bool {
        loadedPack.registry.recognize(url) == nil && filePack.registry.recognize(url) != nil
    }

    // MARK: - Helpers

    /// The pipeline, assembling it on first use: `ELVWebViewRenderer` is
    /// MainActor-bound and spinning up WebKit is exactly the kind of work
    /// that must not ride on app launch.
    private func activePipeline() -> ELVPipeline {
        if let pipeline { return pipeline }
        let built = ELVPipeline(pack: loadedPack, fetcher: fetcher, domRenderer: activeRenderer())
        pipeline = built
        return built
    }

    /// The file pack's pipeline, sharing the starter pipeline's renderer and
    /// fetcher so the fallback never spins up a second webview or HTTP pool.
    private func activeFilePipeline() -> ELVPipeline {
        if let filePipeline { return filePipeline }
        let built = ELVPipeline(pack: filePack, fetcher: fetcher, domRenderer: activeRenderer())
        filePipeline = built
        return built
    }

    private func activeRenderer() -> ELVWebViewRenderer {
        if let renderer { return renderer }
        let built = ELVWebViewRenderer()
        renderer = built
        return built
    }

    /// Loads the bundled JSON pack (`KayaPack.json`): a pack shipped as a
    /// resource file instead of compiled-in source, the real delivery shape
    /// for pack config. Bundle resources are code-signed with the binary,
    /// so they carry embedded trust; bytes that crossed the network
    /// still go through `ELVPackVerifier` instead.
    nonisolated static func loadBundledFilePack(capabilities: ELVCapabilities) -> ELVLoadedPack? {
        guard let url = Bundle.main.url(forResource: "KayaPack", withExtension: "json") else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try ELVPackLoader.load(embedded: data, capabilities: capabilities)
        } catch {
            LMKLogger.error("Bundled file pack failed to load", error: error, category: .error)
            return nil
        }
    }
}

/// A never-nil placeholder so `loadedPack` stays non-optional while the real
/// pack loads (and if the bundled pack is corrupt, a build bug, forever).
/// Internal, not private: the app tests pin that it loads, so a future
/// loader gate rejecting the fallback fails in tests, not at launch.
enum LoadedPackFallback {
    static let empty: ELVLoadedPack = // swiftlint:disable:next force_try
        try! load()

    /// Split from `empty` so the pin test exercises the same path without
    /// the trap.
    static func load() throws -> ELVLoadedPack {
        let data = Data(#"{"schemaVersion":1,"packVersion":"empty","sources":[]}"#.utf8)
        return try ELVPackLoader.load(embedded: data, capabilities: ExampleStore.capabilities)
    }
}
