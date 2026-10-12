import EluviumCore
import Foundation

/// Short-link expansion (`shortlink.expand`): maps.app.goo.gl, yelp.to,
/// abnb.me and friends carry no place data in the URL — only the redirect
/// chain knows the target. The chase is HEAD-first (no body download); some
/// redirectors reject HEAD, so a GET cancelled at the headers is the
/// fallback. The egress policy vets the entry URL before any request leaves
/// (a redirector source is the one recognized source whose op fetches
/// before the pipeline's own transport does), the redirect guard vets every
/// hop, the landing is vetted again after the EU consent interstitial is
/// unwrapped, and the GET leg's transport errors surface typed rather than
/// collapsing into "went nowhere".
public struct ELVShortLinkExpander: Sendable {
    public static let defaultMaxHops = 5

    private let maxHops: Int
    private let chase: @Sendable (URL, Int) async throws -> URL?

    /// `chase` follows redirects and returns the final URL (injectable for
    /// tests); the default is the URLSession HEAD-then-GET implementation.
    public init(maxHops: Int = Self.defaultMaxHops, chase: (@Sendable (URL, Int) async throws -> URL?)? = nil) {
        self.maxHops = maxHops
        self.chase = chase ?? { url, hops in try await Self.sessionFinalURL(following: url, maxHops: hops) }
    }

    /// The expanded, consent-unwrapped end of the chain, or nil when the
    /// chase went nowhere (the chain never moved). An entry or landing URL
    /// the egress policy refuses, a definitive HTTP error on a chain that
    /// never moved (a dead share token's 404), and a transport failure
    /// (offline, timeout) all throw typed failures rather than degrading to
    /// nil, so hosts can message the real cause.
    public func expand(_ url: URL) async throws -> URL? {
        if let reason = ELVEgressPolicy.violation(url) {
            throw ELVFetchFailure.egressBlocked(reason)
        }
        let final: URL?
        do {
            final = try await chase(url, maxHops)
        } catch let error as URLError {
            // An injected chase may let URLSession's error escape raw; the
            // live legs map it themselves, and this keeps the contract the
            // same whichever chase runs.
            throw ELVHTTPFetcher.fetchFailure(from: error)
        }
        guard let final, final != url else { return nil }
        let unwrapped = Self.unwrappedConsent(final)
        // The egress policy is the single scheme + host truth: it refuses
        // custom schemes, plain http, and private hosts alike.
        if let reason = ELVEgressPolicy.violation(unwrapped) {
            throw ELVFetchFailure.egressBlocked(reason)
        }
        return unwrapped
    }

    /// EU consent interstitial: consent.google.com wraps the real target in
    /// a `continue` query parameter. The host is anchored (exact or a
    /// subdomain — a bare `hasSuffix` let "xconsent.google.com" unwrap), and
    /// the target resolves through the scheme-allowlisted URL policy, so a
    /// custom-scheme or `javascript:` continue never unwraps.
    public static func unwrappedConsent(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host == "consent.google.com" || host.hasSuffix(".consent.google.com"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let target = items.first(where: { $0.name == "continue" })?.value,
              let unwrapped = ELVURLPolicy.resolve(target, relativeTo: nil)
        else { return url }
        return unwrapped
    }

    // MARK: - URLSession chase

    /// One shared session for every chase: connection reuse instead of a
    /// fresh pool per expansion, cookies off to match the fetcher's policy.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private static func chaseRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Redirectors behave differently for a bare CFNetwork UA; ride the
        // same persona the fetcher sends.
        request.setValue(ELVUAPersona.mobileSafari.headerValue, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func sessionFinalURL(following url: URL, maxHops: Int) async throws -> URL? {
        // HEAD is the cheap first try, so its transport errors fall through
        // to the GET leg rather than ending the chase.
        let headGuard = ELVRedirectGuard(maxHops: maxHops)
        if let response = try? await session.data(for: chaseRequest(url, method: "HEAD"), delegate: headGuard).1 {
            if let reason = headGuard.refusalReason {
                throw ELVFetchFailure.egressBlocked(reason)
            }
            if let final = response.url, final != url {
                return final
            }
        }
        // Some redirectors reject HEAD, so a GET cancelled at the headers is
        // the authoritative leg; the body is never read. Its transport
        // errors are the chase's verdict: offline stays offline instead of
        // reading as a link that "went nowhere".
        let getGuard = ELVRedirectGuard(maxHops: maxHops)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: chaseRequest(url, method: "GET"), delegate: getGuard)
        } catch let error as URLError {
            throw ELVHTTPFetcher.fetchFailure(from: error)
        }
        bytes.task.cancel()
        if let reason = getGuard.refusalReason {
            throw ELVFetchFailure.egressBlocked(reason)
        }
        guard let http = response as? HTTPURLResponse, let final = http.url else { return nil }
        if final != url { return final }
        // The chain never moved: a definitive HTTP status names a dead token
        // (maps.apple returns 404 for an unknown short link) instead of the
        // generic "could not complete".
        switch http.statusCode {
        case 200 ..< 400: return nil
        case 401: throw ELVFetchFailure.unauthenticated
        case 403, 429, 503: throw ELVFetchFailure.blocked(status: http.statusCode)
        default: throw ELVFetchFailure.httpError(status: http.statusCode)
        }
    }
}
