import Foundation
import Testing
@testable import EluviumCore

@Suite("Egress policy")
struct ELVEgressTests {
    private func violation(_ string: String) -> String? {
        guard let url = URL(string: string) else { return "invalid url" }
        return ELVEgressPolicy.violation(url)
    }

    @Test
    func `HTTPS public hosts pass`() {
        #expect(violation("https://www.alltrails.com/trail/x") == nil)
        #expect(violation("https://api.themeparks.wiki/v1/entity/x") == nil)
    }

    @Test
    func `Non-HTTPS schemes are blocked`() {
        #expect(violation("http://example.com") != nil)
        #expect(violation("file:///etc/passwd") != nil)
        #expect(violation("ftp://example.com") != nil)
    }

    @Test
    func `Loopback, private, and link-local hosts are blocked (SSRF guard)`() {
        #expect(violation("https://localhost/admin") != nil)
        #expect(violation("https://127.0.0.1/") != nil)
        #expect(violation("https://10.0.0.5/") != nil)
        #expect(violation("https://192.168.1.1/") != nil)
        #expect(violation("https://172.16.0.1/") != nil)
        #expect(violation("https://169.254.169.254/latest/meta-data") != nil)
        #expect(violation("https://printer.local/") != nil)
    }

    @Test
    func `Public IPs outside private ranges pass`() {
        #expect(violation("https://8.8.8.8/") == nil)
        #expect(violation("https://172.32.0.1/") == nil)
    }

    @Test
    func `Integer, hex, IPv6-mapped, CGNAT, and benchmark spellings are blocked`() {
        #expect(violation("https://2130706433/") != nil) // 127.0.0.1 as a bare 32-bit integer
        #expect(violation("https://0x7f.0.0.1/") != nil) // hex first octet
        #expect(violation("https://[::ffff:127.0.0.1]/") != nil) // IPv4-mapped IPv6 loopback
        #expect(violation("https://100.64.0.1/") != nil) // CGNAT 100.64/10
        #expect(violation("https://198.18.0.1/") != nil) // benchmark 198.18/15
    }

    @Test
    func `Hostnames are never mistaken for address literals`() {
        // The old prefix check read "fd…" as a ULA address and blocked a
        // real .gov domain.
        #expect(violation("https://fda.gov/") == nil)
    }

    @Test
    func `Every IPv6 spelling of a blocked address is blocked`() {
        let blocked = [
            "https://[0:0:0:0:0:0:0:1]/", "https://[0::1]/", "https://[::]/", // loopback, unspecified
            "https://[fe81::1]/", "https://[febf::1]/", "https://[fec0::1]/", // link-local /10, site-local
            "https://[fc00::1]/", "https://[fdff::1]/", "https://[ff02::1]/", // unique-local, multicast
            "https://[0:0:0:0:0:ffff:7f00:1]/", "https://[::ffff:10.0.0.1]/", // IPv4-mapped, uncompressed too
            "https://[::127.0.0.1]/", "https://[64:ff9b::c0a8:101]/", "https://[2002:c0a8:101::1]/", // compatible, NAT64, 6to4
        ]
        for url in blocked {
            #expect(violation(url) != nil, "\(url)")
        }
        #expect(violation("https://[2606:4700:4700::1111]/") == nil) // public resolver
        #expect(violation("https://[::ffff:8.8.8.8]/") == nil) // mapped public IPv4
        #expect(violation("https://[64:ff9b::808:808]/") == nil) // NAT64 of a public IPv4
    }

    @Test
    func `A trailing dot never slips a local host past the policy`() {
        #expect(violation("https://localhost./") != nil)
        #expect(violation("https://127.0.0.1./") != nil)
        #expect(violation("https://printer.local./") != nil)
        #expect(violation("https://example.com./") == nil)
    }

    @Test
    func `UA personas resolve by name and fall back safely`() {
        #expect(ELVUAPersona.resolve("crawler") == .crawler)
        #expect(ELVUAPersona.resolve("desktopSafari") == .desktopSafari)
        #expect(ELVUAPersona.resolve("nonsense") == .mobileSafari)
        #expect(ELVUAPersona.resolve(nil) == .mobileSafari)
        #expect(ELVUAPersona.crawler.headerValue.contains("facebookexternalhit"))
    }
}
