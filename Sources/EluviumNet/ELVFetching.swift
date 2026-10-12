import EluviumCore
import Foundation

/// Typed failure states so hosts can message them distinctly.
public enum ELVFetchFailure: Error, Equatable, Sendable {
    /// Non-2xx that reads as a bot wall or rate limit (403/429/503). A
    /// non-2xx body is never parsed as content.
    case blocked(status: Int)
    /// Any other non-2xx status. Always a status the server actually sent:
    /// no sentinel value stands in for "something else went wrong" (those
    /// are `transport` and `formatDrift`).
    case httpError(status: Int)
    /// The transport failed before any HTTP status existed (DNS, TLS,
    /// connection reset, …); `code` is the `URLError.Code` raw value, so
    /// logs say which.
    case transport(code: Int)
    /// The service wants a login (401, or a login redirect the source
    /// declares).
    case unauthenticated
    case timeout
    case offline
    /// The response exists but its expected shape is gone (an empty `{}`
    /// where JSON was promised) — the health-run signal, never silence.
    case formatDrift(String)
    case invalidURL
    /// Egress policy refused the request (non-HTTPS, private host, …).
    case egressBlocked(String)
}

extension ELVFetchFailure {
    /// The typed failure for anything a transport, renderer, op, or page
    /// decode threw: the one fold the pipeline and the enumerator share. A
    /// typed failure passes through, an egress refusal becomes
    /// `egressBlocked`, and anything else folds to its `ELVLog.describe`
    /// summary (type and case, or domain and code), so every reason stays
    /// free of user data and can be logged publicly; the full error goes to
    /// a debug line under `category`. Cancellation is not folded here: each
    /// caller intercepts `CancellationError` first and reports it its own
    /// way.
    static func folding(_ error: any Error, category: ELVLog.Category = .fetch) -> Self {
        switch error {
        case let failure as Self:
            return failure
        case let refusal as ELVEgressRefusal:
            return .egressBlocked(refusal.reason)
        default:
            ELVLog.debug(category, "Folding an unexpected error into formatDrift", error: error)
            return .formatDrift(ELVLog.describe(error).summary)
        }
    }
}

/// One fetched page/response, plus the redirect-resolved final URL that
/// re-enters recognition.
public struct ELVFetchResponse: Sendable {
    public var finalURL: URL
    public var status: Int
    public var data: Data
    /// Lossy-UTF-8 body text: the byte cap can land mid-character.
    public var bodyText: String
    /// True when the byte cap truncated the body.
    public var truncated: Bool

    /// Public so a host can conform its own transport to `ELVFetching`
    /// (a cache layer, a recording proxy) without living in this module.
    public init(finalURL: URL, status: Int, data: Data, bodyText: String, truncated: Bool) {
        self.finalURL = finalURL
        self.status = status
        self.data = data
        self.bodyText = bodyText
        self.truncated = truncated
    }
}

/// The outcome of a conditional (ETag) GET used for pack refresh: either a
/// fresh response with its ETag, or `notModified` (304) so the caller keeps its
/// cached pack. Kept separate from `ELVFetchResponse` so the hot extraction
/// path never grows a conditional/ETag branch.
public struct ELVConditionalFetchResult: Sendable {
    /// `nil` when the server answered 304 (not modified).
    public var response: ELVFetchResponse?
    /// The response's `ETag`, to persist for the next conditional GET.
    public var etag: String?

    public var notModified: Bool { response == nil }

    public init(response: ELVFetchResponse?, etag: String?) {
        self.response = response
        self.etag = etag
    }
}

/// Per-source transport budget, clamped by the binary. `timeout` is a
/// wall-clock bound on the whole request (connect, headers, body), not an
/// idle interval: a server trickling one byte per idle window would
/// otherwise hold a fetch, and the pipeline behind it, open indefinitely.
public struct ELVFetchBudget: Sendable {
    /// The binary's hard body ceiling; a pack's `maxBytes` clamps to it.
    public static let maxBytesCeiling = 10_000_000
    /// The binary's hard wall-clock ceiling. Also the session's resource
    /// timeout, so a transfer no budget bounds still ends here.
    public static let timeoutCeiling: TimeInterval = 60

    public var maxBytes: Int
    public var timeout: TimeInterval

    public init(maxBytes: Int = 3_000_000, timeout: TimeInterval = 15) {
        self.maxBytes = min(maxBytes, Self.maxBytesCeiling)
        self.timeout = min(timeout, Self.timeoutCeiling)
    }

    public static let standard = Self()
}

/// The transport seam. The live `ELVHTTPFetcher` hits the network; tests
/// inject a fixture-replaying stub so the whole pipeline runs offline.
public protocol ELVFetching: Sendable {
    func fetch(_ url: URL, persona: ELVUAPersona, referer: URL?, accept: String?, budget: ELVFetchBudget) async throws -> ELVFetchResponse

    /// Conditional GET for pack refresh: sends `If-None-Match` and surfaces the
    /// `ETag` and a 304. The default ignores conditionals and wraps `fetch`, so
    /// existing fetchers and test stubs need no change; the live fetcher
    /// overrides it.
    func fetchConditional(_ url: URL, ifNoneMatch: String?, budget: ELVFetchBudget) async throws -> ELVConditionalFetchResult
}

public extension ELVFetching {
    func fetch(_ url: URL, persona: ELVUAPersona = .mobileSafari, referer: URL? = nil, accept: String? = nil, budget: ELVFetchBudget = .standard) async throws -> ELVFetchResponse {
        try await fetch(url, persona: persona, referer: referer, accept: accept, budget: budget)
    }

    func fetchConditional(_ url: URL, ifNoneMatch _: String? = nil, budget: ELVFetchBudget = .standard) async throws -> ELVConditionalFetchResult {
        let response = try await fetch(url, budget: budget)
        return ELVConditionalFetchResult(response: response, etag: nil)
    }
}
