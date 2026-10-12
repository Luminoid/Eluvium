import EluviumCore
import Foundation

/// On-disk cache for a downloaded pack ("atomic replace into Application
/// Support"). Stores the signed envelope, not the bare payload, and
/// re-verifies it on load — so a tampered cache file can never reach the
/// loader, keeping the trust boundary intact across launches. This enables an
/// offline launch: load the built-in subset plus the cached downloaded pack and
/// merge.
///
/// Beside the envelope and its ETag the store keeps the `packVersion` of the
/// last pack it accepted: the rollback floor `ELVRemotePackService` refuses
/// to go below, so a stale CDN edge or a replayed older (validly signed)
/// pack cannot downgrade sources.
public struct ELVRemotePackStore: Sendable {
    private let directory: URL
    private let envelopeURL: URL
    private let etagURL: URL
    private let versionURL: URL

    /// `directory` is a caller-owned location — typically an Application
    /// Support subdirectory.
    public init(directory: URL) {
        self.directory = directory
        envelopeURL = directory.appendingPathComponent("pack.envelope.json")
        etagURL = directory.appendingPathComponent("pack.etag")
        versionURL = directory.appendingPathComponent("pack.version")
    }

    /// The stored ETag for the next conditional GET, or nil.
    public var etag: String? {
        Self.readTrimmed(etagURL)
    }

    /// The `packVersion` of the last pack this store accepted, or nil when
    /// none was recorded: the floor a refresh refuses to go below.
    public var packVersion: String? {
        Self.readTrimmed(versionURL)
    }

    /// Atomically persists the verified envelope, its ETag, and the version
    /// of the pack it carries, creating the directory if needed.
    /// `Data.write(options: .atomic)` writes to a temporary file and
    /// renames, so a crash mid-write never leaves a partial pack; the
    /// version is written last, so a crash between writes leaves the floor
    /// at or below the cached pack, never above it. A response without an
    /// ETag clears the stored one: a stale tag would otherwise ride the
    /// next conditional GET against an envelope it never described.
    public func save(envelope: Data, etag: String?, packVersion: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try envelope.write(to: envelopeURL, options: .atomic)
        if let etag, !etag.isEmpty {
            try Data(etag.utf8).write(to: etagURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: etagURL.path) {
            try FileManager.default.removeItem(at: etagURL)
        }
        try Data(packVersion.utf8).write(to: versionURL, options: .atomic)
    }

    /// Reads the cached envelope and re-verifies it against `keys` before
    /// loading. Returns nil when no cache file exists; a file that is
    /// present but unreadable, undecodable, tampered, or unloadable throws,
    /// so a corrupt cache surfaces instead of masquerading as "no cache".
    /// A cache that fails to load logs an error line (the path stays
    /// private) before the error rethrows.
    ///
    /// `bundledVersion` is the `packVersion` of the pack compiled into the
    /// app. A cached pack older than it is obsolete (an app update shipped
    /// newer sources than the last download), so it is discarded and nil
    /// returned: the envelope is deleted, the ETag kept (a 304 for the same
    /// stale resource then costs nothing), and the rollback floor raised to
    /// the bundled version, so a refresh never re-accepts that pack.
    public func loadCached(keys: ELVPackKeySet, capabilities: ELVCapabilities = .core, bundledVersion: String? = nil) throws -> ELVLoadedPack? {
        guard FileManager.default.fileExists(atPath: envelopeURL.path) else { return nil }
        let loaded: ELVLoadedPack
        do {
            let data = try Data(contentsOf: envelopeURL)
            let envelope = try JSONDecoder().decode(ELVPackEnvelope.self, from: data)
            let verified = try ELVPackVerifier.verify(envelope, keys: keys, failureLevel: .debug)
            loaded = try ELVPackLoader.load(verified, capabilities: capabilities, failureLevel: .debug)
        } catch {
            ELVLog.error(.remote, "Cached remote pack failed to load", private: "path=\(envelopeURL.path)", error: error)
            throw error
        }
        guard let bundledVersion, ELVPackVersion.compare(loaded.pack.packVersion, bundledVersion) == .orderedAscending else {
            return loaded
        }
        try discardCache(raisingFloorTo: bundledVersion)
        ELVLog.notice(.remote, "Cached remote pack version=\(loaded.pack.packVersion) is older than bundled=\(bundledVersion); discarded")
        return nil
    }

    /// Removes the cached envelope, ETag, and recorded version (e.g. on key
    /// rotation or a forced reset).
    public func clear() {
        try? FileManager.default.removeItem(at: envelopeURL)
        try? FileManager.default.removeItem(at: etagURL)
        try? FileManager.default.removeItem(at: versionURL)
    }

    // MARK: - Helpers

    /// Drops an obsolete cached envelope and lifts the rollback floor to
    /// `version`, never lowering it.
    private func discardCache(raisingFloorTo version: String) throws {
        try FileManager.default.removeItem(at: envelopeURL)
        if let floor = packVersion, ELVPackVersion.compare(floor, version) != .orderedAscending { return }
        try Data(version.utf8).write(to: versionURL, options: .atomic)
    }

    private static func readTrimmed(_ url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
