/// A string-backed coding key for containers that mix a known key set with
/// arbitrary keys that must be preserved (record unknown-key bags) or
/// tolerated (pack objects, where unmodeled keys are ignored by contract).
struct ELVDynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ key: String) {
        stringValue = key
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

/// The unknown-key bag every round-trip type shares: `ELVRecord`, the
/// `ELVValue` leaf structs, and the entity index decode every key they do not
/// model into `[String: ELVRawJSON]` and re-emit it unchanged, so a newer
/// binary's additions survive a pass through this one.
extension KeyedDecodingContainer where Key == ELVDynamicKey {
    func elvUnknownKeys(excluding known: Set<String>) throws -> [String: ELVRawJSON] {
        var bag: [String: ELVRawJSON] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            bag[key.stringValue] = try decode(ELVRawJSON.self, forKey: key)
        }
        return bag
    }
}

extension KeyedEncodingContainer where Key == ELVDynamicKey {
    mutating func elvEncodeUnknown(_ bag: [String: ELVRawJSON]) throws {
        for (key, raw) in bag {
            try encode(raw, forKey: .init(key))
        }
    }
}
