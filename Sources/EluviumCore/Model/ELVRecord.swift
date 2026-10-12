import Foundation

/// Which candidate produced a field's value. Not optional garnish: a wrong
/// field must be attributable to its source, so provenance is part of
/// the model rather than the logs.
public struct ELVProvenance: Sendable, Codable, Equatable {
    /// The winning selector, e.g. `meta:og:title`, `jsonld:Product.name`,
    /// `native:trail.statsFromText@2`, or a merged form like `header,og`.
    public var origin: String
    /// Index of the winning candidate in the field's ordered candidate list.
    public var candidateIndex: Int?

    public init(origin: String, candidateIndex: Int? = nil) {
        self.origin = origin
        self.candidateIndex = candidateIndex
    }
}

/// The generic, open-ended, multi-level record every Eluvium pipeline
/// produces: typed leaf fields, child collections, and cross-source
/// identities.
///
/// Compatibility rules baked into the wire format:
/// - `kind` and field keys are open strings, never enums — an unrecognized
///   value must not be a decode error.
/// - Keys this binary does not understand decode into `unknown` and are
///   re-emitted unchanged, so a round trip through an older binary
///   never drops a newer binary's data.
public struct ELVRecord: Sendable, Codable, Equatable {
    /// The record format this binary writes.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// The source that produced this record. Permanent, used as a dedup key.
    public var sourceId: String
    public var sourceURL: URL?
    /// The record's id within its source (a product id, a check-in id).
    /// `sourceId` + `externalId` dedups re-imports of the same source.
    public var externalId: String?
    /// Open vocabulary (`trail`, `product`, `flight`, …), never an enum in
    /// the persisted form.
    public var kind: String
    public var fields: [String: ELVValue]
    public var collections: [String: [Self]]
    public var identities: [ELVIdentity]
    /// Per-field provenance, keyed by field key.
    public var provenance: [String: ELVProvenance]
    /// Top-level keys written by a newer binary. Preserved, never dropped.
    public var unknown: [String: ELVRawJSON]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        sourceId: String,
        sourceURL: URL? = nil,
        externalId: String? = nil,
        kind: String,
        fields: [String: ELVValue] = [:],
        collections: [String: [Self]] = [:],
        identities: [ELVIdentity] = [],
        provenance: [String: ELVProvenance] = [:],
        unknown: [String: ELVRawJSON] = [:]
    ) {
        self.formatVersion = formatVersion
        self.sourceId = sourceId
        self.sourceURL = sourceURL
        self.externalId = externalId
        self.kind = kind
        self.fields = fields
        self.collections = collections
        self.identities = identities
        self.provenance = provenance
        self.unknown = unknown
    }
}

// MARK: - Codable

public extension ELVRecord {
    /// The keys this binary models. Every other top-level key rides the
    /// unknown-preservation bag, so a newer binary's additions
    /// survive a round trip through this one untouched.
    private static let knownKeys: Set<String> = [
        "formatVersion", "sourceId", "sourceURL", "externalId", "kind",
        "fields", "collections", "identities", "provenance",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .init("formatVersion")) ?? 1
        sourceId = try container.decode(String.self, forKey: .init("sourceId"))
        // Lenient: a persisted URL that no longer parses (Foundation's URL
        // grammar tightens between releases) costs the URL, not the record.
        sourceURL = try container.decodeIfPresent(String.self, forKey: .init("sourceURL")).flatMap { URL(string: $0) }
        externalId = try container.decodeIfPresent(String.self, forKey: .init("externalId"))
        kind = try container.decodeIfPresent(String.self, forKey: .init("kind")) ?? ""
        fields = try container.decodeIfPresent([String: ELVValue].self, forKey: .init("fields")) ?? [:]
        collections = try container.decodeIfPresent([String: [ELVRecord]].self, forKey: .init("collections")) ?? [:]
        identities = try container.decodeIfPresent([ELVIdentity].self, forKey: .init("identities")) ?? []
        provenance = try container.decodeIfPresent([String: ELVProvenance].self, forKey: .init("provenance")) ?? [:]

        unknown = try container.elvUnknownKeys(excluding: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ELVDynamicKey.self)
        try container.encode(formatVersion, forKey: .init("formatVersion"))
        try container.encode(sourceId, forKey: .init("sourceId"))
        try container.encodeIfPresent(sourceURL, forKey: .init("sourceURL"))
        try container.encodeIfPresent(externalId, forKey: .init("externalId"))
        try container.encode(kind, forKey: .init("kind"))
        if !fields.isEmpty { try container.encode(fields, forKey: .init("fields")) }
        if !collections.isEmpty { try container.encode(collections, forKey: .init("collections")) }
        if !identities.isEmpty { try container.encode(identities, forKey: .init("identities")) }
        if !provenance.isEmpty { try container.encode(provenance, forKey: .init("provenance")) }
        try container.elvEncodeUnknown(unknown)
    }
}
