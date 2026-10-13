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
    /// A page's plain or rendered text. A pasted share blurb never lands
    /// here (every step replaces the document); it rides
    /// `ELVExtractionContext.paste`.
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
    /// produced it, else the raw `html`, cut to
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
/// captured document, fields already resolved (pack order lets later
/// fields reference earlier ones), and the paste the input came from.
public struct ELVExtractionContext: Sendable {
    public var url: URL?
    public var params: [String: String]
    public var document: ELVDocument
    public var fields: [String: ELVValue]
    /// The share blurb around the input link, when the input was pasted
    /// text; nil for a bare URL. It survives every step and a redirect or
    /// canonical-capture re-entry, unlike the document.
    public var paste: ELVPasteContext?

    public init(url: URL? = nil, params: [String: String] = [:], document: ELVDocument = ELVDocument(), fields: [String: ELVValue] = [:], paste: ELVPasteContext? = nil) {
        self.url = url
        self.params = params
        self.document = document
        self.fields = fields
        self.paste = paste
    }
}

/// What a `paste` selector reads: the blurb around the input link, the
/// label a host's user typed, and the brand of the source now extracting
/// (the pipeline stamps it per source, so a redirected paste derives its
/// share name against the brand it landed on).
public struct ELVPasteContext: Sendable, Equatable {
    /// The text before the link, trimmed; nil when the paste had none.
    public var leading: String?
    /// The paste with the link replaced by a space; nil for a lone URL.
    public var blurb: String?
    /// A label the host's user typed; it outranks every extracted label.
    public var userLabel: String?
    /// The extracting source's brand (its `title`).
    public var brand: String?
    /// Share-blurb name separators (`ELVPastePolicy.labelSeparators`).
    public var separators: [String]

    public init(leading: String? = nil, blurb: String? = nil, userLabel: String? = nil, brand: String? = nil, separators: [String] = ELVPastePolicy.standard.labelSeparators) {
        self.leading = leading
        self.blurb = blurb
        self.userLabel = userLabel
        self.brand = brand
        self.separators = separators
    }

    /// The context for `input`, or nil when it carries nothing beyond its
    /// URL and no label was typed.
    public init?(input: ELVPastedInput, userLabel: String? = nil, separators: [String] = ELVPastePolicy.standard.labelSeparators) {
        let typed = userLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (typed?.isEmpty ?? true) ? nil : typed
        guard input.leadingText != nil || input.blurb != nil || label != nil else { return nil }
        self.init(leading: input.leadingText, blurb: input.blurb, userLabel: label, separators: separators)
    }

    /// The named paste value a `{"paste": key}` selector reads: `label` (the
    /// "<name> on <Brand>" share name), `title` (the whole lead-in, social
    /// posts), `leading` (the raw lead-in), `text` (the blurb).
    func value(_ key: String) -> String? {
        switch key {
        case "label":
            guard let leading, let brand else { return nil }
            return ELVShareLabel.suffixed(leading: leading, brand: brand, separators: separators)
        case "title":
            return leading.flatMap { ELVShareLabel.whole(leading: $0) }
        case "leading":
            return leading
        case "text":
            return blurb
        default:
            return nil
        }
    }

    /// The keys `value(_:)` answers; the validator names any other.
    static let keys: Set<String> = ["label", "title", "leading", "text"]
}
