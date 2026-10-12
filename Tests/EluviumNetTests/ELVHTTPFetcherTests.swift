import EluviumCore
import Foundation
import Testing
@testable import EluviumNet

@Suite("Fetch budget")
struct ELVFetchBudgetTests {
    @Test
    func `Budget clamps to the binary's ceiling`() {
        let budget = ELVFetchBudget(maxBytes: 999_000_000, timeout: 600)
        #expect(budget.maxBytes == ELVFetchBudget.maxBytesCeiling)
        #expect(budget.timeout == ELVFetchBudget.timeoutCeiling)
    }
}

/// A stub transport that answers 200 and then trickles 4 KiB every 50 ms for
/// as long as the task lives: fast enough that URLSession's idle timeout
/// never fires, endless enough that only a wall-clock bound can end it.
private final class TrickleProtocol: URLProtocol {
    private var timer: DispatchSourceTimer?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 4096)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            client?.urlProtocol(self, didLoad: chunk)
        }
        timer.resume()
        self.timer = timer
    }

    override func stopLoading() {
        timer?.cancel()
        timer = nil
    }
}

/// The wall-clock bound: `URLRequest.timeoutInterval` is an idle interval,
/// so a server that keeps trickling holds a fetch open forever unless the
/// fetcher bounds the whole request itself.
@Suite("Fetch deadline")
struct ELVFetchDeadlineTests {
    @Test
    func `The session's resource timeout is the budget ceiling`() {
        #expect(ELVHTTPFetcher().resourceTimeout == ELVFetchBudget.timeoutCeiling)
    }

    @Test
    func `A trickling body ends at the budget's wall-clock deadline as a timeout`() async throws {
        let fetcher = ELVHTTPFetcher(protocolClasses: [TrickleProtocol.self])
        let url = try #require(URL(string: "https://trickle.example/slow"))
        let clock = ContinuousClock()
        let started = clock.now
        // Under a stalled simulator the idle timeout can fire first; both
        // paths surface `.timeout`, and the elapsed bound is the contract.
        await #expect(throws: ELVFetchFailure.timeout) {
            _ = try await fetcher.fetch(url, budget: ELVFetchBudget(maxBytes: 3_000_000, timeout: 0.5))
        }
        #expect(clock.now - started < .seconds(10))
    }
}

/// The URLError seam: a user cancellation must surface as Swift
/// cancellation (the pipeline's marker path), never as a transport
/// failure, and unmapped codes keep their URLError raw value instead of
/// collapsing into a fake HTTP -1.
@Suite("Fetch failure mapping")
struct ELVFetchFailureMappingTests {
    @Test
    func `A cancelled URLError rethrows as CancellationError`() {
        #expect(ELVHTTPFetcher.fetchFailure(from: URLError(.cancelled)) is CancellationError)
    }

    @Test
    func `Timeout and offline codes keep their dedicated cases`() {
        #expect(ELVHTTPFetcher.fetchFailure(from: URLError(.timedOut)) as? ELVFetchFailure == .timeout)
        #expect(ELVHTTPFetcher.fetchFailure(from: URLError(.networkConnectionLost)) as? ELVFetchFailure == .offline)
        #expect(ELVHTTPFetcher.fetchFailure(from: URLError(.notConnectedToInternet)) as? ELVFetchFailure == .offline)
        #expect(ELVHTTPFetcher.fetchFailure(from: URLError(.dataNotAllowed)) as? ELVFetchFailure == .offline)
    }

    @Test
    func `Unmapped codes carry the URLError raw value as a transport failure`() {
        let code = URLError.Code.dnsLookupFailed
        #expect(ELVHTTPFetcher.fetchFailure(from: URLError(code)) as? ELVFetchFailure == .transport(code: code.rawValue))
    }
}

/// A stub transport that answers a fixed status and headers with an empty
/// body: the AWS WAF challenge shape (`202`, no bytes,
/// `x-amzn-waf-action: challenge`) and its plain-2xx control.
private final class StatusStubProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let challenged = url.path.hasPrefix("/challenge")
        let headers = challenged ? ["Content-Length": "0", "x-amzn-waf-action": "challenge"] : ["Content-Type": "text/html"]
        guard let response = HTTPURLResponse(url: url, statusCode: challenged ? 202 : 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(challenged ? [] : Array("<title>ok</title>".utf8)))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Bot walls that answer 2xx: the status alone would read as a page with
/// nothing on it, so the escalation ladder would never hear it was walled.
@Suite("Fetch bot-wall statuses")
struct ELVFetchWallStatusTests {
    @Test
    func `An AWS WAF challenge 202 is a blocked fetch, not an empty page`() async throws {
        let fetcher = ELVHTTPFetcher(protocolClasses: [StatusStubProtocol.self])
        let url = try #require(URL(string: "https://waf.example/challenge/book/1"))
        await #expect(throws: ELVFetchFailure.blocked(status: 202)) {
            _ = try await fetcher.fetch(url, budget: ELVFetchBudget())
        }
    }

    @Test
    func `A plain 2xx without the challenge header still reads its body`() async throws {
        let fetcher = ELVHTTPFetcher(protocolClasses: [StatusStubProtocol.self])
        let url = try #require(URL(string: "https://waf.example/book/1"))
        let response = try await fetcher.fetch(url, budget: ELVFetchBudget())
        #expect(response.status == 200)
        #expect(response.bodyText.contains("<title>ok</title>"))
    }
}

/// A stub transport serving a patterned body whose length is the URL's last
/// path component, in uneven pieces so the reader's staging chunk boundaries
/// never line up with the delivery boundaries.
private final class SizedBodyProtocol: URLProtocol {
    static func body(count: Int) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 % 251) })
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let count = Int(url.lastPathComponent),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.body(count: count)
        var offset = 0
        while offset < body.count {
            let end = min(offset + 9999, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset ..< end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The byte cap is exact: a body of exactly `maxBytes` is whole, one byte
/// more truncates to exactly `maxBytes`, and the bytes kept are the body's
/// own prefix, across staging-chunk and delivery boundaries alike.
@Suite("Fetch byte cap")
struct ELVFetchByteCapTests {
    private let cap = 100_003

    private func fetch(bodyBytes: Int) async throws -> ELVFetchResponse {
        let fetcher = ELVHTTPFetcher(protocolClasses: [SizedBodyProtocol.self])
        let url = try #require(URL(string: "https://sized.example/body/\(bodyBytes)"))
        return try await fetcher.fetch(url, budget: ELVFetchBudget(maxBytes: cap))
    }

    @Test
    func `A body of exactly maxBytes arrives whole and untruncated`() async throws {
        let response = try await fetch(bodyBytes: cap)
        #expect(!response.truncated)
        #expect(response.data == SizedBodyProtocol.body(count: cap))
    }

    @Test
    func `One byte past maxBytes truncates to exactly maxBytes of the body's prefix`() async throws {
        let response = try await fetch(bodyBytes: cap + 1)
        #expect(response.truncated)
        #expect(response.data == SizedBodyProtocol.body(count: cap))
    }

    @Test
    func `A body under the cap is read whole`() async throws {
        let response = try await fetch(bodyBytes: cap - 1)
        #expect(!response.truncated)
        #expect(response.data == SizedBodyProtocol.body(count: cap - 1))
    }
}
