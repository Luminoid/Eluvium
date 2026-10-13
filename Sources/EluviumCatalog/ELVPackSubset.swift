import Foundation

/// Slices a full pack down to a chosen subset of sources, carrying exactly the
/// fragments and triggers those sources depend on. This is what `eluvium
/// curate` uses to emit an adopting app's compiled-in pack: the app links only
/// the sources it selected, never the whole catalog.
///
/// Works on the pack JSON directly (via `JSONSerialization`), not the decoded
/// model: `ELVSourcePack` is decode-only, and re-serializing the raw JSON
/// preserves the exact regex escaping the extractor relies on (the same reason
/// the opt-in pack was generated this way).
///
/// The dependency closure is exact: a source reaches pack-level tables by
/// name in only two ways — the fragment names in its `use` list, and the
/// trigger names a fetch step's `when` references. The walk follows the
/// grammar the loader resolves, no wider: `when` names a trigger only in its
/// string form on a composite plan's top-level steps (steps do not nest, and
/// a name inside `anyOf` is inert), and the steps walked are the ones that
/// run — the source's own fetch, or, when it declares none, the first `use`d
/// fragment's (a fragment's fetch never fills a source that has one).
/// Redirector `previewAs` hints keep only targets inside the subset.
/// Including every referenced fragment/trigger and no unreferenced one keeps
/// the subset free of the dangling/unused diagnostics the loader and
/// validator emit; a closure-correct subset loads clean.
///
/// The pack's `strongNamespaces` carry over filtered to the namespaces the
/// selected sources declare (source, collection, and step-scoped collection
/// identities): the strong bit is what lets those records auto-link in the
/// adopting app, and a namespace no kept source declares has nothing to link.
public enum ELVPackSubset {
    /// Returns pack JSON containing only `ids` (in their original declaration
    /// order) plus their fragment/trigger closure. Throws if any requested id
    /// is absent, so a typo surfaces instead of silently shrinking the pack.
    public static func subset(fromPackJSON data: Data, ids: Set<String>, packVersion: String? = nil) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ELVPackSubsetError.malformedPack("top level is not a JSON object")
        }
        guard let sources = root["sources"] as? [[String: Any]] else {
            throw ELVPackSubsetError.malformedPack("missing \"sources\" array")
        }

        let selected = sources.filter { ($0["id"] as? String).map(ids.contains) ?? false }
        let missing = ids.subtracting(selected.compactMap { $0["id"] as? String })
        guard missing.isEmpty else {
            throw ELVPackSubsetError.unknownSourceIds(missing.sorted())
        }

        let fragments = root["fragments"] as? [String: Any] ?? [:]
        let triggers = root["triggers"] as? [String: Any] ?? [:]

        // Fragment closure: the union of every selected source's `use`.
        var neededFragments = Set<String>()
        for source in selected {
            neededFragments.formUnion((source["use"] as? [String]) ?? [])
        }

        // Trigger closure: `when` refs from the fetch plan each selected
        // source actually runs.
        var neededTriggers = Set<String>()
        for source in selected {
            collectTriggerRefs(inFetch: effectiveFetch(of: source, fragments: fragments), into: &neededTriggers)
        }

        var result: [String: Any] = [:]
        result["schemaVersion"] = root["schemaVersion"] ?? 1
        if let minor = root["schemaMinor"] { result["schemaMinor"] = minor }
        let baseVersion = root["packVersion"] as? String ?? "0"
        result["packVersion"] = packVersion ?? "\(baseVersion)-subset"
        let keptFragments = fragments.filter { neededFragments.contains($0.key) }
        if !keptFragments.isEmpty { result["fragments"] = keptFragments }
        let keptTriggers = triggers.filter { neededTriggers.contains($0.key) }
        if !keptTriggers.isEmpty { result["triggers"] = keptTriggers }
        if let strong = root["strongNamespaces"] as? [String] {
            let declared = Set(selected.flatMap(declaredNamespaces(of:)))
            let kept = strong.filter(declared.contains)
            if !kept.isEmpty { result["strongNamespaces"] = kept }
        }
        // A redirector's preview hints name sources the subset may have
        // dropped; keep only the hints whose target came along (an absent
        // target is a dangling reference the validator would name).
        let selectedIds = Set(selected.compactMap { $0["id"] as? String })
        result["sources"] = selected.map { source -> [String: Any] in
            guard let hints = source["previewAs"] as? [String: String] else { return source }
            var pruned = source
            let kept = hints.filter { selectedIds.contains($0.value) }
            pruned["previewAs"] = kept.isEmpty ? nil : kept
            return pruned
        }

        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    /// The fetch plan the loader resolves for `source`: its own when it
    /// declares one, else the first `use`d fragment's that has one.
    private static func effectiveFetch(of source: [String: Any], fragments: [String: Any]) -> Any? {
        if let own = source["fetch"] { return own }
        for name in (source["use"] as? [String]) ?? [] {
            if let fetch = (fragments[name] as? [String: Any])?["fetch"] { return fetch }
        }
        return nil
    }

    /// Records the trigger names a composite plan's steps reference through
    /// the string form of `when`. Steps are one level deep, an inline trigger
    /// object names nothing (a string inside its `anyOf` is inert), and a
    /// single-mode plan has no steps to carry a `when`.
    private static func collectTriggerRefs(inFetch fetch: Any?, into refs: inout Set<String>) {
        guard let fetch = fetch as? [String: Any], fetch["mode"] as? String == "composite",
              let steps = fetch["steps"] as? [[String: Any]] else { return }
        for step in steps {
            if let name = step["when"] as? String { refs.insert(name) }
        }
    }

    /// Every identity namespace a source declares: its own specs, its
    /// collections', and its steps' scoped collections'.
    private static func declaredNamespaces(of source: [String: Any]) -> [String] {
        func namespaces(_ specs: Any?) -> [String] {
            ((specs as? [[String: Any]]) ?? []).compactMap { $0["ns"] as? String }
        }
        func collectionNamespaces(_ collections: Any?) -> [String] {
            ((collections as? [[String: Any]]) ?? []).flatMap { namespaces($0["identities"]) }
        }
        let steps = ((source["fetch"] as? [String: Any])?["steps"] as? [[String: Any]]) ?? []
        return namespaces(source["identities"])
            + collectionNamespaces(source["collections"])
            + steps.flatMap { collectionNamespaces($0["collections"]) }
    }
}

public enum ELVPackSubsetError: Error, Equatable {
    /// The bytes are not a pack document (no top-level object, or no `sources`).
    case malformedPack(String)
    /// Requested source ids that the pack does not contain, sorted.
    case unknownSourceIds([String])
}
