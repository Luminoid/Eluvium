import EluviumCore
import Foundation
import Testing
@testable import EluviumDOM

/// `.serialized`: every test here boots its own WKWebView, and nine WebContent
/// launches at once take 3-6 s each in the runner (1-2 s even on an idle
/// machine), longer than the tight poll budgets several tests deliberately
/// use to exercise the watchdog path. One webview at a time keeps a launch
/// well inside those budgets, so a failure here means the renderer, not the
/// machine. The declared-first warm-up test absorbs the one cost that is
/// not per-webview: the test host's FIRST WebContent process launch, which
/// has taken 20 s in a full package run and over 100 s on a machine that
/// spent the day launching simulators (2026-09-10). Every timed test below
/// runs against a booted WebKit.
@Suite("WebView renderer", .serialized)
@MainActor
struct ELVWebViewRendererTests {
    /// Renders inline HTML from a data: URL and asserts the compiled program
    /// extracted the settled DOM. This is the real WKWebView path, no network.
    private func dataURL(_ html: String) -> URL? {
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? html
        return URL(string: "data:text/html,\(encoded)")
    }

    @Test
    func `WebKit warm-up: the test host's first WebContent launch happens here, not in a timed render`() async throws {
        // Generous watchdog, tiny poll budget: the renderer's settle polls
        // start only once the navigation commits, so this waits exactly as
        // long as the cold launch takes (1-4 s on an idle machine) and no
        // longer. The assertion is real; a WebKit that cannot boot inside
        // three minutes is a broken runner, and this test should say so
        // instead of the next one's budget expiring for an unrelated reason.
        let renderer = ELVWebViewRenderer(watchdogSeconds: 180)
        let request = try ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>Warm</h1></body></html>")),
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            settle: ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.25, maxPolls: 12),
            css: [ELVCSSQuery(key: "h1", selector: "h1", attr: nil)]
        )
        let result = try await renderer.render(request)
        #expect(result.cssResults["h1"] == "Warm")
    }

    @Test
    func `Declared regions read rendered text: the h1, its header block, and the body`() async throws {
        let html = """
        <html><body><nav>Explore nearby</nav>
        <section><div><header><h1>Hidden Falls Trail</h1><p>Moderate, 5.1 mi</p></header></div></section>
        <aside>Mission Peak Loop, Hard, 8.2 mi</aside>
        <div style="display:none">hidden text</div></body></html>
        """
        let renderer = ELVWebViewRenderer(watchdogSeconds: 10)
        let source = ELVSource(id: "t", kind: "trail", fetch: ELVFetchPlan(mode: "dom", regions: ["h1", "header", "body"]))
        let request = try ELVDOMRequest(
            url: #require(dataURL(html)),
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            settle: ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.2, maxPolls: 15),
            css: source.cssQueries(for: #require(source.fetch?.resolvedSteps.first))
        )
        let result = try await renderer.render(request)
        #expect(result.cssResults["@h1"] == "Hidden Falls Trail")
        let header = try #require(result.cssResults["@header"])
        #expect(header.contains("Moderate, 5.1 mi"))
        #expect(!header.contains("Mission Peak"))
        let body = try #require(result.cssResults["@body"])
        #expect(body.contains("Mission Peak Loop"))
        // innerText is RENDERED text: display:none content is absent.
        #expect(!body.contains("hidden text"))
    }

    @Test
    func `An idle renderer releases its pooled webview`() async throws {
        let renderer = ELVWebViewRenderer(watchdogSeconds: 10, idleTeardownSeconds: 1)
        let request = try ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>Idle</h1></body></html>")),
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            settle: ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.2, maxPolls: 15),
            css: []
        )
        _ = try await renderer.render(request)
        #expect(renderer.hasPooledWebView)
        var polls = 0
        while renderer.hasPooledWebView, polls < 300 {
            try await Task.sleep(for: .milliseconds(20))
            polls += 1
        }
        #expect(!renderer.hasPooledWebView)
    }

    @Test
    func `A rendered page yields CSS results and settled HTML`() async throws {
        let html = """
        <html><head><title>Trail</title>
        <meta property="og:title" content="Hidden Falls Trail">
        </head><body><h1>Hidden Falls Trail</h1><span class="difficulty">Moderate</span></body></html>
        """
        // The warm-up above has paid the host's first WebKit launch, and the
        // renderer's settle polls start at the navigation's commit, so this
        // runs on an ordinary budget; warm, it finishes in about a second.
        let renderer = ELVWebViewRenderer(watchdogSeconds: 10)
        let request = try ELVDOMRequest(
            url: #require(dataURL(html)),
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            settle: ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.2, maxPolls: 15),
            css: [
                ELVCSSQuery(key: "h1", selector: "h1", attr: nil),
                ELVCSSQuery(key: ".difficulty", selector: ".difficulty", attr: "text"),
            ]
        )
        let result = try await renderer.render(request)
        #expect(result.settled)
        #expect(result.cssResults["h1"] == "Hidden Falls Trail")
        #expect(result.cssResults[".difficulty"] == "Moderate")
        #expect(result.html.contains("Hidden Falls Trail"))
    }

    @Test
    func `The headless document presents as visible, so visibility-gated pages proceed`() async throws {
        // KAYA's share route (any app-hand-off page) starts its web redirect
        // only from a visible document, and an offscreen WKWebView reports
        // hidden for its whole life. This page writes its h1 only when the
        // document reads as visible both ways a page can ask: the instance
        // property and the prototype getter.
        let html = """
        <html><body><div id="spinner">loading</div><script>
        var own = document.hidden;
        var proto = Object.getOwnPropertyDescriptor(Document.prototype, 'hidden').get.call(document);
        if (!own && !proto && document.visibilityState === 'visible') {
          document.body.insertAdjacentHTML('beforeend', '<h1>Visible</h1>');
        }
        </script></body></html>
        """
        let renderer = ELVWebViewRenderer(watchdogSeconds: 10)
        let request = try ELVDOMRequest(
            url: #require(dataURL(html)),
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            settle: ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.2, maxPolls: 15),
            css: [ELVCSSQuery(key: "h1", selector: "h1", attr: nil)]
        )
        let result = try await renderer.render(request)
        #expect(result.settled)
        #expect(result.cssResults["h1"] == "Visible")
    }

    @Test
    func `A metadata-free page never settles but still returns its partial HTML`() async throws {
        // No h1, no jsonld, no og:title — the challenge-shell shape. The poll
        // budget expires; the partial render is still returned (watchdog).
        let html = "<html><body><div>just a spinner</div></body></html>"
        let renderer = ELVWebViewRenderer(watchdogSeconds: 5)
        let request = try ELVDOMRequest(
            url: #require(dataURL(html)),
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            settle: ELVSettlePolicy(signals: ["h1", "jsonld", "og:title"], pollSeconds: 0.15, maxPolls: 4),
            css: [ELVCSSQuery(key: "h1", selector: "h1", attr: nil)]
        )
        let result = try await renderer.render(request)
        #expect(!result.settled)
        #expect(result.cssResults["h1"] == nil)
        #expect(result.html.contains("spinner"))
    }

    @Test
    func `A plain-http request URL is refused by the egress policy before any load`() async throws {
        // Defense in depth: the renderer is public API, so a host
        // calling it directly meets the same egress policy as the pipeline.
        let renderer = ELVWebViewRenderer(watchdogSeconds: 5)
        let request = try ELVDOMRequest(
            url: #require(URL(string: "http://example.com/menu")),
            userAgent: "Mozilla/5.0",
            settle: ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.1, maxPolls: 1),
            css: []
        )
        await #expect(throws: ELVEgressRefusal(reason: "scheme must be https")) {
            _ = try await renderer.render(request)
        }
    }

    @Test
    func `A private-host request URL is refused by the egress policy before any load`() async throws {
        let renderer = ELVWebViewRenderer(watchdogSeconds: 5)
        let request = try ELVDOMRequest(
            url: #require(URL(string: "https://192.168.1.10/admin")),
            userAgent: "Mozilla/5.0",
            settle: ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.1, maxPolls: 1),
            css: []
        )
        await #expect(throws: ELVEgressRefusal(reason: "private address blocked")) {
            _ = try await renderer.render(request)
        }
    }

    @Test
    func `Sequential renders on one renderer reuse the pooled webview cleanly`() async throws {
        // The webview is pooled across renders (one WebContent process pair,
        // not one per render) and parked on about:blank between them — the
        // second render must never see the first render's DOM.
        let renderer = ELVWebViewRenderer(watchdogSeconds: 10)
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
        let settle = ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.2, maxPolls: 15)
        let css = [ELVCSSQuery(key: "h1", selector: "h1", attr: nil)]
        let first = try await renderer.render(ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>First Page</h1></body></html>")),
            userAgent: userAgent, settle: settle, css: css
        ))
        let second = try await renderer.render(ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>Second Page</h1></body></html>")),
            userAgent: userAgent, settle: settle, css: css
        ))
        #expect(first.cssResults["h1"] == "First Page")
        #expect(second.cssResults["h1"] == "Second Page")
        #expect(!second.html.contains("First Page"))
    }

    @Test
    func `Overlapping renders serialize on the pooled webview, each returning its own page`() async throws {
        // A main-actor method is reentrant at every await, so two renders
        // started back to back used to interleave their loads and polls on
        // the one pooled webview; the render queue runs them in order.
        let renderer = ELVWebViewRenderer(watchdogSeconds: 10)
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
        let settle = ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.2, maxPolls: 15)
        let css = [ELVCSSQuery(key: "h1", selector: "h1", attr: nil)]
        let alpha = try ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>Alpha Page</h1></body></html>")),
            userAgent: userAgent, settle: settle, css: css
        )
        let beta = try ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>Beta Page</h1></body></html>")),
            userAgent: userAgent, settle: settle, css: css
        )
        async let first = renderer.render(alpha)
        async let second = renderer.render(beta)
        let (a, b) = try await (first, second)
        #expect(a.cssResults["h1"] == "Alpha Page")
        #expect(b.cssResults["h1"] == "Beta Page")
        #expect(!a.html.contains("Beta Page"))
        #expect(!b.html.contains("Alpha Page"))
    }

    @Test
    func `Main-frame navigation follows the egress policy, with the renderer's own schemes exempt`() throws {
        // The gate the navigation delegate applies per hop: a redirect or
        // script navigation onto plain http, a private host, or a file:
        // origin is cancelled; the about:blank park, data: documents, and
        // public https pass.
        for refused in ["http://example.com/menu", "https://192.168.1.10/admin", "file:///etc/hosts"] {
            let url = try #require(URL(string: refused))
            #expect(!ELVWebViewRenderer.allowsMainFrameNavigation(to: url), "\(refused) must be refused")
        }
        for allowed in ["about:blank", "data:text/html,%3Ch1%3Ehi%3C%2Fh1%3E", "https://www.google.com/maps/place/Jenny+Lake"] {
            let url = try #require(URL(string: allowed))
            #expect(ELVWebViewRenderer.allowsMainFrameNavigation(to: url), "\(allowed) must be allowed")
        }
    }

    @Test
    func `A hand-off to an app URL scheme is refused without failing the render`() throws {
        // KAYA's share page sets location.href to kaya://… on touch-capable
        // UAs. The hop is cancelled (egress refuses every custom scheme),
        // the document stays, and the render extracts it; only a web-scheme
        // hop could have replaced the page, so only that one is fatal.
        for handoff in ["kaya://kaya-app.kayaclimb.com/share/climb?climb_id=2062530", "itms-apps://apps.apple.com/app/id1", "mailto:hi@example.com"] {
            let url = try #require(URL(string: handoff))
            #expect(!ELVWebViewRenderer.allowsMainFrameNavigation(to: url), "\(handoff) must be refused")
            #expect(!ELVWebViewRenderer.mainFrameRefusalIsFatal(for: url), "\(handoff) must not fail the render")
        }
        for fatal in ["http://example.com/menu", "https://192.168.1.10/admin"] {
            let url = try #require(URL(string: fatal))
            #expect(ELVWebViewRenderer.mainFrameRefusalIsFatal(for: url), "\(fatal) replaces the document")
        }
    }

    // MARK: - Canonical-URL capture

    private static let captureUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
    private static let captureRegex = "!3d-?[0-9.]+!4d-?[0-9.]+"

    @Test
    func `Canonical capture polls the live URL to the rewritten place form`() async throws {
        let canonical = try #require(URL(string: "https://www.google.com/maps/place/Jenny+Lake/data=!8m2!3d43.7911!4d-110.7622"))
        let renderer = ELVWebViewRenderer(watchdogSeconds: 10)
        // The seam simulates Google's post-load history.replaceState: a
        // fresh pool at entry (nil), then the rewrite has landed.
        var calls = 0
        renderer.urlProbeOverride = { _ in
            calls += 1
            return calls == 1 ? nil : canonical
        }
        let request = try ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>Maps Shell</h1></body></html>")),
            userAgent: Self.captureUserAgent,
            settle: ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.15, maxPolls: 10),
            css: [ELVCSSQuery(key: "h1", selector: "h1", attr: nil)],
            captureCanonical: ELVCanonicalCapture(untilURLRegex: Self.captureRegex, maxPolls: 10)
        )
        let result = try await renderer.render(request)
        #expect(result.canonicalURL == canonical)
        // A captured canonical is itself a settle signal.
        #expect(result.settled)
    }

    @Test
    func `A capture that never matches runs out its budget and still returns the partial render`() async throws {
        // No probe override: the live URL stays the data: URL, which never
        // matches the predicate — the timeout path. The page itself settles
        // and its render survives for the fall-through extraction.
        let renderer = ELVWebViewRenderer(watchdogSeconds: 10)
        let request = try ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>Maps Shell</h1></body></html>")),
            userAgent: Self.captureUserAgent,
            settle: ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.15, maxPolls: 8),
            css: [ELVCSSQuery(key: "h1", selector: "h1", attr: nil)],
            captureCanonical: ELVCanonicalCapture(untilURLRegex: Self.captureRegex, maxPolls: 4)
        )
        let result = try await renderer.render(request)
        #expect(result.canonicalURL == nil)
        #expect(result.settled)
        #expect(result.cssResults["h1"] == "Maps Shell")
        #expect(result.html.contains("Maps Shell"))
    }

    @Test
    func `A stale canonical from the previous pooled job is never attributed to the next request`() async throws {
        // The TripDays scar: a failed load leaves the pooled webview's
        // URL on the PREVIOUS job's page, and returning it would land link
        // A's canonical URL — and pin — on link B.
        let renderer = ELVWebViewRenderer(watchdogSeconds: 10)
        let stale = try #require(URL(string: "https://www.google.com/maps/place/First+Place/data=!8m2!3d1.5!4d2.5"))
        let settle = ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.15, maxPolls: 8)
        let capture = ELVCanonicalCapture(untilURLRegex: Self.captureRegex, maxPolls: 4)
        let css = [ELVCSSQuery(key: "h1", selector: "h1", attr: nil)]

        // First job: the rewrite lands and is captured.
        var firstCalls = 0
        renderer.urlProbeOverride = { _ in
            firstCalls += 1
            return firstCalls == 1 ? nil : stale
        }
        let first = try await renderer.render(ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>First Page</h1></body></html>")),
            userAgent: Self.captureUserAgent, settle: settle, css: css, captureCanonical: capture
        ))
        #expect(first.canonicalURL == stale)

        // Second job on the pooled webview: the blank park never committed,
        // so every probe still reports the first job's canonical. The entry
        // snapshot must refuse it — partial render, no capture.
        renderer.urlProbeOverride = { _ in stale }
        let second = try await renderer.render(ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>Second Page</h1></body></html>")),
            userAgent: Self.captureUserAgent, settle: settle, css: css, captureCanonical: capture
        ))
        #expect(second.canonicalURL == nil)
        #expect(second.cssResults["h1"] == "Second Page")
        #expect(!second.html.contains("First Page"))
    }

    @Test
    func `An egress-refused capture target is never surfaced`() async throws {
        // A hostile page rewriting its URL to a private host matches the
        // predicate but must not become the canonical (egress contract).
        let internalHost = try #require(URL(string: "https://192.168.1.10/maps/place/x/data=!8m2!3d1.0!4d2.0"))
        let renderer = ELVWebViewRenderer(watchdogSeconds: 10)
        var calls = 0
        renderer.urlProbeOverride = { _ in
            calls += 1
            return calls == 1 ? nil : internalHost
        }
        let request = try ELVDOMRequest(
            url: #require(dataURL("<html><body><h1>Maps Shell</h1></body></html>")),
            userAgent: Self.captureUserAgent,
            settle: ELVSettlePolicy(signals: ["h1"], pollSeconds: 0.15, maxPolls: 6),
            css: [ELVCSSQuery(key: "h1", selector: "h1", attr: nil)],
            captureCanonical: ELVCanonicalCapture(untilURLRegex: Self.captureRegex, maxPolls: 4)
        )
        let result = try await renderer.render(request)
        #expect(result.canonicalURL == nil)
        #expect(result.cssResults["h1"] == "Maps Shell")
    }
}
