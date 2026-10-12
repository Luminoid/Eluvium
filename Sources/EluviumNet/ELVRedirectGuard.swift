import EluviumCore
import Foundation

/// Caps a redirect chain AND runs the egress policy on every intermediate
/// hop — URLSession otherwise connects to each hop before the caller ever
/// sees the final URL, so checking only the landing lets a public host 302
/// the pipeline onto an internal address. Past the cap or on a violation the
/// delegate declines the hop; URLSession then completes with the last
/// response reached, and the owner reads `refusalReason` to throw a typed
/// failure instead of a bare 3xx.
///
/// Public so a host that fetches page-derived URLs itself (a thumbnail
/// loader) rides the same per-hop policy instead of keeping a twin.
///
/// `@unchecked Sendable`: URLSession serializes its delegate callbacks, so
/// the mutable state never races.
public final class ELVRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let defaultMaxHops = 10

    private let maxHops: Int
    private var hops = 0
    public private(set) var refusalReason: String?

    public init(maxHops: Int = ELVRedirectGuard.defaultMaxHops) {
        self.maxHops = maxHops
    }

    public func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        hops += 1
        guard hops <= maxHops else {
            refusalReason = "redirect chain exceeded \(maxHops) hops"
            completionHandler(nil)
            return
        }
        if let url = request.url, let reason = ELVEgressPolicy.violation(url) {
            refusalReason = reason
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
