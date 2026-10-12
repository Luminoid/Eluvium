import Foundation

/// Archive import, stages ③–⑥ over a user-provided file. Pure and
/// offline: one child record per row/item, `externalId` dedup left to the
/// caller's merge policy.
public enum ELVArchiveImporter {
    public enum Failure: Error, Equatable {
        case unreadable
        case unsupportedFormat(String)
        /// The bytes failed the source's own file probe (never trust
        /// the extension, or the caller's source choice, alone). Carries the
        /// probe's expectation so UI can say what the file should contain.
        case formatMismatch(expected: String)
        case noRows
        /// The file exceeds the byte ceiling; carries the limit so UI can
        /// say how big is too big.
        case tooLarge(limit: Int)
    }

    /// Imports `data` through `source`, whose fetch plan declares the
    /// archive format (`csv`, `json`, `jsJson`, `opml`, `wereadNotes`;
    /// inferred from the file name when absent, except `wereadNotes`, whose
    /// `.txt` says nothing and must be declared). Files past `maxBytes` are refused before any
    /// decoding.
    ///
    /// When the source declares a file rule with a content probe, the probe
    /// runs against the file head before any assembly: the caller chose the
    /// source, but the content still has to look like what that source
    /// ingests. Name-glob matching stays `ELVFileRecognizer`'s job — the
    /// caller's file name may be arbitrary; the bytes may not.
    ///
    /// Logs one outcome line: a notice with the source, format, row counts
    /// (rows read and records assembled, so dropped rows show), byte count,
    /// and duration; an error on failure. The file name is user input and
    /// stays in private detail.
    public static func importRecords(source: ELVSource, fileName: String, data: Data, maxBytes: Int = ELVArchiveLimits.maxImportBytes) throws -> [ELVRecord] {
        let started = ContinuousClock.now
        let format = source.fetch?.resolvedSteps.first?.format ?? inferFormat(fileName: fileName)
        do {
            let imported = try importBody(source: source, data: data, maxBytes: maxBytes, format: format)
            let elapsed = ELVLogFormat.milliseconds(ContinuousClock.now - started)
            ELVLog.notice(
                .importer,
                "Imported source=\(source.id) format=\(format) records=\(imported.records.count) of \(imported.scanned) rows bytes=\(data.count) in \(elapsed)ms",
                private: "file=\(fileName)"
            )
            return imported.records
        } catch {
            let elapsed = ELVLogFormat.milliseconds(ContinuousClock.now - started)
            ELVLog.error(.importer, "Import failed source=\(source.id) format=\(format) bytes=\(data.count) in \(elapsed)ms", private: "file=\(fileName)", error: error)
            throw error
        }
    }

    /// The import itself; `scanned` counts the rows or items read, so the
    /// log can say how many assembled to nothing.
    private static func importBody(source: ELVSource, data: Data, maxBytes: Int, format: String) throws -> (records: [ELVRecord], scanned: Int) {
        guard data.count <= maxBytes else { throw Failure.tooLarge(limit: maxBytes) }
        guard !data.isEmpty else { throw Failure.unreadable }
        if let rule = source.match?.file, let expected = ELVFileRecognizer.probeFailure(rule, head: ELVFileRecognizer.probeHead(of: data)) {
            throw Failure.formatMismatch(expected: expected)
        }
        if format == "json" || format == "jsJson" {
            return try importJSON(source: source, data: data, format: format)
        }
        guard let text = ELVFileRecognizer.decode(data) else { throw Failure.unreadable }

        switch format {
        case "csv":
            // The item ceiling applies to every import surface: without it a
            // pathological input grows one in-memory array without bound.
            guard let table = ELVCSVReader.parse(text, maxRows: ELVArchiveLimits.maxTotalItems) else { throw Failure.unreadable }
            let context = ELVExtractionContext()
            let records = table.rows.compactMap { ELVAssembler.assembleRow(source: source, row: $0, context: context) }
            guard !records.isEmpty else { throw Failure.noRows }
            return (records, table.rows.count)
        case "opml":
            guard let subscriptions = ELVOPMLReader.parse(text) else { throw Failure.formatMismatch(expected: "<opml") }
            let items = ELVOPMLReader.itemsJSON(subscriptions)
            let records = items.compactMap { ELVAssembler.assembleItem(source: source, itemJSON: $0) }
            guard !records.isEmpty else { throw Failure.noRows }
            return (records, items.count)
        case "wereadNotes":
            guard let notes = ELVWeReadNotesReader.parse(text) else { throw Failure.formatMismatch(expected: "《title》 header with its N个笔记 count") }
            let items = ELVWeReadNotesReader.itemsJSON(notes)
            let records = items.compactMap { ELVAssembler.assembleItem(source: source, itemJSON: $0) }
            guard !records.isEmpty else { throw Failure.noRows }
            return (records, items.count)
        default:
            throw Failure.unsupportedFormat(format)
        }
    }

    /// A JSON or `.js`-wrapped JSON export. The items are what the source's
    /// `list.items` json selector picks (`$.items[*]` for a
    /// `{"items": [...]}` export), the same selector a paginated list of the
    /// same shape uses; without one, a root array's elements or the root
    /// object itself. Plain JSON parses straight from the bytes.
    private static func importJSON(source: ELVSource, data: Data, format: String) throws -> (records: [ELVRecord], scanned: Int) {
        let root: ELVRawJSON?
        if format == "jsJson" {
            guard let text = ELVFileRecognizer.decode(data) else { throw Failure.unreadable }
            root = ELVJSJSONReader.parse(text)
        } else {
            root = ELVRawJSON.parse(data)
        }
        guard let root else { throw Failure.unreadable }
        let selected: [ELVRawJSON] = if case let .json(path)? = source.list?.items {
            ELVJSONPath(path).evaluate(root)
        } else {
            root.arrayValue ?? [root]
        }
        // Same ceiling as `parseShards`: the single-document path must not
        // be the uncapped back door.
        let items = selected.prefix(ELVArchiveLimits.maxTotalItems)
        let records = items.compactMap { ELVAssembler.assembleItem(source: source, itemJSON: $0) }
        guard !records.isEmpty else { throw Failure.noRows }
        return (records, items.count)
    }

    static func inferFormat(fileName: String) -> String {
        let lowered = fileName.lowercased()
        if lowered.hasSuffix(".csv") { return "csv" }
        if lowered.hasSuffix(".js") { return "jsJson" }
        if lowered.hasSuffix(".json") { return "json" }
        if lowered.hasSuffix(".opml") { return "opml" }
        return "unknown"
    }
}
