import Foundation
import Testing
@testable import EluviumCore

/// The hostile-lookalike conformance suite: every matcher build must
/// pass these. Cases come from TripDays' production suite.
@Suite("Anchored host matching")
struct ELVHostMatcherTests {
    @Test
    func `Exact and subdomain hosts match`() {
        #expect(ELVHostMatcher.hostMatches("booking.com", pattern: "booking.com"))
        #expect(ELVHostMatcher.hostMatches("www.booking.com", pattern: "booking.com"))
        #expect(ELVHostMatcher.hostMatches("m.airbnb.com", pattern: "airbnb.com"))
        #expect(ELVHostMatcher.hostMatches("maps.google.com", pattern: "google.com"))
        #expect(ELVHostMatcher.hostMatches("BOOKING.COM", pattern: "booking.com"))
        #expect(ELVHostMatcher.hostMatches("booking.com.", pattern: "booking.com"))
    }

    @Test
    func `Hostile lookalikes never match a host rule`() {
        #expect(!ELVHostMatcher.hostMatches("maps.google.evil.com", pattern: "google.com"))
        #expect(!ELVHostMatcher.hostMatches("airbnb.evil.com", pattern: "airbnb.com"))
        #expect(!ELVHostMatcher.hostMatches("evil-booking.com", pattern: "booking.com"))
        #expect(!ELVHostMatcher.hostMatches("yelp.com.attacker.net", pattern: "yelp.com"))
        #expect(!ELVHostMatcher.hostMatches("xn--bookng-3ta.com", pattern: "booking.com"))
        #expect(!ELVHostMatcher.hostMatches("notbooking.com", pattern: "booking.com"))
        #expect(!ELVHostMatcher.hostMatches("", pattern: "booking.com"))
    }

    @Test
    func `A userinfo-spoofed URL exposes the real host, which fails the rule`() throws {
        let url = try #require(URL(string: "https://booking.com@evil.com/hotel"))
        let host = try #require(url.host)
        #expect(!ELVHostMatcher.hostMatches(host, pattern: "booking.com"))
    }

    @Test
    func `Brand form matches real multi-TLD storefronts`() {
        #expect(ELVHostMatcher.hostMatchesBrand("amazon.com", brand: "amazon"))
        #expect(ELVHostMatcher.hostMatchesBrand("amazon.de", brand: "amazon"))
        #expect(ELVHostMatcher.hostMatchesBrand("amazon.co.jp", brand: "amazon"))
        #expect(ELVHostMatcher.hostMatchesBrand("www.amazon.co.uk", brand: "amazon"))
        #expect(ELVHostMatcher.hostMatchesBrand("smile.amazon.com.au", brand: "amazon"))
        #expect(ELVHostMatcher.hostMatchesBrand("google.de", brand: "google"))
    }

    @Test
    func `Brand form rejects lookalikes and non-anchored labels`() {
        #expect(!ELVHostMatcher.hostMatchesBrand("amazon.evil.com", brand: "amazon"))
        #expect(!ELVHostMatcher.hostMatchesBrand("evil-amazon.de", brand: "amazon"))
        #expect(!ELVHostMatcher.hostMatchesBrand("amazon.com.attacker.net", brand: "amazon"))
        #expect(!ELVHostMatcher.hostMatchesBrand("myamazon.com", brand: "amazon"))
        #expect(!ELVHostMatcher.hostMatchesBrand("amazon.co.evil.com", brand: "amazon"))
        #expect(!ELVHostMatcher.hostMatchesBrand("www.amazon", brand: "amazon"))
        #expect(!ELVHostMatcher.hostMatchesBrand("amazon.c0m", brand: "amazon"))
        #expect(!ELVHostMatcher.hostMatchesBrand("host.com", brand: "amazon.com"))
    }
}
