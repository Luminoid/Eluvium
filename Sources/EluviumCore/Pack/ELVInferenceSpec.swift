import Foundation

/// The declared kind-inference tables: extracted evidence → suggested
/// record kind. TripDays maintains four independent hardcoded taxonomies
/// mapping to the same result (the JSON-LD `@type` switch, the word-bounded
/// Maps category-keyword table, the `MKPointOfInterestCategory` switch, and
/// host-brand inference); here they are one pack-owned section.
///
/// Semantics mirrored from the source implementations, not the code:
/// - Unmatched evidence yields NO suggestion — never a wrong default.
/// - A suggestion fills only an absent kind; an authored `kind` always wins
///   (the assembler owns that gate).
/// - `categoryKeyword` matching is word-bounded ("barn" never matches a
///   "bar" entry) through `ELVTokenizedText`, the one-pass tokenization
///   `ELVMapsMetaClassifier.category` shares — a pack string never becomes
///   a regex pattern here.
///
/// Pack-controlled strings are hostile input: keys normalize and each table
/// caps in `init`, truncation is deterministic (sorted keys), and decode
/// leniency is forward-compatible: an unknown key inside `inference` or a malformed
/// table degrades with a note the validator surfaces, never a dead source.
public struct ELVInferenceSpec: Sendable, Decodable, Equatable {
    static let maxEntriesPerTable = 128
    static let maxKeyLength = 128
    static let maxKindLength = 64
    /// Category evidence text is field-sourced and short; the bound keeps a
    /// hostile multi-KB field value from feeding the tokenizer unbounded.
    static let maxCategoryEvidenceLength = 1024

    /// JSON-LD `@type` → kind. Keys stored lowercased; matched against every
    /// scanned node's types in document order, case-insensitively.
    public var jsonldType: [String: String]
    /// Word-bounded keyword → kind, matched within the extracted category
    /// evidence fields only (see `categoryFieldNames`).
    public var categoryKeyword: [String: String]
    /// Platform point-of-interest category → kind. Evidence arrives verbatim
    /// from `place.mapKitLookup` (`MKPOICategoryRestaurant`); keys are
    /// authored bare (`restaurant`), so the prefix strips before lookup.
    public var poiCategory: [String: String]
    /// Host brand → kind. Bare keys use the TLD-constrained brand matcher,
    /// dotted keys the exact-or-subdomain host matcher — there is no
    /// substring form, so `opentable.evil.com` can never earn a kind.
    public var hostBrand: [String: String]
    /// Decode and clamp bookkeeping (unknown keys, malformed or empty or
    /// truncated tables), surfaced as validator diagnostics. Not wire data.
    public var decodeIssues: [String]

    public init(
        jsonldType: [String: String] = [:],
        categoryKeyword: [String: String] = [:],
        poiCategory: [String: String] = [:],
        hostBrand: [String: String] = [:],
        decodeIssues: [String] = []
    ) {
        var issues = decodeIssues
        self.jsonldType = Self.sanitized(jsonldType, table: "jsonldType", issues: &issues)
        self.categoryKeyword = Self.sanitized(categoryKeyword, table: "categoryKeyword", issues: &issues)
        self.poiCategory = Self.sanitized(poiCategory, table: "poiCategory", issues: &issues)
        self.hostBrand = Self.sanitized(hostBrand, table: "hostBrand", issues: &issues)
        self.decodeIssues = issues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        var issues: [String] = []
        func table(_ name: String) -> [String: String] {
            let key = ELVDynamicKey(name)
            guard container.contains(key) else { return [:] }
            guard let raw = try? container.decode([String: String].self, forKey: key) else {
                issues.append("\(name) is not a string-to-string map; the table is dropped")
                return [:]
            }
            if raw.isEmpty { issues.append("\(name) is declared but empty; it can never suggest a kind") }
            return raw
        }
        let jsonldType = table("jsonldType")
        let categoryKeyword = table("categoryKeyword")
        let poiCategory = table("poiCategory")
        let hostBrand = table("hostBrand")
        for key in container.allKeys.map(\.stringValue).sorted() where !Self.knownTables.contains(key) {
            issues.append("key \"\(key)\" is not an inference table this binary knows; it is ignored")
        }
        self.init(jsonldType: jsonldType, categoryKeyword: categoryKeyword, poiCategory: poiCategory, hostBrand: hostBrand, decodeIssues: issues)
    }

    /// Whether no table carries a single entry.
    public var isEmpty: Bool {
        jsonldType.isEmpty && categoryKeyword.isEmpty && poiCategory.isEmpty && hostBrand.isEmpty
    }

    /// Named tables for the validator's per-entry walk, in axis order.
    var namedTables: [(name: String, entries: [String: String])] {
        [("jsonldType", jsonldType), ("categoryKeyword", categoryKeyword), ("poiCategory", poiCategory), ("hostBrand", hostBrand)]
    }

    // MARK: - Execution

    /// The suggested kind for the evidence in `context`, or nil when nothing
    /// matches. Axis order is fixed: declared, exact evidence first (JSON-LD
    /// types, then the platform POI category), fuzzy category text next, and
    /// the whole-site host prior last.
    public func suggestedKind(context: ELVExtractionContext) -> String? {
        if let kind = jsonldTypeMatch(in: context.document.jsonLDNodes) { return kind }
        if let kind = poiCategoryMatch(in: context.fields) { return kind }
        if let kind = categoryKeywordMatch(in: context.fields) { return kind }
        if let kind = hostBrandMatch(for: context.url) { return kind }
        return nil
    }

    /// The convention fields category evidence is read from: `category` is
    /// what `maps.classifyMetaSegments`, `jsonld.bestPlaceNode`, and
    /// `place.mapKitLookup` emit; `type` carries the raw type phrase
    /// ("Pizza restaurant"). Titles and body text deliberately never
    /// contribute — unanchored text is someone else's evidence (the TripDays
    /// related-trail-card lesson).
    private static let categoryFieldNames = ["category", "type", "poiCategory"]

    private func jsonldTypeMatch(in nodes: [ELVRawJSON]) -> String? {
        guard !jsonldType.isEmpty else { return nil }
        for node in nodes {
            guard let typeValue = node["@type"] else { continue }
            let types = typeValue.stringValue.map { [$0] } ?? (typeValue.arrayValue?.compactMap(\.stringValue) ?? [])
            for type in types {
                if let kind = usable(jsonldType[type.lowercased()]) { return kind }
            }
        }
        return nil
    }

    private func poiCategoryMatch(in fields: [String: ELVValue]) -> String? {
        guard !poiCategory.isEmpty else { return nil }
        for name in Self.categoryFieldNames {
            guard let value = fields[name], let string = ELVSelectorEngine.stringForm(of: value)?.singleString else { continue }
            if let kind = usable(poiCategory[Self.normalizedPOICategory(string)]) { return kind }
        }
        return nil
    }

    /// MapKit rawValues carry an `MKPOICategory` prefix the authored keys
    /// omit; anything else lowercases and trims only.
    private static func normalizedPOICategory(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = "mkpoicategory"
        return lowered.hasPrefix(prefix) ? String(lowered.dropFirst(prefix.count)) : lowered
    }

    private func categoryKeywordMatch(in fields: [String: ELVValue]) -> String? {
        guard !categoryKeyword.isEmpty else { return nil }
        let evidence = Self.categoryFieldNames
            .compactMap { name in fields[name].flatMap { ELVSelectorEngine.stringForm(of: $0)?.singleString } }
            .joined(separator: " ")
        guard !evidence.isEmpty else { return nil }
        // Keys are stored lowercased, which is what the tokenized probe
        // expects of its keywords.
        let tokenized = ELVTokenizedText(String(evidence.prefix(Self.maxCategoryEvidenceLength)))
        // Sorted keys: when several keywords hit one phrase, the winner is
        // deterministic rather than dictionary-order random.
        for keyword in categoryKeyword.keys.sorted() where tokenized.contains(keyword: keyword) {
            if let kind = usable(categoryKeyword[keyword]) { return kind }
        }
        return nil
    }

    private func hostBrandMatch(for url: URL?) -> String? {
        guard !hostBrand.isEmpty, let host = url?.host else { return nil }
        for key in hostBrand.keys.sorted() {
            let matches = key.contains(".")
                ? ELVHostMatcher.hostMatches(host, pattern: key)
                : ELVHostMatcher.hostMatchesBrand(host, brand: key)
            if matches, let kind = usable(hostBrand[key]) { return kind }
        }
        return nil
    }

    /// A blank kind is no suggestion (the validator flags the entry).
    private func usable(_ kind: String?) -> String? {
        guard let kind, !kind.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return kind
    }

    // MARK: - Sanitizing

    private static let knownTables: Set<String> = ["jsonldType", "categoryKeyword", "poiCategory", "hostBrand"]

    /// Normalizes keys (trim + lowercase) and applies the hostile-input caps.
    /// Iteration is over sorted keys so truncation and duplicate-key
    /// resolution are deterministic.
    private static func sanitized(_ raw: [String: String], table: String, issues: inout [String]) -> [String: String] {
        var entries: [String: String] = [:]
        var droppedMalformed = 0
        var droppedOverCap = 0
        for key in raw.keys.sorted() {
            guard let kind = raw[key] else { continue }
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty, normalizedKey.count <= maxKeyLength, kind.count <= maxKindLength else {
                droppedMalformed += 1
                continue
            }
            guard entries.count < maxEntriesPerTable else {
                droppedOverCap += 1
                continue
            }
            if entries[normalizedKey] == nil { entries[normalizedKey] = kind }
        }
        if droppedMalformed > 0 {
            issues.append("\(table) dropped \(droppedMalformed) entries with an empty or oversized key or kind")
        }
        if droppedOverCap > 0 {
            issues.append("\(table) is capped at \(maxEntriesPerTable) entries; \(droppedOverCap) dropped")
        }
        return entries
    }
}
