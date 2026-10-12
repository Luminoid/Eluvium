import Foundation

/// Scalar-or-array leniency for pack lists: `"host": "imdb.com"` and
/// `"host": ["imdb.com"]` are the same declaration, because the scalar form
/// is unambiguous and the most common hand-authoring slip. Anything else
/// (an object, a mixed-type array) still throws, so structural nonsense is
/// contained by the source-level lossy decode instead of passing silently.
extension KeyedDecodingContainer {
    /// Decodes `[String]`, accepting a bare string as a one-element list.
    /// Absent key decodes to `[]`.
    func elvStringList(forKey key: Key) throws -> [String] {
        guard contains(key) else { return [] }
        if let list = try? decode([String].self, forKey: key) { return list }
        if let single = try? decode(String.self, forKey: key) { return [single] }
        throw DecodingError.typeMismatch([String].self, .init(
            codingPath: codingPath + [key],
            debugDescription: "Expected a string or an array of strings"
        ))
    }

    /// Decodes `[Int]`, accepting a bare integer as a one-element list.
    /// Absent key decodes to `[]`.
    func elvIntList(forKey key: Key) throws -> [Int] {
        guard contains(key) else { return [] }
        if let list = try? decode([Int].self, forKey: key) { return list }
        if let single = try? decode(Int.self, forKey: key) { return [single] }
        throw DecodingError.typeMismatch([Int].self, .init(
            codingPath: codingPath + [key],
            debugDescription: "Expected an integer or an array of integers"
        ))
    }
}
