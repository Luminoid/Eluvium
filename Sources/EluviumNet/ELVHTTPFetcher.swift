import EluviumCore
import Foundation

/// The `http` / `json` transport: HTTPS-only with an SSRF guard, personas,
/// a streaming byte cap, a wall-clock deadline, and typed failures.
/// `URLSession` follows redirects under `ELVRedirectGuard`; the final URL
/// re-enters recognition at the pipeline layer. A struct, not an actor: the
/// only state is the session, which is itself thread-safe, and an actor hop
/// per fetch would serialize every source's transport behind one queue.
public struct ELVHTTPFetcher: ELVFetching, Sendable {
    private let session: URLSession
    /// The host's ceiling on any one request's wall-clock budget.
    private let timeoutCap: TimeInterval?

    public init() {
        self.init(protocolClasses: nil)
    }

    /// A fetcher whose requests never outlast `timeoutCap` seconds, whatever
    /// a source's budget allows: a paste flow showing a spinner wants a
    /// shorter wait than a background import does. Clamped to 1 ...
    /// `ELVFetchBudget.timeoutCeiling`.
    public init(timeoutCap: TimeInterval) {
        self.init(protocolClasses: nil, timeoutCap: timeoutCap)
    }

    /// Internal for tests: a stub `URLProtocol` stands in for the network so
    /// the deadline and cap paths run offline. The session is ephemeral with
    /// cookies off (no session sharing with anything the user is
    /// logged into), and its resource timeout is the budget ceiling so a
    /// transfer outlasting every per-request bound still ends.
    init(protocolClasses: [AnyClass]?, timeoutCap: TimeInterval? = nil) {
        self.timeoutCap = timeoutCap.map { $0.isFinite ? min(max($0, 1), ELVFetchBudget.timeoutCeiling) : ELVFetchBudget.timeoutCeiling }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = ELVFetchBudget.timeoutCeiling
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: configuration)
    }

    /// Internal for tests: the session-level wall-clock ceiling.
    var resourceTimeout: TimeInterval { session.configuration.timeoutIntervalForResource }

    public func fetch(
        _ url: URL,
        persona: ELVUAPersona,
        referer: URL?,
        accept: String?,
        budget requested: ELVFetchBudget
    ) async throws -> ELVFetchResponse {
        var budget = requested
        if let timeoutCap { budget.timeout = min(budget.timeout, timeoutCap) }
        let deadline = ContinuousClock.now + .seconds(budget.timeout)
        var request = try Self.request(for: url, budget: budget)
        request.setValue(persona.headerValue, forHTTPHeaderField: "User-Agent")
        request.setValue(accept ?? "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        let (bytes, http, finalURL) = try await openStream(request)
        try Self.checkStatus(http, bytes: bytes)
        return try await readResponse(bytes, http: http, finalURL: finalURL, budget: budget, deadline: deadline)
    }

    /// Conditional GET for pack refresh: adds `If-None-Match`, returns
    /// `notModified` on a 304 (which `fetch` would throw on), and reads the
    /// `ETag`. Same egress checkpoints, byte cap, and deadline as `fetch`.
    public func fetchConditional(
        _ url: URL,
        ifNoneMatch: String?,
        budget: ELVFetchBudget
    ) async throws -> ELVConditionalFetchResult {
        let deadline = ContinuousClock.now + .seconds(budget.timeout)
        var request = try Self.request(for: url, budget: budget)
        request.setValue(ELVUAPersona.mobileSafari.headerValue, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }

        let (bytes, http, finalURL) = try await openStream(request)
        let etag = http.value(forHTTPHeaderField: "ETag")
        if http.statusCode == 304 {
            bytes.task.cancel()
            return ELVConditionalFetchResult(response: nil, etag: etag ?? ifNoneMatch)
        }
        try Self.checkStatus(http, bytes: bytes)
        let fetched = try await readResponse(bytes, http: http, finalURL: finalURL, budget: budget, deadline: deadline)
        return ELVConditionalFetchResult(response: fetched, etag: etag)
    }

    // MARK: - Shared legs

    /// The egress-vetted request skeleton. `timeoutInterval` is URLSession's
    /// idle bound; the wall-clock bound is the caller's deadline.
    private static func request(for url: URL, budget: ELVFetchBudget) throws -> URLRequest {
        if let reason = ELVEgressPolicy.violation(url) {
            throw ELVFetchFailure.egressBlocked(reason)
        }
        return URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: budget.timeout)
    }

    /// Opens the response stream: the guard caps hops and re-runs the egress
    /// policy per hop, and the landing itself is re-checked (belt and braces
    /// with the per-hop check). Status handling stays with the caller, since
    /// the conditional path reads a 304 as a result, not a failure.
    private func openStream(_ request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse, finalURL: URL) {
        let redirectGuard = ELVRedirectGuard()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        } catch let error as URLError {
            throw Self.fetchFailure(from: error)
        }

        if let reason = redirectGuard.refusalReason {
            bytes.task.cancel()
            throw ELVFetchFailure.egressBlocked(reason)
        }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            bytes.task.cancel()
            throw ELVFetchFailure.formatDrift("non-HTTP response")
        }
        if let reason = ELVEgressPolicy.violation(finalURL) {
            bytes.task.cancel()
            throw ELVFetchFailure.egressBlocked(reason)
        }
        return (bytes, http, finalURL)
    }

    /// Maps a non-2xx status to its typed failure before any body is read,
    /// cancelling the stream so the body never downloads. One 2xx is a wall
    /// too: AWS WAF's challenge answers `202` with an empty body and
    /// `x-amzn-waf-action: challenge` (Goodreads under any burst), which
    /// would otherwise read as a page with nothing on it.
    private static func checkStatus(_ http: HTTPURLResponse, bytes: URLSession.AsyncBytes) throws {
        switch http.statusCode {
        case 200 ..< 300:
            if http.value(forHTTPHeaderField: "x-amzn-waf-action")?.lowercased() == "challenge" {
                bytes.task.cancel()
                throw ELVFetchFailure.blocked(status: http.statusCode)
            }
            return
        case 401:
            bytes.task.cancel()
            throw ELVFetchFailure.unauthenticated
        case 403, 429, 503:
            bytes.task.cancel()
            throw ELVFetchFailure.blocked(status: http.statusCode)
        default:
            bytes.task.cancel()
            throw ELVFetchFailure.httpError(status: http.statusCode)
        }
    }

    /// The staging chunk `readResponse` fills before each append into the
    /// body: a multiple of the 4 KiB deadline granularity.
    private static let readChunkBytes = 32 * 1024

    /// Streams the body against the byte cap and the deadline, so an
    /// oversized response never sits in RAM and a trickling one never
    /// outlives its budget. The deadline is polled every 4 KiB rather than
    /// per byte: the idle timeout catches any gap longer than the budget,
    /// and the session's resource timeout ends whatever slips between.
    ///
    /// `AsyncBytes` yields one byte at a time, so bytes stage in a fixed
    /// local chunk that moves into the body `readChunkBytes` at a time: a
    /// per-byte `Data.append` re-entered `Data`'s storage bookkeeping for
    /// every byte of a body up to the 10 MB ceiling. The cap and deadline
    /// count staged bytes too, so both trip at exactly the byte they did
    /// before, and a truncated body holds exactly `maxBytes`.
    private func readResponse(_ bytes: URLSession.AsyncBytes, http: HTTPURLResponse, finalURL: URL, budget: ELVFetchBudget, deadline: ContinuousClock.Instant) async throws -> ELVFetchResponse {
        let cap = max(budget.maxBytes, 0)
        var data = Data()
        data.reserveCapacity(min(Int(max(http.expectedContentLength, 0)), cap))
        var chunk = [UInt8](repeating: 0, count: Self.readChunkBytes)
        var staged = 0
        var received = 0
        var truncated = false
        do {
            for try await byte in bytes {
                if received == cap {
                    truncated = true
                    bytes.task.cancel()
                    break
                }
                if received & 0xFFF == 0, ContinuousClock.now > deadline {
                    bytes.task.cancel()
                    throw ELVFetchFailure.timeout
                }
                chunk[staged] = byte
                staged += 1
                received += 1
                if staged == chunk.count {
                    data.append(contentsOf: chunk)
                    staged = 0
                }
            }
        } catch let error as URLError {
            throw Self.fetchFailure(from: error)
        }
        data.append(contentsOf: chunk[..<staged])

        // Lossy UTF-8: the cap can land mid-character; a failable
        // decode threw whole bodies away and a Latin-1 fallback mojibakes.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        return ELVFetchResponse(finalURL: finalURL, status: http.statusCode, data: data, bodyText: text, truncated: truncated)
    }

    /// Internal for tests and the short-link chase. A `.cancelled` URLError
    /// is the enclosing task's cancellation surfacing through URLSession,
    /// rethrown as `CancellationError` so the pipeline's cancellation marker
    /// reports a user action, not a transport failure.
    static func fetchFailure(from error: URLError) -> any Error {
        switch error.code {
        case .cancelled: CancellationError()
        case .timedOut: ELVFetchFailure.timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: ELVFetchFailure.offline
        default: ELVFetchFailure.transport(code: error.code.rawValue)
        }
    }
}
