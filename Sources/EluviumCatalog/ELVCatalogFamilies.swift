import Foundation

/// Named groups of catalog source ids, so `eluvium curate --families
/// travel,floors` expands to the right sources without an app hardcoding them.
/// Derived from the chunk table (`starterPackChunks`), not a hand-maintained
/// list: a family's ids are its chunks' source ids in table order, so a chunk
/// added to the table is in the pack AND here in one edit, and sources added
/// to a chunk follow automatically. Finer selection is always available
/// through `--ids`.
public enum ELVCatalogFamilies {
    public static let families: [String: [String]] = {
        var families: [String: [String]] = [:]
        for chunk in starterPackChunks {
            families[chunk.family, default: []] += sourceIds(inChunk: chunk.json)
        }
        return families
    }()

    /// Family names, sorted — for CLI help and unknown-family errors.
    public static let known: [String] = families.keys.sorted()

    /// The source ids for a set of family names, deduped, in the order the
    /// families are given. Unknown names contribute nothing (the CLI validates
    /// against `known` before calling this).
    public static func ids(forFamilies names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            for id in families[name] ?? [] where seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    /// Extracts the `id` values from a chunk, which is a JSON fragment: source
    /// objects joined by commas with no array brackets. Wrapping in `[ … ]`
    /// makes it parseable.
    private static func sourceIds(inChunk chunk: String) -> [String] {
        let data = Data("[\(chunk)]".utf8)
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { $0["id"] as? String }
    }
}
