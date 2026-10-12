import EluviumCore
import Foundation
import Testing
@testable import EluviumNet

@Suite("Short-link expansion")
struct ELVShortLinkExpanderTests {
    private func expander(landingOn final: String?) -> ELVShortLinkExpander {
        ELVShortLinkExpander(chase: { _, _ in final.flatMap(URL.init(string:)) })
    }

    @Test
    func `The chase result is returned when it moves and passes the guards`() async throws {
        let short = try #require(URL(string: "https://maps.app.goo.gl/abc123"))
        let expanded = try await expander(landingOn: "https://www.google.com/maps/place/Benu/data=!3d37.78!4d-122.39").expand(short)
        #expect(expanded?.host == "www.google.com")
    }

    @Test
    func `A chase that goes nowhere yields nil`() async throws {
        let short = try #require(URL(string: "https://maps.app.goo.gl/abc123"))
        let unmoved = try await expander(landingOn: "https://maps.app.goo.gl/abc123").expand(short)
        #expect(unmoved == nil)
        let failed = try await expander(landingOn: nil).expand(short)
        #expect(failed == nil)
    }

    @Test
    func `A chase whose chain dead-ends on an HTTP error rethrows it typed`() async throws {
        let short = try #require(URL(string: "https://maps.apple/p/dead-token"))
        let dead = ELVShortLinkExpander(chase: { _, _ in throw ELVFetchFailure.httpError(status: 404) })
        await #expect(throws: ELVFetchFailure.httpError(status: 404)) {
            _ = try await dead.expand(short)
        }
    }

    @Test
    func `A redirect can never smuggle the pipeline onto a private or non-https host`() async throws {
        let short = try #require(URL(string: "https://yelp.to/abc"))
        for landing in ["https://192.168.1.1/admin", "http://example.com/x", "https://169.254.169.254/latest"] {
            do {
                _ = try await expander(landingOn: landing).expand(short)
                Issue.record("Expected egressBlocked for \(landing)")
            } catch let failure as ELVFetchFailure {
                guard case .egressBlocked = failure else {
                    Issue.record("Expected egressBlocked, got \(failure) for \(landing)")
                    continue
                }
            }
        }
    }

    @Test
    func `The consent interstitial unwraps on the anchored host only`() throws {
        let wrapped = try #require(URL(string: "https://consent.google.com/m?continue=https%3A%2F%2Fwww.google.com%2Fmaps%2Fplace%2FBenu"))
        #expect(ELVShortLinkExpander.unwrappedConsent(wrapped).host == "www.google.com")

        // "xconsent.google.com" is NOT consent.google.com or a subdomain.
        let spoofed = try #require(URL(string: "https://xconsent.google.com/m?continue=https%3A%2F%2Fevil.example%2F"))
        #expect(ELVShortLinkExpander.unwrappedConsent(spoofed) == spoofed)

        // A custom-scheme or script target never unwraps: the continue
        // value resolves through the scheme-allowlisted URL policy.
        let scheme = try #require(URL(string: "https://consent.google.com/m?continue=comgooglemaps%3A%2F%2Fx"))
        #expect(ELVShortLinkExpander.unwrappedConsent(scheme) == scheme)
        let script = try #require(URL(string: "https://consent.google.com/m?continue=javascript%3Aalert(1)"))
        #expect(ELVShortLinkExpander.unwrappedConsent(script) == script)
    }

    @Test
    func `An entry URL the egress policy refuses throws before any chase runs`() async throws {
        // A redirector source's op is the one fetch a recognized source
        // makes before the pipeline's own transport, so the entry URL meets
        // the policy here: plain http, a loopback host, a file: origin.
        for origin in ["http://bit.ly/abc", "https://127.0.0.1/abc", "file:///etc/hosts"] {
            let url = try #require(URL(string: origin))
            let expander = ELVShortLinkExpander(chase: { _, _ in
                Issue.record("The chase must not run for \(origin)")
                return nil
            })
            do {
                _ = try await expander.expand(url)
                Issue.record("Expected egressBlocked for \(origin)")
            } catch let failure as ELVFetchFailure {
                guard case .egressBlocked = failure else {
                    Issue.record("Expected egressBlocked, got \(failure) for \(origin)")
                    continue
                }
            }
        }
    }

    @Test
    func `A transport error on the chase surfaces typed: offline stays offline`() async throws {
        // The GET leg used to `try?` its URLError into nil, so a device with
        // no network read as a link that "went nowhere".
        let short = try #require(URL(string: "https://maps.app.goo.gl/abc123"))
        let offline = ELVShortLinkExpander(chase: { _, _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: ELVFetchFailure.offline) {
            _ = try await offline.expand(short)
        }
        let timedOut = ELVShortLinkExpander(chase: { _, _ in throw URLError(.timedOut) })
        await #expect(throws: ELVFetchFailure.timeout) {
            _ = try await timedOut.expand(short)
        }
    }

    @Test
    func `A chase landing on the consent page returns the unwrapped target`() async throws {
        let short = try #require(URL(string: "https://maps.app.goo.gl/abc123"))
        let expanded = try await expander(landingOn: "https://consent.google.com/m?continue=https%3A%2F%2Fwww.google.com%2Fmaps%2Fplace%2FBenu").expand(short)
        #expect(expanded?.host == "www.google.com")
        #expect(expanded?.path == "/maps/place/Benu")
    }

    @Test
    func `The op registers async, gates capabilities, and emits the expanded URL`() async throws {
        ELVStubChase.register()
        #expect(ELVNativeOps.isRegistered("shortlink.expand"))
        let op = try #require(ELVNativeOps.lookupAsync("shortlink.expand"))
        let outputs = try #require(await op(["url": "https://maps.app.goo.gl/to-alltrails"], ELVExtractionContext()))
        let expected = try #require(URL(string: "https://www.alltrails.com/trail/us/wyoming/hidden-falls-trail"))
        #expect(outputs["url"] == .url(expected))
    }
}
