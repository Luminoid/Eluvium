import Foundation

/// The binary-owned UA persona set. Packs pick a persona by name —
/// never a free-form string.
public enum ELVUAPersona: String, Sendable, CaseIterable {
    /// `facebookexternalhit`: sites serve `og:` metas to known link
    /// unfurlers.
    case crawler
    /// Full meta head on share pages.
    case mobileSafari
    /// Full JSON-LD island instead of a stripped mobile shell.
    case desktopSafari

    public var headerValue: String {
        switch self {
        case .crawler:
            "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"
        case .mobileSafari:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        case .desktopSafari:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        }
    }

    /// Resolves a pack's persona name; unknown names fall back to
    /// `mobileSafari` rather than leaking a raw string into requests. The
    /// validator notes the unknown name at load (`knownNames`), so the
    /// fallback degrades with a diagnostic, never silently.
    public static func resolve(_ name: String?) -> Self {
        name.flatMap { Self(rawValue: $0) } ?? .mobileSafari
    }

    /// Every persona name a pack may write. Lives in Core (not the
    /// transport) so `ELVPackValidator` can name a typo without importing
    /// EluviumNet.
    public static let knownNames: Set<String> = Set(allCases.map(\.rawValue))
}
