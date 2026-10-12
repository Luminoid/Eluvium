import EluviumCore
import Foundation
import UniformTypeIdentifiers

/// Where a recognized file imports: one of the three app-authored demos, or
/// one of the loaded pack's own file sources (`ELVLoadedPack.fileSources`).
enum ImportTarget: Equatable {
    case demo(ImportDemo)
    case catalog(ELVSource)
}

/// Reads a picked or dropped archive file off the main thread and
/// recognizes which source it belongs to (stage ① over a file: name
/// glob plus content probe), so the Imports screen only ever receives a
/// typed outcome. The size cap is checked through `fileSizeKey` before any
/// bytes load.
enum ImportFileReader {
    /// What reading a file produced.
    enum Outcome {
        /// The decoded text and the source that recognized the file.
        case text(String, target: ImportTarget)
        case tooLarge
        case unreadable
    }

    /// Refusal ceiling for picked files; a personal-archive export is
    /// kilobytes to a few megabytes, so anything past this is not one.
    static let maxImportBytes = 20 * 1024 * 1024

    /// The cap spelled for people, formatted from the one constant so the
    /// copy and the check can never disagree.
    static let maxImportBytesDescription: String = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useMB
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(maxImportBytes))
    }()

    /// What the document picker and the drop target accept: the demo formats
    /// (CSV, jsJson, OPML) and the catalog's (iNaturalist and eBird CSVs,
    /// the 微信读书 `.txt` export). `.text` covers plain text and the script
    /// shards; OPML has no builtin type, so one is derived from its extension.
    static let importableTypes: [UTType] = {
        var types: [UTType] = [.commaSeparatedText, .plainText, .text, .json, .xml]
        if let opml = UTType(filenameExtension: "opml") { types.append(opml) }
        return types
    }()

    /// Recognition order: the three demos first (their sources are the
    /// screen's own), then the pack's file sources. An unrecognized file
    /// stays on the Flighty demo so the mismatch surfaces as its typed
    /// failure copy instead of a silent no-op.
    static func target(fileName: String, data: Data, catalogSources: [ELVSource]) -> ImportTarget {
        let recognized = ELVFileRecognizer.recognize(fileName: fileName, data: data, sources: ImportDemo.recognizableSources + catalogSources)
        if let demo = ImportDemo.allCases.first(where: { $0.source.id == recognized?.id }) {
            return .demo(demo)
        }
        if let recognized {
            return .catalog(recognized)
        }
        return .demo(.flighty)
    }

    /// Detached: file IO, the lossy decode, and the recognizer's content
    /// probe never touch the main thread. Lossy UTF-8 matches
    /// `ELVFileRecognizer`'s replacement-character stance (a strict decode
    /// would throw whole files away over one bad byte).
    static func read(at url: URL, catalogSources: [ELVSource]) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // A size the system can't report is refused, not waved through:
            // the cap exists to keep arbitrary picks from loading whole.
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxImportBytes else {
                return Outcome.tooLarge
            }
            guard let data = try? Data(contentsOf: url) else { return Outcome.unreadable }
            let target = target(fileName: url.lastPathComponent, data: data, catalogSources: catalogSources)
            // swiftlint:disable:next optional_data_string_conversion
            return Outcome.text(String(decoding: data, as: UTF8.self), target: target)
        }.value
    }

    // MARK: - Drops

    /// The first importable type a dropped item offers, if any.
    static func importableTypeIdentifier(of provider: NSItemProvider) -> String? {
        importableTypes.first { provider.hasItemConformingToTypeIdentifier($0.identifier) }?.identifier
    }

    /// Copies a dropped file somewhere it outlives the provider's callback
    /// (the system deletes its own copy when the callback returns), keeping
    /// the file name: recognition globs on it (`tweets*.js`, `*.csv`). Nil
    /// when the item has no file or the copy fails. Pair with
    /// `discardStagedDrop(_:)` once the read is done. Runs on the caller's
    /// executor (the provider is not Sendable); the copy itself happens on
    /// the provider's queue.
    static func stageDrop(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { continuation in
            loadDrop(from: provider, typeIdentifier: typeIdentifier) { continuation.resume(returning: $0) }
        }
    }

    /// Removes a `stageDrop` copy and its private folder.
    static func discardStagedDrop(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Formed in a nonisolated static context: the provider calls back on
    /// its own queue, and a closure formed in MainActor code would inherit
    /// that isolation and trap there.
    private nonisolated static func loadDrop(from provider: NSItemProvider, typeIdentifier: String, completion: @escaping @Sendable (URL?) -> Void) {
        _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            guard let url else {
                completion(nil)
                return
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportDrops", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            let staged = folder.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: staged)
                completion(staged)
            } catch {
                completion(nil)
            }
        }
    }
}
