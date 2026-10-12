import Foundation

/// A list/enumeration spec: a source with a `list` produces many
/// records from a paginated seed. `items` selects the item nodes on each
/// page and `next` locates the following page; every walk is resumable,
/// bounded (`maxPages` plus the enumerator's own ceilings), and reports
/// what it skipped instead of truncating silently. Unknown keys are ignored
/// , so a newer pack's list vocabulary degrades to what this binary
/// executes rather than failing the source.
public struct ELVListSpec: Sendable, Decodable, Equatable {
    /// The range an offset cursor's `pageSize` is clamped into. Pack
    /// numerics clamp in `init`: the enumerator adds `pageSize` to a running
    /// offset every page, so an unbounded value could overflow that
    /// arithmetic, and a non-positive one could never advance a walk.
    public static let pageSizeRange = 1 ... 1000

    /// The seed URL (may carry `{param.x}` templates). The first page.
    public var seed: String
    /// Selects the item nodes on each page.
    public var items: ELVSelector
    /// The next-page cursor. Absent means single-page.
    public var next: ELVCursor?
    /// Total-count selector, for progress reporting.
    public var total: ELVSelector?
    /// Hard page cap (plus the enumerator's ceiling). Default 100.
    public var maxPages: Int
    /// What to do when a page errors.
    public var onPageError: ELVPageErrorPolicy
    /// Decode-time clamps worth telling the author about (an offset page
    /// size outside `pageSizeRange`), surfaced by the validator. Not wire
    /// data.
    public var decodeIssues: [String]

    public init(
        seed: String,
        items: ELVSelector,
        next: ELVCursor? = nil,
        total: ELVSelector? = nil,
        maxPages: Int = 100,
        onPageError: ELVPageErrorPolicy = .stop,
        decodeIssues: [String] = []
    ) {
        self.seed = seed
        self.items = items
        self.next = next.map(Self.clamped)
        self.total = total
        self.maxPages = maxPages
        self.onPageError = onPageError
        self.decodeIssues = decodeIssues
    }

    private enum CodingKeys: String, CodingKey {
        case seed, items, next, total, maxPages, onPageError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let next = try container.decodeIfPresent(ELVCursor.self, forKey: .next)
        var issues: [String] = []
        if case let .offset(_, pageSize)? = next, !Self.pageSizeRange.contains(pageSize) {
            issues.append("offset pageSize \(pageSize) is outside \(Self.pageSizeRange.lowerBound)...\(Self.pageSizeRange.upperBound) and is clamped")
        }
        try self.init(
            seed: container.decode(String.self, forKey: .seed),
            items: container.decode(ELVSelector.self, forKey: .items),
            next: next,
            total: container.decodeIfPresent(ELVSelector.self, forKey: .total),
            maxPages: container.decodeIfPresent(Int.self, forKey: .maxPages) ?? 100,
            onPageError: container.decodeIfPresent(ELVPageErrorPolicy.self, forKey: .onPageError) ?? .stop,
            decodeIssues: issues
        )
    }

    private static func clamped(_ cursor: ELVCursor) -> ELVCursor {
        guard case let .offset(param, pageSize) = cursor else { return cursor }
        return .offset(param: param, pageSize: min(max(pageSize, pageSizeRange.lowerBound), pageSizeRange.upperBound))
    }
}

/// How the next page is located.
public enum ELVCursor: Sendable, Decodable, Equatable {
    /// A JSONPath to a cursor token appended as `&{param}=<token>` — the
    /// param name and the URL template come from the source's list seed.
    case cursorToken(path: String, param: String)
    /// A selector yielding the full next-page URL.
    case nextURL(ELVSelector)
    /// Offset pagination: `param` advances by `pageSize` each page.
    case offset(param: String, pageSize: Int)

    private enum CodingKeys: String, CodingKey {
        case kind, path, param, pageSize
    }

    /// Two spellings. A bare selector object (`{"json": "$.next"}`) is a
    /// `nextURL` cursor; a `kind`-tagged object names a typed cursor
    /// (`cursorToken`, `offset`) with its arguments. The tagged forms are
    /// probed first because selectors decode leniently: the bare form would
    /// otherwise swallow any tagged object as an unsupported selector. An
    /// unknown `kind`, or a typed cursor missing an argument, degrades to
    /// single-page enumeration (an unsupported `nextURL` selector the
    /// validator names) rather than failing the source.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .kind) {
        case "cursorToken":
            guard let path = try container.decodeIfPresent(String.self, forKey: .path),
                  let param = try container.decodeIfPresent(String.self, forKey: .param) else {
                self = .nextURL(.unsupported(key: "cursorToken:(missing path or param)"))
                return
            }
            self = .cursorToken(path: path, param: param)
        case "offset":
            guard let param = try container.decodeIfPresent(String.self, forKey: .param),
                  let pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) else {
                self = .nextURL(.unsupported(key: "offset:(missing param or pageSize)"))
                return
            }
            self = .offset(param: param, pageSize: pageSize)
        case let .some(unknown):
            self = .nextURL(.unsupported(key: "cursorKind:\(unknown)"))
        case nil:
            self = try .nextURL(ELVSelector(from: decoder))
        }
    }
}

/// What happens when one page of an enumeration repeatedly errors.
public enum ELVPageErrorPolicy: String, Sendable, Decodable {
    /// Stop the walk at the failed page (what was gathered stands).
    case stop
    /// Skip the failed page and continue (offset walks tolerate a gap).
    case skip

    /// Decodes leniently like the sibling pack enums: a policy this
    /// binary does not know becomes `.stop`, the conservative choice,
    /// instead of failing the whole source.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .stop
    }
}
