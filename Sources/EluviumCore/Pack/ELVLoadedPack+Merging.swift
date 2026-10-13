import Foundation

/// Composing a built-in pack with a downloaded one ("newer of (bundled,
/// downloaded) wins", ordered by `ELVPackVersion`). A flat registry concat would be wrong — priority
/// dominates declaration order, id→source maps are per-pack, and generic
/// floors / file / seed sources live outside the registry — so the merge
/// unions the active sources and re-derives every lookup structure through the
/// normal `ELVLoadedPack` initializer.
public extension ELVLoadedPack {
    /// Layers `overlay` over `self`: on a shared source id the overlay wins,
    /// base order is preserved with overlay-only sources appended. Registry,
    /// generic floors, file / seed / enumerable rosters, and the id index
    /// all re-derive from the merged source set, and the strong namespaces
    /// are the union of both layers (append-only). The returned pack's
    /// `pack` metadata (notably `packVersion`) is the overlay's; behavior
    /// comes from `sources` / `registry` / `recognize`.
    ///
    /// An overlay older than `self` (`ELVPackVersion.compare`) is refused:
    /// the result is `self`, unchanged, so a stale download can never roll
    /// back a newer bundled pack (the newer of bundled and downloaded
    /// wins). An equal version still layers.
    func merging(_ overlay: ELVLoadedPack) -> ELVLoadedPack {
        guard ELVPackVersion.compare(overlay.pack.packVersion, pack.packVersion) != .orderedAscending else { return self }
        let overlayById = Dictionary(overlay.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var mergedSources: [ELVSource] = []
        var activeIds = Set<String>()
        for source in sources {
            mergedSources.append(overlayById[source.id] ?? source)
            activeIds.insert(source.id)
        }
        for source in overlay.sources where activeIds.insert(source.id).inserted {
            mergedSources.append(source)
        }

        // Skips are informational: union both, overlay's reason wins on a
        // shared id, and drop any id that is active after the merge.
        var mergedSkipped: [ELVSkippedSource] = []
        var seenSkips = Set<String>()
        for skip in overlay.skipped + skipped where !activeIds.contains(skip.id) && seenSkips.insert(skip.id).inserted {
            mergedSkipped.append(skip)
        }

        return ELVLoadedPack(
            pack: overlay.pack,
            sources: mergedSources,
            skipped: mergedSkipped,
            capabilities: capabilities,
            diagnostics: diagnostics + overlay.diagnostics,
            strongNamespaces: strongNamespaces.union(overlay.strongNamespaces)
        )
    }
}
