import Foundation
import Testing
@testable import EluviumCore

@Suite("URL policy")
struct ELVURLPolicyTests {
    @Test
    func `httpsUpgraded rewrites only the scheme of an http URL`() throws {
        let upgraded = try ELVURLPolicy.httpsUpgraded(#require(URL(string: "http://xhslink.com/o/exampleId0?a=1#frag")))
        #expect(upgraded.absoluteString == "https://xhslink.com/o/exampleId0?a=1#frag")
        let secure = try #require(URL(string: "https://example.com/x"))
        #expect(ELVURLPolicy.httpsUpgraded(secure) == secure)
        let file = try #require(URL(string: "file:///tmp/x"))
        #expect(ELVURLPolicy.httpsUpgraded(file) == file)
        let upperCased = try ELVURLPolicy.httpsUpgraded(#require(URL(string: "HTTP://example.com/")))
        #expect(upperCased.scheme == "https")
    }

    @Test
    func `resolve admits http(s) only and treats protocol-relative forms as https`() throws {
        let base = try #require(URL(string: "https://example.com/page"))
        #expect(ELVURLPolicy.resolve("/a", relativeTo: base)?.absoluteString == "https://example.com/a")
        #expect(ELVURLPolicy.resolve("//cdn.example/a.jpg", relativeTo: nil)?.absoluteString == "https://cdn.example/a.jpg")
        #expect(ELVURLPolicy.resolve("javascript:alert(1)", relativeTo: base) == nil)
        #expect(ELVURLPolicy.resolve("data:text/html,x", relativeTo: base) == nil)
        #expect(ELVURLPolicy.resolve("   ", relativeTo: base) == nil)
    }

    @Test
    func `resolve refuses a dotless host and keeps dotted names and IP literals`() throws {
        let base = try #require(URL(string: "https://example.com/page"))
        // fujifilm-x.com writes a WordPress attachment id where its
        // og:image URL belongs (2026-10-12); the id is not a host.
        #expect(ELVURLPolicy.resolve("http://92884", relativeTo: base) == nil)
        #expect(ELVURLPolicy.resolve("https://intranet/hero.jpg", relativeTo: base) == nil)
        #expect(ELVURLPolicy.resolve("https://cdn.example.net/hero.jpg", relativeTo: base)?.host == "cdn.example.net")
        #expect(ELVURLPolicy.resolve("https://93.184.216.34/hero.jpg", relativeTo: base)?.host == "93.184.216.34")
        #expect(ELVURLPolicy.resolve("https://[2606:2800:220:1:248:1893:25c8:1946]/hero.jpg", relativeTo: base) != nil)
        // Relative forms take the base's host.
        #expect(ELVURLPolicy.resolve("hero.jpg", relativeTo: base)?.absoluteString == "https://example.com/hero.jpg")
    }
}
