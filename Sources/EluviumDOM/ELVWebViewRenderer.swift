import EluviumCore
import Foundation
import Synchronization
import WebKit
#if canImport(UIKit)
    import UIKit
#endif

/// The headless `WKWebView` DOM engine. It renders a URL in an
/// ephemeral, offscreen webview, waits for the unified settle policy
/// (stability AND a content signal), evaluates one compiled extraction
/// program (no raw pack JS — see `ELVSelectorJSCompiler`), and returns the
/// settled HTML plus resolved CSS values. `@MainActor` because `WKWebView`
/// is main-actor-bound. One render at a time: a main-actor method is
/// reentrant at every `await`, so two concurrent `render` calls would
/// otherwise interleave their loads and polls on the one pooled webview;
/// `renderTail` chains them in call order instead.
///
/// The webview is pooled: created on the first render, parked on
/// `about:blank` between renders, and evicted on a memory warning. A fresh
/// `WKWebView` costs a WebContent + Networking process pair (tens of MB,
/// 100-300 ms), which per-render construction paid every single time.
@MainActor
public final class ELVWebViewRenderer: NSObject, ELVDOMRendering {
    /// A hard ceiling on total render time, independent of the poll
    /// budget — the load watchdog. On expiry the partial render is
    /// still returned. Measured on `ContinuousClock`, like the fetcher's
    /// deadline, so a wall-clock change mid-render neither fires the
    /// watchdog early nor holds it open.
    private let watchdogSeconds: Double

    /// The pooled webview (see the type comment); nil until the first
    /// render and after a memory-warning eviction.
    private var pooledWebView: WKWebView?

    /// The render queue's tail: completes once the most recently enqueued
    /// render has returned or thrown. Each new render awaits the tail it
    /// found and installs its own, synchronously, before its first await,
    /// so two callers arriving back to back never both see the same
    /// predecessor. A queued render retains the renderer until it runs.
    private var renderTail: Task<Void, Never>?

    /// The per-hop egress gate, installed as the pooled webview's navigation
    /// delegate. Held strongly here because `navigationDelegate` is weak;
    /// the gate holds no reference back, so there is no cycle.
    private let navigationGate = NavigationGate()

    #if canImport(UIKit)
        /// Evicts the pooled webview under memory pressure; removed in
        /// `deinit`, which is isolated so the read needs no unsafe opt-out.
        private var memoryWarningObserver: (any NSObjectProtocol)?
    #endif

    /// The between-renders parking target; the literal cannot fail to parse.
    private static let blankURL = URL(string: "about:blank")!

    /// The floor under every evaluate race: even with the watchdog spent,
    /// one last evaluate gets this long before the render is unblocked.
    private static let minimumEvaluateSeconds: Double = 2

    /// The extracted-HTML byte cap, mirroring the HTTP path's default body
    /// cap (`ELVFetchBudget`). The compiled program slices `outerHTML` to
    /// this many UTF-16 units before it crosses WebKit IPC (the early cap);
    /// the receipt-side cap below is the hard byte bound, since a UTF-16
    /// slice can still exceed it in bytes.
    private static let maxHTMLBytes = 3_000_000

    /// Test seam: how the live webview URL is read for canonical-URL capture
    /// (the entry snapshot and every poll). Nil in production, reading the
    /// webview's own `url`; EluviumDOMTests inject deterministic rewrite and
    /// stale-pool sequences without a network load.
    var urlProbeOverride: ((WKWebView) -> URL?)?

    public init(watchdogSeconds: Double = 30) {
        // Bounded before it becomes a `Duration` (which traps on a
        // non-finite or out-of-range value): a century, the package's
        // duration ceiling.
        self.watchdogSeconds = watchdogSeconds.isFinite ? min(max(watchdogSeconds, 0), ELVBounds.centurySeconds) : ELVBounds.centurySeconds
        super.init()
        #if canImport(UIKit)
            memoryWarningObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.evictPooledWebView() }
            }
        #endif
    }

    isolated deinit {
        #if canImport(UIKit)
            if let memoryWarningObserver {
                NotificationCenter.default.removeObserver(memoryWarningObserver)
            }
        #endif
        // A queued or running render retains `self`, so by the time deinit
        // runs the tail has completed; cancelling is bookkeeping, not
        // teardown.
        renderTail?.cancel()
    }

    public nonisolated func render(_ request: ELVDOMRequest) async throws -> ELVDOMResult {
        try await enqueueRender(request)
    }

    // MARK: - Serialization

    /// Runs `request` after every render enqueued before it. The egress
    /// refusal comes first so a refused URL never waits in line. The job
    /// awaits its predecessor's tail (a `Never`-failing task, so the wait
    /// itself cannot be cancelled out of order), then re-checks its own
    /// cancellation before touching the webview; the new tail awaits the
    /// job's result whether it returned or threw, which is what lets a
    /// cancelled render release the slot to the one behind it.
    private func enqueueRender(_ request: ELVDOMRequest) async throws -> ELVDOMResult {
        // Defense in depth: the pipeline egress-checks the step URL
        // before calling render, but the renderer is public API, so a host
        // calling it directly meets the same single policy. `data:` URLs are
        // exempt: the document IS the URL — the top-level load fetches
        // nothing — and they are the engine's only offline-testable entry.
        if request.url.scheme?.lowercased() != "data",
           let reason = ELVEgressPolicy.violation(request.url) {
            throw ELVEgressRefusal(reason: reason)
        }

        let previous = renderTail
        let job = Task { [previous] in
            await previous?.value
            try Task.checkCancellation()
            return try await self.renderOnMain(request)
        }
        renderTail = Task { _ = await job.result }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    // MARK: - Render

    private func renderOnMain(_ request: ELVDOMRequest) async throws -> ELVDOMResult {
        let webView = await preparedWebView(userAgent: request.userAgent)
        // Teardown parks the webview on about:blank as well as stopping the
        // load: an in-flight `evaluateJavaScript`'s strong capture would
        // otherwise pin the rendered page, and navigating away is what lets
        // a multi-MB DOM release while the webview itself stays pooled.
        defer {
            webView.stopLoading()
            webView.load(URLRequest(url: Self.blankURL))
        }

        // Snapshot-blanking (the TripDays scar tissue): the pooled
        // webview can still sit on the PREVIOUS job's page — the post-render
        // park is fire-and-forget, and a failed load leaves the URL
        // untouched — and surfacing that URL as a capture would land link
        // A's canonical URL (and pin) on link B. Snapshot it, blank the page
        // so it can't survive the load, and refuse ever to attribute the
        // snapshot (or about:blank) to this request's capture.
        let staleURL = liveURL(of: webView)
        if let staleURL, staleURL != Self.blankURL {
            webView.load(URLRequest(url: Self.blankURL))
        }
        // The rescue is gated on the input URL LACKING the target data:
        // a URL already matching the predicate has nothing to capture, and
        // watching it would immediately "capture" the input itself.
        let captureWanted: ELVCanonicalCapture? = request.captureCanonical.flatMap { capture in
            matches(regex: capture.untilURLRegex, in: request.url.absoluteString) ? nil : capture
        }

        let start = ContinuousClock.now
        // Every evaluate races this same deadline, so the final extraction
        // sits inside the watchdog too, not just the poll loop.
        let deadline = start + .seconds(watchdogSeconds)
        navigationGate.beginRender()
        let navigation = webView.load(URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: watchdogSeconds))
        navigationGate.expect(navigation)

        // The settle budget measures the page settling, not WebKit starting
        // up: a cold WebContent process launch takes seconds (20 s and more
        // when a full test run starts several at once), and polls spent
        // against a document that has not committed are the budget wasted
        // before the page exists. Wait for this navigation's commit, or a
        // failed load, under the watchdog alone; the polls start after.
        while !navigationGate.committed, !navigationGate.loadFailed, ContinuousClock.now <= deadline {
            try await Self.sleep(seconds: min(request.settle.pollSeconds, 0.25))
            if let reason = navigationGate.mainFrameRefusal {
                throw ELVEgressRefusal(reason: reason)
            }
        }

        // Poll for settle: stable body length AND a content signal, or a
        // captured canonical URL, or the poll/watchdog budget runs out.
        // Capture polls are cheaper than settle probes and the Maps rewrite
        // can land seconds after settle, so the capture keeps its own budget
        // (`ELVCanonicalCapture.maxPolls`) past the settle rounds.
        let settle = request.settle
        let probe = ELVSelectorJSCompiler.settleProbe(settleSignals: settle.signals)
        let captureBudget = captureWanted?.maxPolls ?? 0
        var previousLength = -1
        var stableStreak = 0
        var canonicalURL: URL?
        var settled = false

        for round in 0 ..< max(settle.maxPolls, captureBudget) {
            // A load that failed outright leaves nothing to settle; extract
            // whatever the document holds instead of polling the budget out.
            if ContinuousClock.now > deadline || navigationGate.loadFailed { break }
            try await Self.sleep(seconds: settle.pollSeconds)
            // A cancelled main-frame hop means the document on screen is
            // not the one the pack asked for; extracting from it would be a
            // silent wrong-page record, so the render fails the same way the
            // pre-load check does.
            if let reason = navigationGate.mainFrameRefusal {
                throw ELVEgressRefusal(reason: reason)
            }

            // Canonical-URL capture: watch the webview's own URL for
            // Google's client-side history.replaceState rewrite. Never the
            // stale snapshot, never the blank park, and — the surfacing
            // contract — never a URL the egress policy refuses.
            if let capture = captureWanted, canonicalURL == nil, round < captureBudget,
               let live = liveURL(of: webView), live != staleURL, live != Self.blankURL,
               matches(regex: capture.untilURLRegex, in: live.absoluteString),
               ELVEgressPolicy.violation(live) == nil {
                // A captured canonical is itself a settle signal (the Maps
                // rescue): once the pin materializes, extract.
                canonicalURL = live
                settled = true
                break
            }

            if !settled, round < settle.maxPolls {
                guard let probeResult = try? await evaluateJSON(probe, in: webView, deadline: deadline) else { continue }
                // Page-controlled JS (a shadowed `innerText.length` getter)
                // must not reach Int(...) unclamped: Int(1e300) traps.
                let rawLength = probeResult["length"]?.numberValue ?? 0
                let length = rawLength.isFinite ? Int(min(max(rawLength, 0), 1e9)) : 0
                let anySignal = probeResult["anySignal"] == .bool(true)

                stableStreak = length == previousLength ? stableStreak + 1 : 0
                previousLength = length
                // Settled = a content signal present AND the body has stopped
                // growing for two polls. The challenge-shell case never sets
                // anySignal, so it correctly burns the budget rather than
                // exiting early with nothing.
                if anySignal, stableStreak >= 1 {
                    settled = true
                }
            }

            // Settled with no capture pending (or the capture budget spent):
            // nothing left to wait for. A settled page whose capture hasn't
            // landed keeps polling the URL alone.
            if settled, canonicalURL == nil, captureWanted == nil || round + 1 >= captureBudget {
                break
            }
        }

        // Extract once from the settled (or watchdog-cut, partial) DOM. A
        // failed evaluate still returns the partial (empty) result, as
        // before, but its reason now rides the result instead of vanishing.
        let program = ELVSelectorJSCompiler.compile(css: request.css, maxHTMLBytes: Self.maxHTMLBytes)
        var extractionError: String?
        let extraction: ELVRawJSON
        do {
            if let evaluated = try await evaluateJSON(program, in: webView, deadline: deadline) {
                extraction = evaluated
            } else {
                extraction = .object([:])
                extractionError = "extraction returned no JSON"
            }
        } catch {
            extraction = .object([:])
            extractionError = error is EvaluateTimeout ? "evaluate timed out" : ELVLog.describe(error).summary
        }
        // A hop refused after the last poll still disqualifies the page.
        if let reason = navigationGate.mainFrameRefusal {
            throw ELVEgressRefusal(reason: reason)
        }
        var html = extraction["html"]?.stringValue ?? ""
        // The receipt-side cap is the hard byte bound behind the compiler's
        // UTF-16 slice: one pathological page must not ride tens of MB into
        // the extractor. Deliberately lossy at the cut (a byte cap can land
        // mid-character), same as the HTTP body cap — a failable
        // conversion would reject the whole payload over the split
        // character.
        if html.utf8.count > Self.maxHTMLBytes {
            html = String(decoding: html.utf8.prefix(Self.maxHTMLBytes), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        }
        var cssResults: [String: String] = [:]
        for (key, value) in extraction["results"]?.objectValue ?? [:] {
            if let string = value.stringValue { cssResults[key] = string }
        }
        // Last-chance capture from the rendered document's own URL, under
        // the same guards as the poll: not the stale snapshot, not the blank
        // park, egress-clean.
        if canonicalURL == nil, let capture = captureWanted,
           let final = extraction["url"]?.stringValue.flatMap({ URL(string: $0) }),
           final != staleURL, final != Self.blankURL,
           matches(regex: capture.untilURLRegex, in: final.absoluteString),
           ELVEgressPolicy.violation(final) == nil {
            canonicalURL = final
        }
        let finalURL = webView.url ?? request.url
        let loadError = navigationGate.loadError.map { ELVLog.describe($0).summary }
        let elapsed = ELVLogFormat.milliseconds(ContinuousClock.now - start)
        ELVLog.debug(
            .render,
            "Render host=\(ELVLogFormat.host(request.url)) settled=\(settled) captured=\(canonicalURL != nil) bytes=\(html.utf8.count) css=\(cssResults.count) "
                + "load=\(loadError ?? "ok") evaluate=\(extractionError ?? "ok") in \(elapsed)ms",
            private: "final=\(finalURL.absoluteString)"
        )

        return ELVDOMResult(
            finalURL: finalURL,
            html: html,
            cssResults: cssResults,
            settled: settled,
            canonicalURL: canonicalURL,
            loadError: loadError,
            extractionError: extractionError
        )
    }

    // MARK: - Per-hop egress

    /// Whether the webview may navigate a frame to `url`: the renderer's own
    /// `about:blank` park (and `about:srcdoc` frames) and `data:` documents
    /// pass, since neither fetches anything; everything else meets the
    /// egress policy. Static and nonisolated so the decision is testable
    /// without a `WKNavigationAction`.
    nonisolated static func allowsMainFrameNavigation(to url: URL) -> Bool {
        navigationRefusal(for: url) == nil
    }

    /// Whether a REFUSED main-frame hop to `url` means the document the
    /// pack asked for is gone: only a web-scheme hop (a redirect or script
    /// navigation onto plain http or a private host) would have replaced
    /// it. A hand-off to an app URL scheme (KAYA's share page sets
    /// `location.href` to `kaya://…` on touch-capable UAs) is cancelled
    /// like every refusal but leaves the page on screen, so the render goes
    /// on and extracts it.
    nonisolated static func mainFrameRefusalIsFatal(for url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": true
        default: false
        }
    }

    /// The egress reason a navigation to `url` is refused, nil when allowed.
    private nonisolated static func navigationRefusal(for url: URL) -> String? {
        switch url.scheme?.lowercased() {
        case "about", "data": nil
        default: ELVEgressPolicy.violation(url)
        }
    }

    /// The navigation delegate that closes the redirect gap. The
    /// pre-load check vets the URL the pack built, but `WKWebView` follows
    /// server redirects, meta refreshes, and script navigations on its own,
    /// so without this a public page could hop the main frame onto an
    /// internal host. Every frame's navigation is decided before it starts;
    /// refused ones are cancelled, and a main-frame refusal onto a web
    /// scheme is recorded so the render fails typed (an app-scheme hand-off
    /// is cancelled silently: `mainFrameRefusalIsFatal`). Subresources
    /// (scripts, stylesheets, XHR and
    /// fetch, images) never pass through a navigation policy: their egress
    /// is inherent to running a webview at all, and the content rule list
    /// trims only what extraction never reads.
    private final class NavigationGate: NSObject, WKNavigationDelegate {
        /// The reason the render in flight had a main-frame hop cancelled;
        /// nil while clean. `beginRender` resets it per render.
        private(set) var mainFrameRefusal: String?
        /// Whether the render's own navigation has committed a document
        /// (the settle polls start here) and whether its load failed before
        /// committing (nothing will ever settle; extract and return). Both
        /// reset per render; the blank park that precedes a render commits
        /// a different `WKNavigation`, which is why the expected one is
        /// matched by identity instead of "any commit".
        private(set) var committed = false
        private(set) var loadFailed = false
        /// The error the failed load reported, kept for the result's
        /// `loadError` rather than dropped with the flag.
        private(set) var loadError: (any Error)?
        private var expected: WKNavigation?

        func beginRender() {
            mainFrameRefusal = nil
            committed = false
            loadFailed = false
            loadError = nil
            expected = nil
        }

        /// The navigation `load` returned for this render; nil (WebKit gave
        /// none back) accepts the next commit whatever its navigation.
        func expect(_ navigation: WKNavigation?) {
            expected = navigation
        }

        private func isExpected(_ navigation: WKNavigation?) -> Bool {
            expected == nil || navigation === expected
        }

        func webView(_: WKWebView, didCommit navigation: WKNavigation!) {
            if isExpected(navigation) { committed = true }
        }

        func webView(_: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            guard isExpected(navigation) else { return }
            loadFailed = true
            loadError = error
        }

        func webView(_: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            guard isExpected(navigation), !committed else { return }
            loadFailed = true
            loadError = error
        }

        func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, let reason = ELVWebViewRenderer.navigationRefusal(for: url) else {
                decisionHandler(.allow)
                return
            }
            // A subframe on a refused host is the same egress and is
            // cancelled the same way, but only the main frame changes what
            // the render IS: the document the pack asked for never arrived.
            // An app-scheme hand-off cannot replace the document, so it is
            // cancelled without a record. A nil target frame is a new
            // window, which a headless webview with no UI delegate never
            // opens.
            if navigationAction.targetFrame?.isMainFrame ?? false, ELVWebViewRenderer.mainFrameRefusalIsFatal(for: url) {
                mainFrameRefusal = reason
            }
            decisionHandler(.cancel)
        }
    }

    // MARK: - Webview pool

    /// Blocks image / media / font subresource loads. Extraction reads DOM
    /// text, attributes, and resolved CSS values — never decoded pixels — so
    /// these loads only cost bandwidth, settle time, and a wall of
    /// WebContent decode-error log noise (the simulator lacks WEBP / AVIF /
    /// video codecs). Scripts, stylesheets, and XHR stay loaded: pages that
    /// build their document in script need them to finish.
    private static let subresourceBlockRules = """
    [{"trigger": {"url-filter": ".*", "resource-type": ["image", "media", "font"]}, "action": {"type": "block"}}]
    """

    /// Presents the headless document as visible. An offscreen
    /// `WKWebView` reports `document.hidden == true` and
    /// `visibilityState == "hidden"` for its whole life, and pages gate real
    /// work on that: KAYA's share route resolves its climb's slug over
    /// GraphQL, then starts the app hand-off and the web redirect to
    /// `/climb/<slug>` only from a visible document (`document.hidden ||
    /// start()`), so the render sat on the SPA's spinner until the settle
    /// budget ran out (2026-09-10). Headless Chrome reports `visible` for
    /// the same reason; this is the WebKit equivalent. Defined on
    /// `Document.prototype` so instance and prototype reads agree, injected
    /// into every frame at document start. Engine code, not pack JS.
    private static let presentAsVisibleSource = """
    (function () {
      var hidden = { get: function () { return false; }, configurable: true };
      var state = { get: function () { return 'visible'; }, configurable: true };
      try { Object.defineProperty(Document.prototype, 'hidden', hidden); } catch (e) {}
      try { Object.defineProperty(Document.prototype, 'visibilityState', state); } catch (e) {}
    })();
    """

    /// The pooled webview, configured for this render. The data store stays
    /// `nonPersistent`: no cookie or session sharing with
    /// anything the user is logged into. Pooling shares that ephemeral store
    /// across this renderer's own renders only — never with Safari, never
    /// across relaunches.
    private func preparedWebView(userAgent: String) async -> WKWebView {
        if let pooled = pooledWebView {
            pooled.customUserAgent = userAgent
            return pooled
        }
        // Compiled per pool creation, not per render; the rule-list store
        // caches the compiled artifact on disk. A compile failure means
        // this pool renders unblocked, never that the render fails.
        let blockList = await (try? WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "elv-block-subresources",
            encodedContentRuleList: Self.subresourceBlockRules
        )) ?? nil
        // Re-check after the await: renders are serialized, but an eviction
        // and a re-creation can interleave with the compile.
        if let pooled = pooledWebView {
            pooled.customUserAgent = userAgent
            return pooled
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.presentAsVisibleSource, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        if let blockList {
            configuration.userContentController.add(blockList)
        }
        let created = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        created.navigationDelegate = navigationGate
        pooledWebView = created
        created.customUserAgent = userAgent
        return created
    }

    /// Drops the pooled webview — its WebContent + Networking processes and
    /// any parked DOM. An in-flight render holds its own reference and
    /// finishes normally; the instance just stops being retained for the
    /// next render, which recreates the pool.
    private func evictPooledWebView() {
        pooledWebView = nil
    }

    // MARK: - Helpers

    /// The live webview URL as capture sees it: the test seam when
    /// injected, the webview's own `url` otherwise.
    private func liveURL(of webView: WKWebView) -> URL? {
        if let urlProbeOverride { return urlProbeOverride(webView) }
        return webView.url
    }

    /// Thrown by the deadline racer when an evaluate outruns its budget.
    /// Callers `try?` it away: a hung poll degrades to a missed poll, a
    /// hung final extraction degrades to the watchdog-cut partial result
    /// — never a hang.
    private nonisolated struct EvaluateTimeout: Error {}

    /// Evaluates a script that returns a JSON string and parses it into a
    /// `Sendable` `ELVRawJSON` — the primitive that safely crosses the
    /// continuation boundary (a raw `Any?` from WebKit does not). Raced
    /// against `deadline`: WebKit does not guarantee the completion ever
    /// fires (a dead WebContent process goes silent), and an unraced
    /// continuation would hang the render forever, pinning the webview.
    private func evaluateJSON(_ script: String, in webView: WKWebView, deadline: ContinuousClock.Instant) async throws -> ELVRawJSON? {
        let json = try await race(deadline: deadline) {
            try await Self.evaluateString(script, in: webView)
        }
        guard let json else { return nil }
        // The payload embeds the page's outerHTML (multi-MB) as a bridged
        // UTF-16 string, so the UTF-8 transcode moves off the main actor
        // with the JSONSerialization + re-materialization: the copy costs
        // as much as the parse. `String` and `ELVRawJSON` are `Sendable`;
        // the detached body is nonisolated and immediately awaited, so the
        // handle needs no storage.
        return await Task.detached { ELVRawJSON.parse(Data(json.utf8)) }.value
    }

    /// First result wins: `operation` against the remaining watchdog budget
    /// (never under `minimumEvaluateSeconds`). The operation child cannot be
    /// truly cancelled — WebKit offers no evaluate cancellation — so losing
    /// the race force-resumes its continuation via the cancellation handler
    /// (`evaluateString`), which is what lets the group, and the render,
    /// actually unblock.
    private func race<T: Sendable>(deadline: ContinuousClock.Instant, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let wake = max(deadline, ContinuousClock.now + .seconds(Self.minimumEvaluateSeconds))
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(until: wake, clock: .continuous)
                throw EvaluateTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw EvaluateTimeout() }
            return first
        }
    }

    /// The exactly-once resume state for `evaluateString`.
    private nonisolated enum EvaluateState {
        case pending
        case running(CheckedContinuation<String?, any Error>)
        case finished

        /// The continuation if still resumable, transitioning to `finished`.
        mutating func take() -> CheckedContinuation<String?, any Error>? {
            guard case let .running(continuation) = self else {
                self = .finished
                return nil
            }
            self = .finished
            return continuation
        }
    }

    /// Bridges `evaluateJavaScript`'s completion into async, resuming
    /// exactly once. Cancellation — the deadline racer winning — resumes
    /// early with `CancellationError`; WebKit's completion, which may arrive
    /// late or never, resumes only when it gets there first and otherwise
    /// lands in the void instead of double-resuming.
    private static func evaluateString(_ script: String, in webView: WKWebView) async throws -> String? {
        let state = Mutex<EvaluateState>(.pending)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
                let proceed = state.withLock { current -> Bool in
                    guard case .pending = current else { return false }
                    current = .running(continuation)
                    return true
                }
                guard proceed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // The client world shares the page's DOM but not its JS
                // globals, so a hostile page cannot redefine `JSON.stringify`
                // or `String.prototype.slice` to return hundreds of MB past
                // the program's own size cap. The programs read only the DOM.
                webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                    guard let continuation = state.withLock({ $0.take() }) else { return }
                    switch result {
                    case let .success(value):
                        continuation.resume(returning: value as? String)
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.withLock { $0.take() }?.resume(throwing: CancellationError())
        }
    }

    /// Clamped sleep. `pollSeconds` is already clamped upstream by
    /// `ELVSettlePolicy`, but this helper also serves other durations, so it
    /// keeps a belt-and-braces bound of its own before the `UInt64`
    /// conversion (which traps on negative or non-finite input).
    private nonisolated static func sleep(seconds: Double) async throws {
        let clamped = seconds.isFinite ? min(max(seconds, 0), 60) : 0
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }

    private nonisolated func matches(regex pattern: String, in string: String) -> Bool {
        // The shared compile cache also input-caps the subject, so a pack
        // pattern is neither recompiled per poll nor free to backtrack over
        // an unbounded subject.
        ELVRegexCache.matches(pattern, in: string)
    }
}
