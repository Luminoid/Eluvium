import Foundation

/// An arbitrary JSON value, preserved verbatim.
///
/// This is the backbone of Eluvium's forward-compatibility rules: anything a
/// decoder cannot interpret — an unknown `ELVValue` payload, an unrecognized
/// key on a persisted `ELVRecord` — is captured as `ELVRawJSON` and re-emitted
/// unchanged on encode, never dropped. Without it, a record synced
/// new-device → old-device → back would silently lose every field the old
/// binary did not understand.
public indirect enum ELVRawJSON: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])
}

// MARK: - Codable

extension ELVRawJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([ELVRawJSON].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: ELVRawJSON].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Value is not representable as JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(bool):
            try container.encode(bool)
        case let .number(number):
            try container.encode(number)
        case let .string(string):
            try container.encode(string)
        case let .array(array):
            try container.encode(array)
        case let .object(object):
            try container.encode(object)
        }
    }
}

// MARK: - Accessors

public extension ELVRawJSON {
    /// The string payload, if this is a `.string`.
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The numeric payload, if this is a `.number`.
    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// The object payload, if this is an `.object`.
    var objectValue: [String: ELVRawJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// The array payload, if this is an `.array`.
    var arrayValue: [ELVRawJSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// Member lookup on `.object`; `nil` for every other case.
    subscript(key: String) -> ELVRawJSON? {
        objectValue?[key]
    }
}
