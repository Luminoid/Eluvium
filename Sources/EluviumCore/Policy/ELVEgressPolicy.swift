import Foundation

/// A DOM render the egress policy refused. Declared beside the policy (not
/// in EluviumNet) so `EluviumDOM` can refuse without importing the network
/// module; the pipeline maps it to its typed fetch failure.
public struct ELVEgressRefusal: Error, Sendable, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// The single egress policy: HTTPS-only; loopback, private, link-local,
/// CGNAT, and benchmark ranges blocked, in dotted-quad, integer, hex, and
/// octal spellings and as IPv4-mapped IPv6. Every path that makes the device
/// fetch — the HTTP fetcher, the short-link chase, and the DOM renderer —
/// consults this one implementation, and the redirect guard re-checks every
/// hop (a public host that 302s to a private address must not smuggle the
/// pipeline inside).
///
/// Known limit: the check is on the URL's host as written. A hostname whose
/// DNS answer is a private address (rebinding) passes; closing that requires
/// resolving before connecting, which the offline-testable transport seam
/// deliberately avoids. Pack review remains the backstop for hostile hosts.
public enum ELVEgressPolicy {
    /// A human-readable refusal reason, or nil when the URL may be fetched.
    public static func violation(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            return "scheme must be https"
        }
        guard var host = url.host?.lowercased(), !host.isEmpty else {
            return "missing host"
        }
        // A fully qualified name's trailing dot resolves the same host
        // (`localhost.`, `127.0.0.1.`), so it must not slip past the checks.
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return "missing host" }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") {
            return "local host blocked"
        }
        if host.contains(":") {
            return blockedIPv6(host).map { _ in "private address blocked" }
        }
        if let address = parseIPv4(host), isBlockedIPv4(address) {
            return "private address blocked"
        }
        return nil
    }

    // MARK: - IPv4

    /// Parses every `inet_aton` spelling: `a.b.c.d`, `a.b.c`, `a.b`, and the
    /// bare 32-bit integer, each part in decimal, hex (`0x7f`), or octal
    /// (`0177`). Returns nil for anything that is not an IPv4 literal — a
    /// hostname like `fda.gov` must never be mistaken for an address.
    private static func parseIPv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 4).contains(parts.count) else { return nil }
        var values: [UInt32] = []
        for part in parts {
            guard let value = parseIPv4Part(part) else { return nil }
            values.append(value)
        }
        switch values.count {
        case 4:
            guard values.allSatisfy({ $0 <= 0xFF }) else { return nil }
            return values[0] << 24 | values[1] << 16 | values[2] << 8 | values[3]
        case 3:
            guard values[0] <= 0xFF, values[1] <= 0xFF, values[2] <= 0xFFFF else { return nil }
            return values[0] << 24 | values[1] << 16 | values[2]
        case 2:
            guard values[0] <= 0xFF, values[1] <= 0xFFFFFF else { return nil }
            return values[0] << 24 | values[1]
        default:
            return values[0]
        }
    }

    private static func parseIPv4Part(_ part: Substring) -> UInt32? {
        guard !part.isEmpty else { return nil }
        if part.hasPrefix("0x") || part.hasPrefix("0X") {
            let digits = part.dropFirst(2)
            guard !digits.isEmpty else { return nil }
            return UInt32(digits, radix: 16)
        }
        if part.count > 1, part.hasPrefix("0") {
            return UInt32(part.dropFirst(), radix: 8)
        }
        // Decimal only — any letter means hostname, not address.
        guard part.allSatisfy(\.isNumber) else { return nil }
        return UInt32(part)
    }

    private static func isBlockedIPv4(_ address: UInt32) -> Bool {
        let blocked: [(base: UInt32, prefix: UInt32)] = [
            (0x0000_0000, 8), // 0.0.0.0/8 "this network"
            (0x0A00_0000, 8), // 10/8 private
            (0x7F00_0000, 8), // 127/8 loopback
            (0x6440_0000, 10), // 100.64/10 CGNAT
            (0xA9FE_0000, 16), // 169.254/16 link-local
            (0xAC10_0000, 12), // 172.16/12 private
            (0xC0A8_0000, 16), // 192.168/16 private
            (0xC612_0000, 15), // 198.18/15 benchmark
            (0xF000_0000, 4), // 240/4 reserved + broadcast
        ]
        return blocked.contains { base, prefix in
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
            return address & mask == base
        }
    }

    // MARK: - IPv6

    /// Returns the reason-worthy match for a blocked IPv6 literal, nil for a
    /// permitted one. The literal is parsed to its 16 bytes (`inet_pton`), so
    /// every spelling of an address lands in the same check: `::1`,
    /// `0:0:0:0:0:0:0:1`, and `[0::1]` alike. Blocks unspecified, loopback,
    /// link-local (`fe80::/10`), site-local (`fec0::/10`), unique-local
    /// (`fc00::/7`), and multicast, plus any IPv4-mapped, IPv4-compatible,
    /// NAT64 (`64:ff9b::/96`), or 6to4 (`2002::/16`) address whose embedded
    /// IPv4 is blocked. A colon host that does not parse is refused.
    private static func blockedIPv6(_ rawHost: String) -> String? {
        var host = rawHost
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // Zone index (fe80::1%en0) never changes the blocked class.
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return host }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        let embeddedIPv4 = { (offset: Int) in
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        let leadingZeros = bytes.prefix(10).allSatisfy { $0 == 0 }
        // ::/96 (unspecified, loopback, IPv4-compatible) and ::ffff:0:0/96
        // (IPv4-mapped) carry the IPv4 address in their last four bytes;
        // `::` and `::1` read as 0.0.0.0 and 0.0.0.1, both in 0.0.0.0/8.
        if leadingZeros, (bytes[10] == 0 && bytes[11] == 0) || (bytes[10] == 0xFF && bytes[11] == 0xFF) {
            return isBlockedIPv4(embeddedIPv4(12)) ? host : nil
        }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 || bytes[1] & 0xC0 == 0xC0 { return host }
        if bytes[0] & 0xFE == 0xFC { return host }
        if bytes[0] == 0xFF { return host }
        if bytes.prefix(12).elementsEqual([0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]), isBlockedIPv4(embeddedIPv4(12)) { return host }
        if bytes[0] == 0x20, bytes[1] == 0x02, isBlockedIPv4(embeddedIPv4(2)) { return host }
        return nil
    }
}
