import Foundation
import Synchronization

/// The captured input stages ③–⑤ run over. Pure data: building one from a
/// fixture is what makes the whole pipeline testable without a network.
public struct ELVDocument: Sendable, Equatable {
    /// `property`/`name` → content for meta tags.
    public var metas: [String: String]
    /// The `<title>` text.
    public var title: String?
    /// Flattened JSON-LD nodes in document order.
    public var jsonLDNodes: [ELVRawJSON]
    /// The JSON body (`json` fetch mode, feed envelopes, API responses).
    public var json: ELVRawJSON?
    /// Plain text (a pasted share blurb, a page's visible text).
    public var text: String? {
        didSet { regexInput = ELVDocumentRegexInput() }
    }

    /// CSS selector → extracted value, produced by the DOM engine. Core
    /// evaluates `css` candidates against this map; without a DOM pass the
    /// candidates simply don't produce.
    public var cssResults: [String: String]
    /// One CSV row, header-keyed (archive mode).
    public var row: [String: String]
    /// The raw page HTML the scan ran over, retained for the native ops that
    /// do format-specific island scans (e.g. the Flighty `{"flight":…}`
    /// blob) — the scanned fields can't carry an arbitrary script body.
    public var html: String? {
        didSet { regexInput = ELVDocumentRegexInput() }
    }

    /// The page's `<link>` tags with a `rel` and an `href`, in document
    /// order, from the same scan that fills `metas` (`init(html:)`): feed
    /// autodiscovery reads the `rel="alternate"` ones instead of scanning
    /// the HTML a second time.
    public var links: [ELVHTMLLink]

    /// The bounded `textRegex` input, built on first use and shared by every
    /// copy of this document (one extraction copies it into each context).
    private var regexInput = ELVDocumentRegexInput()

    public init(
        metas: [String: String] = [:],
        title: String? = nil,
        jsonLDNodes: [ELVRawJSON] = [],
        json: ELVRawJSON? = nil,
        text: String? = nil,
        cssResults: [String: String] = [:],
        row: [String: String] = [:],
        html: String? = nil,
        links: [ELVHTMLLink] = []
    ) {
        self.metas = metas
        self.title = title
        self.jsonLDNodes = jsonLDNodes
        self.json = json
        self.text = text
        self.cssResults = cssResults
        self.row = row
        self.html = html
        self.links = links
    }

    /// Builds a document by scanning raw HTML (http fetch mode).
    public init(html: String) {
        let scanned = ELVHTMLScanner.scan(html)
        self.init(metas: scanned.metas, title: scanned.title, jsonLDNodes: scanned.jsonLDNodes, text: nil, html: html, links: scanned.links)
    }

    /// What `textRegex` candidates scan: the rendered `text` when a DOM pass
    /// (or a pasted blurb) produced it, else the raw `html`, cut to
    /// `ELVRegexCache.inputCap`. Built once per document, so the candidates
    /// of one extraction share one prefix copy and one `NSString` bridge
    /// instead of re-cutting a 256K-character prefix each.
    var regexText: NSString? {
        regexInput.value { (text ?? html).map { ELVRegexCache.boundedInput($0) } }
    }
}

/// The lazily built `ELVDocument.regexText`. A cache, not document state:
/// two documents with equal fields are equal whatever either has cached,
/// and assigning `text` or `html` installs a fresh box. `NSString` is
/// immutable, so handing the cached instance out of the lock is sound.
private final class ELVDocumentRegexInput: Sendable, Equatable {
    private let storage = Mutex<NSString??>(nil)

    func value(_ build: () -> String?) -> NSString? {
        storage.withLock { state in
            if let cached = state { return cached }
            let built = build().map { $0 as NSString }
            state = .some(built)
            return built
        }
    }

    static func == (_: ELVDocumentRegexInput, _: ELVDocumentRegexInput) -> Bool {
        true
    }
}

/// Everything a candidate can read: the input URL, recognition params, the
/// captured document, and fields already resolved (pack order lets later
/// fields reference earlier ones).
public struct ELVExtractionContext: Sendable {
    public var url: URL?
    public var params: [String: String]
    public var document: ELVDocument
    public var fields: [String: ELVValue]

    public init(url: URL? = nil, params: [String: String] = [:], document: ELVDocument = ELVDocument(), fields: [String: ELVValue] = [:]) {
        self.url = url
        self.params = params
        self.document = document
        self.fields = fields
    }
}
