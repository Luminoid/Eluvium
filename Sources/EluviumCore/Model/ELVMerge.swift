import Foundation

/// How stage ⑥ folds a fresh record onto an existing one of the same
/// lineage (a re-scrape, a re-import). Cross-source folding is deliberately
/// not a merge — identity linking is an overlay.
public enum ELVMergePolicy: String, Sendable, Codable, CaseIterable {
    /// Only absent or empty fields take the incoming value; user edits and
    /// earlier extractions win. The Petfolio autofill / TripDays
    /// `fillingEmpty` behavior.
    case fillEmptyOnly
    /// Incoming non-empty values win; existing values fill the gaps.
    case preferIncoming
}

public extension ELVRecord {
    /// Folds `incoming` onto this record under `policy` and returns the
    /// result. Same-lineage only: both records should carry the same
    /// `sourceId` (and `externalId` where present); the caller owns that
    /// invariant.
    ///
    /// Collection semantics: children are merged by `externalId` when both
    /// sides key every child (matching ids merge recursively, new ids
    /// append). When either side has unkeyed children there is nothing to
    /// correlate on, so the policy picks a whole collection:
    /// `.fillEmptyOnly` keeps the existing one unless it is empty,
    /// `.preferIncoming` replaces it.
    ///
    /// Identity semantics: `.fillEmptyOnly` unions both sides.
    /// `.preferIncoming` treats each namespace the incoming record declares
    /// like a field: the existing `.declared` identities in that namespace
    /// (what this same source extracted last time) give way to the incoming
    /// ones, so a corrected id replaces the stale one instead of linking
    /// both. Namespaces the incoming record does not declare keep their
    /// existing identities, and crosswalk, heuristic, and unknown-origin
    /// identities (another source's word) always stay.
    func merging(_ incoming: ELVRecord, policy: ELVMergePolicy) -> ELVRecord {
        var merged = self
        merged.formatVersion = max(formatVersion, incoming.formatVersion)

        switch policy {
        case .fillEmptyOnly:
            merged.sourceURL = sourceURL ?? incoming.sourceURL
            merged.externalId = externalId ?? incoming.externalId
            if kind.isEmpty { merged.kind = incoming.kind }
        case .preferIncoming:
            merged.sourceURL = incoming.sourceURL ?? sourceURL
            merged.externalId = incoming.externalId ?? externalId
            if !incoming.kind.isEmpty { merged.kind = incoming.kind }
        }

        for (key, value) in incoming.fields {
            let existing = fields[key]
            let takeIncoming = switch policy {
            case .fillEmptyOnly: existing == nil || existing?.isEmpty == true
            case .preferIncoming: !value.isEmpty || existing == nil
            }
            guard takeIncoming else { continue }
            merged.fields[key] = value
            merged.provenance[key] = incoming.provenance[key]
        }

        for (name, incomingChildren) in incoming.collections {
            merged.collections[name] = Self.mergeChildren(existing: collections[name] ?? [], incoming: incomingChildren, policy: policy)
        }

        if policy == .preferIncoming {
            let redeclared = Set(incoming.identities.filter { $0.origin == .declared }.map(\.namespace))
            merged.identities.removeAll { $0.origin == .declared && redeclared.contains($0.namespace) }
        }
        for identity in incoming.identities where !merged.identities.contains(identity) {
            merged.identities.append(identity)
        }

        for (key, raw) in incoming.unknown {
            switch policy {
            case .fillEmptyOnly:
                if merged.unknown[key] == nil { merged.unknown[key] = raw }
            case .preferIncoming:
                merged.unknown[key] = raw
            }
        }
        return merged
    }

    private static func mergeChildren(existing: [ELVRecord], incoming: [ELVRecord], policy: ELVMergePolicy) -> [ELVRecord] {
        let bothFullyKeyed = existing.allSatisfy { $0.externalId != nil } && incoming.allSatisfy { $0.externalId != nil }
        guard bothFullyKeyed else {
            switch policy {
            case .fillEmptyOnly: return existing.isEmpty ? incoming : existing
            case .preferIncoming: return incoming
            }
        }

        var out = existing
        var indexByExternalId: [String: Int] = [:]
        for (index, child) in out.enumerated() {
            if let id = child.externalId { indexByExternalId[id] = index }
        }
        for child in incoming {
            guard let id = child.externalId else { continue }
            if let index = indexByExternalId[id] {
                out[index] = out[index].merging(child, policy: policy)
            } else {
                indexByExternalId[id] = out.count
                out.append(child)
            }
        }
        return out
    }
}
