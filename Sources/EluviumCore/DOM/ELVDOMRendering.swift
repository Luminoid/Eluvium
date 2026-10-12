import Foundation

// The DOM-render seam types. The pack-schema halves (ELVSettlePolicy,
// ELVCanonicalCapture) live in Pack/ELVDOMPolicies.swift with their decode
// siblings; this file is the cross-target rendering contract only.

/// One CSS query the DOM engine must resolve: a stable key plus the selector
/// and attribute the compiled JS reads. Keys let the caller map results back
/// to the field candidates that requested them.
public struct ELVCSSQuery: Sendable, Equatable {
    /// The `cssResults` key: `selector` or `selector@attr` (matching
    /// `ELVSelectorEngine`'s lookup).
    public var key: String
    public var selector: String
    /// text / `@href` / `@src` / `@content` / an attribute name.
    public var attr: String?

    public init(key: String, selector: String, attr: String?) {
        self.key = key
        self.selector = selector
        self.attr = attr
    }
}

/// What the pipeline hands the DOM engine.
public struct ELVDOMRequest: Sendable {
    public var url: URL
    /// A binary-owned persona identifier (`desktopSafari` etc.); the renderer
    /// maps it to a UA string.
    public var userAgent: String
    public var settle: ELVSettlePolicy
    public var css: [ELVCSSQuery]
    public var captureCanonical: ELVCanonicalCapture?

    public init(url: URL, userAgent: String, settle: ELVSettlePolicy, css: [ELVCSSQuery], captureCanonical: ELVCanonicalCapture? = nil) {
        self.url = url
        self.userAgent = userAgent
        self.settle = settle
        self.css = css
        self.captureCanonical = captureCanonical
    }
}

/// What the DOM engine returns: the settled HTML (for meta / JSON-LD
/// scanning), the resolved CSS values, and the final/canonical URL that
/// re-enters recognition. `settled` is false when the poll budget ran
/// out — the partial render is still returned (the load-watchdog rule),
/// and `loadError` / `extractionError` say why it may hold nothing.
public struct ELVDOMResult: Sendable {
    public var finalURL: URL
    public var html: String
    public var cssResults: [String: String]
    public var settled: Bool
    /// The canonical URL captured via `captureCanonical`, when one matched.
    /// Renderer contract: never the pooled webview's pre-load (stale)
    /// URL, never `about:blank`, and always egress-clean — a violating
    /// rewrite is dropped, not surfaced. The pipeline re-checks egress
    /// before re-entering recognition (the renderer is an injected seam).
    public var canonicalURL: URL?
    /// Why the page's own navigation failed before committing a document
    /// (domain and code, `ELVLog.describe`), nil when it committed. The
    /// render still returns whatever the webview holds; this is the reason
    /// it holds nothing useful.
    public var loadError: String?
    /// Why the final extraction evaluate produced nothing (a timeout, a
    /// WebKit error), nil when it ran. `html` and `cssResults` are then
    /// empty for that reason, not because the page was.
    public var extractionError: String?

    public init(
        finalURL: URL,
        html: String,
        cssResults: [String: String],
        settled: Bool,
        canonicalURL: URL? = nil,
        loadError: String? = nil,
        extractionError: String? = nil
    ) {
        self.finalURL = finalURL
        self.html = html
        self.cssResults = cssResults
        self.settled = settled
        self.canonicalURL = canonicalURL
        self.loadError = loadError
        self.extractionError = extractionError
    }
}

/// The DOM-render seam. Declared in Core so `EluviumNet`'s pipeline can
/// accept a renderer without importing WebKit; `EluviumDOM` provides the
/// `WKWebView` implementation and the host app injects it. A binary with no
/// renderer simply skips `dom` steps (capability gating).
public protocol ELVDOMRendering: Sendable {
    func render(_ request: ELVDOMRequest) async throws -> ELVDOMResult
}

public extension ELVSource {
    /// Every distinct CSS query the candidates a dom `step` runs request,
    /// across fields and collection items — what the DOM engine must
    /// resolve. A step with scoped `fields` or `collections` resolves
    /// css candidates from its own surface; otherwise the source ladder's.
    /// Source collections are always included, since they assemble against
    /// the final context. The key matches `ELVSelectorEngine`'s
    /// `cssResults` lookup (`selector` or `selector@attr`).
    func cssQueries(for step: ELVFetchStep) -> [ELVCSSQuery] {
        cssQueries(fieldSpecs: step.fields ?? fields, collectionSpecs: collections + (step.collections ?? []))
    }

    private func cssQueries(fieldSpecs: [ELVFieldSpec], collectionSpecs: [ELVCollectionSpec]) -> [ELVCSSQuery] {
        var seen = Set<String>()
        var queries: [ELVCSSQuery] = []
        func collect(_ specs: [ELVFieldSpec]) {
            for spec in specs {
                for candidate in spec.candidates {
                    guard case let .css(selector, attr) = candidate.from else { continue }
                    let key = attr.map { "\(selector)@\($0)" } ?? selector
                    if seen.insert(key).inserted {
                        queries.append(ELVCSSQuery(key: key, selector: selector, attr: attr))
                    }
                }
            }
        }
        collect(fieldSpecs)
        for collection in collectionSpecs {
            collect(collection.item)
        }
        return queries
    }
}
