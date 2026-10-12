import Foundation

/// Precision carried by an `ELVValue.date`.
///
/// Sources publish dates at wildly different granularities (a film's release
/// year, a check-in's timestamp); consumers must know how much of the `Date`
/// is meaningful before formatting or comparing.
///
/// An open token like `ELVMediaRef.kind`: a precision written by a newer
/// binary decodes as `.unknown(token)` and re-encodes as that same token, so
/// a round trip through this binary never rewrites it. Display treats
/// an unknown precision as `.day`, the conservative middle.
public enum ELVDatePrecision: Sendable, Equatable, Hashable {
    case year
    case month
    case day
    case time
    /// A precision token this binary does not know, preserved verbatim.
    case unknown(String)

    /// The wire token: `year`, `month`, `day`, `time`, or the preserved
    /// unknown token.
    public var rawValue: String {
        switch self {
        case .year: "year"
        case .month: "month"
        case .day: "day"
        case .time: "time"
        case let .unknown(token): token
        }
    }

    /// Never fails: an unrecognized token becomes `.unknown(token)`.
    public init(rawValue: String) {
        switch rawValue {
        case "year": self = .year
        case "month": self = .month
        case "day": self = .day
        case "time": self = .time
        default: self = .unknown(rawValue)
        }
    }
}

extension ELVDatePrecision: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A structured postal address leaf.
///
/// Consumer-authored: a host or a future pack writes these; no extraction
/// path produces them yet (addresses extract as `.text`). Keys this binary
/// does not model ride `unknown` and re-encode unchanged, the same
/// contract as `ELVRecord`.
public struct ELVPostalAddress: Sendable, Equatable {
    public var street: String?
    public var locality: String?
    public var region: String?
    public var postalCode: String?
    public var countryCode: String?
    /// The address as one display string, when the source only offers that.
    public var formatted: String?
    /// Keys written by a newer binary, preserved verbatim.
    public var unknown: [String: ELVRawJSON]

    public init(
        street: String? = nil,
        locality: String? = nil,
        region: String? = nil,
        postalCode: String? = nil,
        countryCode: String? = nil,
        formatted: String? = nil,
        unknown: [String: ELVRawJSON] = [:]
    ) {
        self.street = street
        self.locality = locality
        self.region = region
        self.postalCode = postalCode
        self.countryCode = countryCode
        self.formatted = formatted
        self.unknown = unknown
    }
}

extension ELVPostalAddress: Codable {
    private static let knownKeys: Set<String> = ["street", "locality", "region", "postalCode", "countryCode", "formatted"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        street = try container.decodeIfPresent(String.self, forKey: .init("street"))
        locality = try container.decodeIfPresent(String.self, forKey: .init("locality"))
        region = try container.decodeIfPresent(String.self, forKey: .init("region"))
        postalCode = try container.decodeIfPresent(String.self, forKey: .init("postalCode"))
        countryCode = try container.decodeIfPresent(String.self, forKey: .init("countryCode"))
        formatted = try container.decodeIfPresent(String.self, forKey: .init("formatted"))
        unknown = try container.elvUnknownKeys(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ELVDynamicKey.self)
        try container.encodeIfPresent(street, forKey: .init("street"))
        try container.encodeIfPresent(locality, forKey: .init("locality"))
        try container.encodeIfPresent(region, forKey: .init("region"))
        try container.encodeIfPresent(postalCode, forKey: .init("postalCode"))
        try container.encodeIfPresent(countryCode, forKey: .init("countryCode"))
        try container.encodeIfPresent(formatted, forKey: .init("formatted"))
        try container.elvEncodeUnknown(unknown)
    }
}

/// An image or video reference leaf.
///
/// `kind` is an open string (`ELVMediaRef.image` / `.video`) so a future media
/// kind decodes on an old binary instead of failing the record. Keys this
/// binary does not model ride `unknown` and re-encode unchanged.
public struct ELVMediaRef: Sendable, Equatable {
    public static let image = "image"
    public static let video = "video"
    public static let audio = "audio"

    public var url: URL
    public var kind: String
    /// Alternative text. Consumer-authored: a host or a future pack writes
    /// it; no extraction path produces it yet.
    public var alt: String?
    /// Fetch-time Referer the origin demands (hotlink protection; a
    /// source's `imageReferer` stamps it). Consumers fetching the media
    /// send it; absent for most sources. Optional, so records written
    /// before it decode unchanged.
    public var referer: URL?
    /// Keys written by a newer binary, preserved verbatim.
    public var unknown: [String: ELVRawJSON]

    public init(url: URL, kind: String = Self.image, alt: String? = nil, referer: URL? = nil, unknown: [String: ELVRawJSON] = [:]) {
        self.url = url
        self.kind = kind
        self.alt = alt
        self.referer = referer
        self.unknown = unknown
    }
}

extension ELVMediaRef: Codable {
    private static let knownKeys: Set<String> = ["url", "kind", "alt", "referer"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ELVDynamicKey.self)
        url = try container.decode(URL.self, forKey: .init("url"))
        kind = try container.decode(String.self, forKey: .init("kind"))
        alt = try container.decodeIfPresent(String.self, forKey: .init("alt"))
        referer = try container.decodeIfPresent(URL.self, forKey: .init("referer"))
        unknown = try container.elvUnknownKeys(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ELVDynamicKey.self)
        try container.encode(url, forKey: .init("url"))
        try container.encode(kind, forKey: .init("kind"))
        try container.encodeIfPresent(alt, forKey: .init("alt"))
        try container.encodeIfPresent(referer, forKey: .init("referer"))
        try container.elvEncodeUnknown(unknown)
    }
}

/// A typed leaf value in an `ELVRecord`.
///
/// Additive-only: cases are never removed or reshaped. `.unknown`
/// exists from v1 so a value written by a newer binary decodes on an older
/// one — the payload is preserved verbatim and re-emitted unchanged.
public indirect enum ELVValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    /// Currency-honest money: integer minor units plus an ISO 4217 code.
    case money(minorUnits: Int64, currencyCode: String)
    case date(Date, precision: ELVDatePrecision)
    case duration(TimeInterval)
    case url(URL)
    case phone(String)
    /// Consumer-authored: a host or a future pack writes these; no
    /// extraction path produces them yet.
    case address(ELVPostalAddress)
    case geo(latitude: Double, longitude: Double)
    case media(ELVMediaRef)
    /// A rating that carries its own scale so consumers can rescale across
    /// 1–5 / 1–10 / 0–100 sources.
    case rating(value: Double, scale: ClosedRange<Double>)
    case tags([String])
    case list([Self])
    case record(ELVRecord)
    /// A value written by a newer binary. Preserved and re-emitted unchanged.
    case unknown(typeTag: String, raw: ELVRawJSON)
}

// MARK: - Emptiness

public extension ELVValue {
    /// Whether this value counts as "empty" for merge policies like
    /// `.fillEmptyOnly` (an empty string is as absent as a missing key).
    var isEmpty: Bool {
        switch self {
        case let .text(string):
            string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .tags(tags):
            tags.isEmpty
        case let .list(values):
            values.isEmpty
        default:
            false
        }
    }
}

// MARK: - Codable

extension ELVValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case minorUnits
        case currencyCode
        case epochSeconds
        case precision
        case seconds
        case address
        case media
        case latitude
        case longitude
        case scaleMin
        case scaleMax
        case values
        case record
    }

    private enum TypeTag: String {
        case text, number, money, date, duration, url, phone, address, geo, media, rating, tags, list, record
    }

    public init(from decoder: Decoder) throws {
        // The escape hatch must cover unknown *shape*, not just unknown
        // tags: a newer binary may write a bare scalar or an object
        // without "type", and either probe failing the whole record would
        // make the additive-only promise a lie. Both degrade to `.unknown`
        // with the payload preserved verbatim, exactly like an unknown tag.
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let tag = try? container.decode(String.self, forKey: .type) else {
            let raw = try decoder.singleValueContainer().decode(ELVRawJSON.self)
            self = .unknown(typeTag: "(unshaped)", raw: raw)
            return
        }
        do {
            self = try Self.decodeTagged(tag, from: container, decoder: decoder)
        } catch is DecodingError {
            // A KNOWN tag with a malformed payload (an inverted rating
            // scale, a missing key, a junk type) degrades the same way as an
            // unknown tag: one bad leaf must never discard the whole
            // record tree, and the payload is preserved verbatim.
            let raw = try decoder.singleValueContainer().decode(ELVRawJSON.self)
            self = .unknown(typeTag: tag, raw: raw)
        }
    }

    private static func decodeTagged(_ tag: String, from container: KeyedDecodingContainer<CodingKeys>, decoder: Decoder) throws -> ELVValue {
        switch TypeTag(rawValue: tag) {
        case .text:
            return try .text(container.decode(String.self, forKey: .value))
        case .number:
            return try .number(container.decode(Double.self, forKey: .value))
        case .money:
            return try .money(
                minorUnits: container.decode(Int64.self, forKey: .minorUnits),
                currencyCode: container.decode(String.self, forKey: .currencyCode)
            )
        case .date:
            return try .date(
                Date(timeIntervalSince1970: container.decode(Double.self, forKey: .epochSeconds)),
                precision: container.decode(ELVDatePrecision.self, forKey: .precision)
            )
        case .duration:
            return try .duration(container.decode(TimeInterval.self, forKey: .seconds))
        case .url:
            return try .url(container.decode(URL.self, forKey: .value))
        case .phone:
            return try .phone(container.decode(String.self, forKey: .value))
        case .address:
            return try .address(container.decode(ELVPostalAddress.self, forKey: .address))
        case .geo:
            return try .geo(
                latitude: container.decode(Double.self, forKey: .latitude),
                longitude: container.decode(Double.self, forKey: .longitude)
            )
        case .media:
            return try .media(container.decode(ELVMediaRef.self, forKey: .media))
        case .rating:
            let scaleMin = try container.decode(Double.self, forKey: .scaleMin)
            let scaleMax = try container.decode(Double.self, forKey: .scaleMax)
            guard scaleMin <= scaleMax else {
                throw DecodingError.dataCorruptedError(forKey: .scaleMax, in: container, debugDescription: "Rating scale is inverted")
            }
            return try .rating(value: container.decode(Double.self, forKey: .value), scale: scaleMin ... scaleMax)
        case .tags:
            return try .tags(container.decode([String].self, forKey: .values))
        case .list:
            return try .list(container.decode([ELVValue].self, forKey: .values))
        case .record:
            return try .record(container.decode(ELVRecord.self, forKey: .record))
        case nil:
            let raw = try decoder.singleValueContainer().decode(ELVRawJSON.self)
            return .unknown(typeTag: tag, raw: raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case let .unknown(_, raw) = self {
            var container = encoder.singleValueContainer()
            try container.encode(raw)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(string):
            try container.encode(TypeTag.text.rawValue, forKey: .type)
            try container.encode(string, forKey: .value)
        case let .number(number):
            try container.encode(TypeTag.number.rawValue, forKey: .type)
            try container.encode(number, forKey: .value)
        case let .money(minorUnits, currencyCode):
            try container.encode(TypeTag.money.rawValue, forKey: .type)
            try container.encode(minorUnits, forKey: .minorUnits)
            try container.encode(currencyCode, forKey: .currencyCode)
        case let .date(date, precision):
            try container.encode(TypeTag.date.rawValue, forKey: .type)
            try container.encode(date.timeIntervalSince1970, forKey: .epochSeconds)
            try container.encode(precision, forKey: .precision)
        case let .duration(seconds):
            try container.encode(TypeTag.duration.rawValue, forKey: .type)
            try container.encode(seconds, forKey: .seconds)
        case let .url(url):
            try container.encode(TypeTag.url.rawValue, forKey: .type)
            try container.encode(url, forKey: .value)
        case let .phone(phone):
            try container.encode(TypeTag.phone.rawValue, forKey: .type)
            try container.encode(phone, forKey: .value)
        case let .address(postalAddress):
            try container.encode(TypeTag.address.rawValue, forKey: .type)
            try container.encode(postalAddress, forKey: .address)
        case let .geo(latitude, longitude):
            try container.encode(TypeTag.geo.rawValue, forKey: .type)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
        case let .media(mediaRef):
            try container.encode(TypeTag.media.rawValue, forKey: .type)
            try container.encode(mediaRef, forKey: .media)
        case let .rating(value, scale):
            try container.encode(TypeTag.rating.rawValue, forKey: .type)
            try container.encode(value, forKey: .value)
            try container.encode(scale.lowerBound, forKey: .scaleMin)
            try container.encode(scale.upperBound, forKey: .scaleMax)
        case let .tags(tags):
            try container.encode(TypeTag.tags.rawValue, forKey: .type)
            try container.encode(tags, forKey: .values)
        case let .list(values):
            try container.encode(TypeTag.list.rawValue, forKey: .type)
            try container.encode(values, forKey: .values)
        case let .record(childRecord):
            try container.encode(TypeTag.record.rawValue, forKey: .type)
            try container.encode(childRecord, forKey: .record)
        case .unknown:
            preconditionFailure("Handled above")
        }
    }
}
