import Foundation

/// A source's match rule. `hosts` use exact-or-subdomain semantics,
/// `brands` use the TLD-constrained brand form — there is deliberately no
/// substring form in this type, which is what makes lookalike hosts
/// unmatchable by construction.
public struct ELVMatchRule: Sendable, Decodable, Equatable {
    public var hosts: [String]
    public var brands: [String]
    /// Path patterns with `:name` captures (see `ELVPathPattern`), tried in
    /// order; the first match wins and supplies the params. The `path` key
    /// takes a scalar or an array (leniency), so a multi-shape source
    /// (`/subject/:id/**` alongside `/game/:id/**`) is one source, not one
    /// per shape.
    public var paths: [String]
    /// Higher wins when several exact sources match one URL.
    public var priority: Int
    /// File-input sources match on filename + content probe instead
    /// of a host.
    public var file: ELVFileMatchRule?

    public init(hosts: [String] = [], brands: [String] = [], paths: [String] = [], priority: Int = 0, file: ELVFileMatchRule? = nil) {
        self.hosts = hosts
        self.brands = brands
        self.paths = paths
        self.priority = priority
        self.file = file
    }

    private enum CodingKeys: String, CodingKey {
        case hosts = "host"
        case brands = "brand"
        case paths = "path"
        case priority
        case file
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try container.elvStringList(forKey: .hosts)
        brands = try container.elvStringList(forKey: .brands)
        paths = try container.elvStringList(forKey: .paths)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        file = try container.decodeIfPresent(ELVFileMatchRule.self, forKey: .file)
    }

    /// A rule with no host, brand, path, or file constraint: it matches any
    /// URL, which is what makes a generic floor a floor.
    public var isCatchAll: Bool {
        hosts.isEmpty && brands.isEmpty && paths.isEmpty && file == nil
    }
}

/// A filename-pattern + content-probe rule for file inputs:
/// `{"name": "FlightyExport-*.csv", "probe": {"csvHeader": ["Date", "Airline"]}}`.
public struct ELVFileMatchRule: Sendable, Decodable, Equatable {
    /// A glob over the file's display name (`*` and `?` wildcards,
    /// case-insensitive).
    public var name: String
    /// Header names that must all appear in a CSV's first row.
    public var csvHeader: [String]
    /// Tokens that must all appear (case-insensitive) near the head of the
    /// file's text — the content probe for non-CSV formats (`"<opml"` for a
    /// subscription list).
    public var contains: [String]

    /// How much of the file's head the `contains` probe reads: enough for
    /// any prolog + root element, cheap on a multi-MB archive.
    static let containsProbeLength = 4096

    public init(name: String, csvHeader: [String] = [], contains: [String] = []) {
        self.name = name
        self.csvHeader = csvHeader
        self.contains = contains
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case probe
    }

    private enum ProbeKeys: String, CodingKey {
        case csvHeader
        case contains
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let probe = try? container.nestedContainer(keyedBy: ProbeKeys.self, forKey: .probe) {
            // The same scalar-or-array leniency as every other
            // string-list key in the pack grammar.
            csvHeader = try probe.elvStringList(forKey: .csvHeader)
            contains = try probe.elvStringList(forKey: .contains)
        } else {
            csvHeader = []
            contains = []
        }
    }

    /// Whether the head of `text` carries every `contains` token
    /// (case-insensitive). True when the rule declares none.
    public func matchesContent(_ text: String) -> Bool {
        guard !contains.isEmpty else { return true }
        let head = String(text.prefix(Self.containsProbeLength)).lowercased()
        return contains.allSatisfy { head.contains($0.lowercased()) }
    }

    /// Whether `fileName` matches the glob.
    public func matchesName(_ fileName: String) -> Bool {
        // A pack pattern compiled once through the shared cache; the inline
        // `(?i)` carries the documented case-insensitivity.
        let escaped = NSRegularExpression.escapedPattern(for: name)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return ELVRegexCache.matches("(?i)^\(escaped)$", in: fileName)
    }
}
