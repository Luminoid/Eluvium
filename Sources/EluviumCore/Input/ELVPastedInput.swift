import Foundation

/// How pasted text becomes an input: the length cap, the bare-host TLD set
/// a whitespace-free token must end in, the schemes that count as a link,
/// and the separators a share blurb puts between a name and its brand.
public struct ELVPastePolicy: Sendable, Equatable {
    /// Pasted text longer than this is not a link paste (share blurbs run
    /// well under 1 KB); it is rejected before any scan runs over it.
    public var maxLength: Int
    /// TLDs a bare dotted token may end in to still count as a URL.
    /// Deliberately a small curated set, not every registered TLD:
    /// "Dinner.at" and "v2.beta" are titles, and accepting any alphabetic
    /// tail turns them into links.
    public var bareHostTLDs: Set<String>
    /// Schemes that make a token a link, lowercased without `://`: the web
    /// schemes plus the app schemes scheme-matched sources claim.
    public var schemes: [String]
    /// What separates a name from its brand in a share blurb's last line
    /// ("Mist Trail on AllTrails", "Ippudo - Yelp").
    public var labelSeparators: [String]

    public init(maxLength: Int, bareHostTLDs: Set<String>, schemes: [String], labelSeparators: [String]) {
        self.maxLength = maxLength
        self.bareHostTLDs = Set(bareHostTLDs.map { $0.lowercased() })
        self.schemes = schemes.map { $0.lowercased() }
        self.labelSeparators = labelSeparators
    }

    public static let standard = Self(
        maxLength: 8192,
        bareHostTLDs: [
            "com", "net", "org", "edu", "gov", "io", "co", "me", "to", "gl",
            "app", "dev", "apple",
            "de", "uk", "ca", "au", "fr", "es", "it", "nl", "jp", "cn", "kr",
        ],
        schemes: ["https", "http", "comgooglemaps", "maps", "flighty"],
        labelSeparators: [" on ", " - ", " | ", " · "]
    )
}

/// One pasted input: the link it carries, as pasted and as a URL, plus the
/// text around it when the paste was a share blurb ("Mist Trail on
/// AllTrails · Moderate · 3.0 mi https://…"). Hosts build one from a title
/// box (`parse`) or a link field (`link`) and run it through the pipeline,
/// so the blurb reaches extraction: the name it carries, and the stats
/// some shares spell out that the page may not serve.
public struct ELVPastedInput: Sendable, Hashable {
    /// The trimmed paste.
    public let text: String
    /// The link as pasted: verbatim, except a bare host gains `https://`.
    /// Never https-upgraded, so a host can store exactly what the user
    /// shared.
    public let urlText: String
    /// `urlText` parsed. Recognition and fetching upgrade `http` themselves.
    public let url: URL
    /// The text before the link in a multi-word paste, trimmed; nil for a
    /// single-token paste or an empty lead-in.
    public let leadingText: String?
    /// The whole paste with the link replaced by a space; nil for a
    /// single-token paste. A share token in the URL can read as a stat
    /// ("…?sh=7mixyz" as "7 mi"), so stats parse from this, never `text`.
    public let blurb: String?

    /// An input that is just a URL (a link already parsed).
    public init(url: URL) {
        text = url.absoluteString
        urlText = url.absoluteString
        self.url = url
        leadingText = nil
        blurb = nil
    }

    private init(text: String, urlText: String, url: URL, leadingText: String?, blurb: String?) {
        self.text = text
        self.urlText = urlText
        self.url = url
        self.leadingText = leadingText
        self.blurb = blurb
    }

    /// The strict reading for text pasted into a TITLE box: only clearly
    /// link-shaped text counts, so ordinary titles ("Dinner at 7", "v2.0
    /// planning", "Dinner.at") never become links. A single token needs a
    /// known scheme or a dotted host ending in a known TLD; multi-word text
    /// needs an embedded link with an explicit known scheme, and the text
    /// before it becomes `leadingText`.
    public static func parse(_ raw: String, policy: ELVPastePolicy = .standard) -> Self? {
        guard raw.count <= policy.maxLength else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return strictToken(trimmed, policy: policy)
        }
        guard let embedded = firstEmbeddedLink(in: trimmed, policy: policy),
              let url = URL(string: embedded.token), hasAddress(url)
        else { return nil }
        let blurb = trimmed.replacingOccurrences(of: embedded.token, with: " ")
        return Self(
            text: trimmed,
            urlText: embedded.token,
            url: url,
            leadingText: embedded.leading.isEmpty ? nil : embedded.leading,
            blurb: blurb
        )
    }

    /// The lenient reading for a LINK field: one whitespace-free token, a
    /// bare host gains `https://`, and any scheme with an address parses
    /// (the field's purpose already says it is a link).
    public static func link(_ raw: String, policy: ELVPastePolicy = .standard) -> Self? {
        guard raw.count <= policy.maxLength else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), hasAddress(url) else { return nil }
        return Self(text: trimmed, urlText: normalized, url: url, leadingText: nil, blurb: nil)
    }

    /// A single token through the strict gate: a known scheme only (a paste
    /// glued to typed text, "Dinhttps://…", must not store junk), or a
    /// dotted host whose every label is non-empty and whose last is a
    /// known TLD.
    private static func strictToken(_ token: String, policy: ELVPastePolicy) -> Self? {
        if let schemeEnd = token.range(of: "://") {
            let scheme = token[..<schemeEnd.lowerBound].lowercased()
            guard policy.schemes.contains(scheme) else { return nil }
            return link(token, policy: policy)
        }
        let hostChunk = token.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let labels = hostChunk.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              let tld = labels.last, policy.bareHostTLDs.contains(tld.lowercased())
        else { return nil }
        return link(token, policy: policy)
    }

    /// The first link anchored on a known scheme in free text, plus the
    /// trimmed text before it. Scheme-anchored, so a bare dotted word in a
    /// sentence never fires.
    private static func firstEmbeddedLink(in text: String, policy: ELVPastePolicy) -> (token: String, leading: String)? {
        let start = policy.schemes
            .compactMap { text.range(of: $0 + "://", options: .caseInsensitive)?.lowerBound }
            .min()
        guard let start else { return nil }
        let token = text[start...].prefix { !$0.isWhitespace }
        let leading = text[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(token), leading)
    }

    /// A web link needs a host; an app-scheme link (`comgooglemaps://?q=…`,
    /// `flighty://flight/UA1`) carries its address in the query or path.
    private static func hasAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "http" || scheme == "https" {
            return !(url.host ?? "").isEmpty
        }
        return url.absoluteString.count > scheme.count + 3
    }
}

/// The human names a share blurb's lead-in can carry, derived once the
/// brand of the matched source is known.
public enum ELVShareLabel {
    /// The "<name> on <Brand>" form (AllTrails, Yelp, Google Maps): the
    /// lead-in's last non-empty line with a separator + brand suffix
    /// stripped, case-insensitively. Nil for arbitrary lead-in text ("Check
    /// this out"), so only a deliberately named share yields a name.
    public static func suffixed(leading: String, brand: String, separators: [String]) -> String? {
        guard !brand.isEmpty else { return nil }
        let lastLine = leading.split(whereSeparator: \.isNewline).last.map(String.init) ?? leading
        let name = lastLine.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in separators {
            let suffix = separator + brand
            guard name.lowercased().hasSuffix(suffix.lowercased()) else { continue }
            let stripped = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : stripped
        }
        return nil
    }

    /// The whole lead-in as a title (social posts carry their title in the
    /// blurb, not the URL): trimmed, trailing truncation marks dropped,
    /// capped at `limit` characters with an ellipsis.
    public static func whole(leading: String, limit: Int = 80) -> String? {
        var text = leading.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("…") || text.hasSuffix(".") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }
        if text.count > limit {
            text = String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }
}
