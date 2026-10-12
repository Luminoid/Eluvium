import Foundation

/// Where a candidate reads its raw value from. Encoded in packs as a
/// single-key object: `{"css": "h1"}`, `{"meta": "og:title"}`,
/// `{"jsonld": "Product.name"}`. An unrecognized selector decodes to
/// `.unsupported` and invalidates only its candidate, never the field.
public enum ELVSelector: Sendable, Equatable {
    /// A literal value.
    case const(String)
    /// A named path param captured at recognition (`url.param.<name>`).
    case urlParam(String)
    /// A query item on the input URL.
    case urlQuery(String)
    /// A regex over the full URL string; first capture group wins, else the
    /// whole match.
    case urlRegex(String)
    /// A meta tag by `property`/`name` (`og:title`).
    case meta(String)
    /// A JSON-LD selector: `Type.key.path` — the first path component
    /// filters nodes by `@type` (case-insensitive, `*` = any node), the
    /// rest is a keypath into the winning node.
    case jsonld(String)
    /// A JSONPath over the document's JSON body (`$.items[0].name`).
    case json(String)
    /// A CSS selector, evaluated by the DOM engine; `attr` picks text,
    /// `@href`, `@src`, `@content`, or an attribute name.
    case css(selector: String, attr: String?)
    /// A regex over the document's plain text; first capture group wins.
    /// `after` (schemaMinor 4) is the same literal anchor `regexRows` takes:
    /// the capped window starts at its first occurrence instead of the top
    /// of the document, so a value that sits deep in a large page (a
    /// server-rendered data blob past the input cap) is reachable; an
    /// absent anchor is a miss.
    case textRegex(String, after: String? = nil)
    /// A regex over the document's raw HTML/text driving a COLLECTION: one
    /// row per match, capture groups keyed `g1`…`gN` plus a 1-based `rank`
    /// from document order (rankings rendered as plain markup). Field
    /// candidates never produce from it. `after` (pack key beside
    /// `regexRows`) is a literal anchor: the scan starts at its first
    /// occurrence, so a data blob that sits deep in a large page is reached
    /// before the input cap applies. The anchor search is a plain substring
    /// find (linear, no backtracking); an absent anchor yields no rows.
    case regexRows(String, after: String? = nil)
    /// A CSV column by header name (archive mode).
    case column(String)
    /// An earlier field's resolved value (`$field.<name>` in pack syntax).
    case field(String)
    /// A registered native op, `name@version`, with named inputs.
    case native(op: String, input: [String: String])
    /// A selector this binary does not understand. Evaluates to nothing.
    case unsupported(key: String)
}

extension ELVSelector: Decodable {
    /// Decoding never throws: a malformed selector — not an object,
    /// zero or several selector keys, a non-string payload — degrades to
    /// `.unsupported` so it invalidates only its candidate, and the pack
    /// validator reports it. Only an unrecognized *shape of container* the
    /// decoder cannot even open would surface an error, and the guards
    /// below absorb that too.
    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: ELVDynamicKey.self) else {
            self = .unsupported(key: "(not an object)")
            return
        }
        let attr = (try? container.decodeIfPresent(String.self, forKey: .init("attr"))) ?? nil
        let after = (try? container.decodeIfPresent(String.self, forKey: .init("after"))) ?? nil
        // The keys that ride beside a selector key: `attr` for css, `input`
        // for native, `after` for textRegex and regexRows. A candidate's
        // `select` belongs on the candidate, not inside `from`; there it
        // makes the object two-keyed and unsupported.
        let auxiliaryKeys: Set = ["attr", "input", "after"]
        let selectorKeys = container.allKeys.map(\.stringValue).filter { !auxiliaryKeys.contains($0) }
        guard selectorKeys.count == 1, let key = selectorKeys.first else {
            self = .unsupported(key: selectorKeys.isEmpty ? "(empty)" : selectorKeys.sorted().joined(separator: "+"))
            return
        }

        func value() -> String? {
            try? container.decode(String.self, forKey: .init(key))
        }
        switch key {
        case "const": self = value().map { .const($0) } ?? .unsupported(key: key)
        case "urlParam": self = value().map { .urlParam($0) } ?? .unsupported(key: key)
        case "urlQuery": self = value().map { .urlQuery($0) } ?? .unsupported(key: key)
        case "urlRegex": self = value().map { .urlRegex($0) } ?? .unsupported(key: key)
        case "meta": self = value().map { .meta($0) } ?? .unsupported(key: key)
        case "jsonld": self = value().map { .jsonld($0) } ?? .unsupported(key: key)
        case "json": self = value().map { .json($0) } ?? .unsupported(key: key)
        case "css": self = value().map { .css(selector: $0, attr: attr) } ?? .unsupported(key: key)
        case "textRegex": self = value().map { .textRegex($0, after: after) } ?? .unsupported(key: key)
        case "regexRows": self = value().map { .regexRows($0, after: after) } ?? .unsupported(key: key)
        case "column": self = value().map { .column($0) } ?? .unsupported(key: key)
        case "field": self = value().map { .field($0) } ?? .unsupported(key: key)
        case "native":
            let input = ((try? container.decodeIfPresent([String: String].self, forKey: .init("input"))) ?? nil) ?? [:]
            self = value().map { .native(op: $0, input: input) } ?? .unsupported(key: key)
        default:
            self = .unsupported(key: key)
        }
    }

    /// A short human tag for provenance (`meta:og:title`, `css:h1`).
    public var provenanceTag: String {
        switch self {
        case let .const(value): "const:\(value)"
        case let .urlParam(name): "urlParam:\(name)"
        case let .urlQuery(name): "urlQuery:\(name)"
        case .urlRegex: "urlRegex"
        case let .meta(name): "meta:\(name)"
        case let .jsonld(path): "jsonld:\(path)"
        case let .json(path): "json:\(path)"
        case let .css(selector, _): "css:\(selector)"
        case .textRegex: "textRegex"
        case .regexRows: "regexRows"
        case let .column(name): "column:\(name)"
        case let .field(name): "field:\(name)"
        case let .native(op, _): "native:\(op)"
        case let .unsupported(key): "unsupported:\(key)"
        }
    }
}
