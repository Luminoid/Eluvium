import Foundation

/// Quote-aware, header-keyed CSV parsing (RFC 4180 tolerant: quoted fields,
/// `""` escapes, embedded commas and newlines, CRLF or LF line endings).
public enum ELVCSVReader {
    public struct Table: Sendable, Equatable {
        public var headers: [String]
        /// Header-keyed rows; short rows simply omit trailing keys.
        public var rows: [[String: String]]
    }

    public static func parse(_ text: String, maxRows: Int? = nil) -> Table? {
        // `maxRows` caps data rows; the header record rides on top of it, so
        // the parse itself stops materializing past the ceiling.
        let records = parseRecords(text, maxRecords: maxRows.map { $0 + 1 })
        guard let headers = records.first, !headers.isEmpty else { return nil }
        let rows = records.dropFirst().compactMap { record -> [String: String]? in
            guard !(record.count == 1 && record[0].isEmpty) else { return nil }
            var row: [String: String] = [:]
            for (index, header) in headers.enumerated() where index < record.count {
                row[header] = record[index]
            }
            return row
        }
        return Table(headers: headers, rows: rows)
    }

    /// The raw record grid, no header interpretation.
    static func parseRecords(_ text: String) -> [[String]] {
        parseRecords(text, maxRecords: nil)
    }

    /// The header row alone: parses only the first record (quoted headers may
    /// span lines), so probing an archive costs one row, not a document scan.
    /// Returns nil for an empty document or a blank first line.
    static func parseHeaders(_ text: String) -> [String]? {
        guard let first = parseRecords(text, maxRecords: 1).first,
              !first.isEmpty, !(first.count == 1 && first[0].isEmpty) else { return nil }
        return first
    }

    /// Single-pass scan over the UTF-8 bytes with index arithmetic, over the
    /// string's own storage when it is contiguous (native strings) and over
    /// one copy otherwise. A grapheme-cluster walk (`text[index]` per
    /// Character) is orders of magnitude slower on multi-MB archives. The
    /// structural bytes (quote, comma, CR, LF) are ASCII and can never occur
    /// inside a multi-byte UTF-8 scalar, so byte comparison is exact; field
    /// content is rebuilt from byte slices via `String(decoding:)`, which
    /// keeps multi-byte content intact.
    private static func parseRecords(_ text: String, maxRecords: Int?) -> [[String]] {
        text.utf8.withContiguousStorageIfAvailable { scanRecords($0, maxRecords: maxRecords) }
            ?? scanRecords(Array(text.utf8), maxRecords: maxRecords)
    }

    private static func scanRecords<Bytes: RandomAccessCollection>(_ bytes: Bytes, maxRecords: Int?) -> [[String]] where Bytes.Element == UInt8, Bytes.Index == Int {
        let quote: UInt8 = 0x22, comma: UInt8 = 0x2C, carriageReturn: UInt8 = 0x0D, lineFeed: UInt8 = 0x0A
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var pieceStart = bytes.startIndex
        var inQuotes = false
        var index = bytes.startIndex

        // Appends the pending byte run [pieceStart, end) to the field. The
        // non-failable decode is deliberate: the slice came from a valid
        // String's own UTF-8 view, so it can never contain invalid UTF-8.
        func flushPiece(upTo end: Int) {
            guard end > pieceStart else { return }
            // swiftlint:disable:next optional_data_string_conversion
            field += String(decoding: bytes[pieceStart ..< end], as: UTF8.self)
        }

        while index < bytes.endIndex {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    flushPiece(upTo: index)
                    if index + 1 < bytes.endIndex, bytes[index + 1] == quote {
                        field.append("\"")
                        index += 2
                    } else {
                        inQuotes = false
                        index += 1
                    }
                    pieceStart = index
                } else {
                    index += 1
                }
            } else {
                switch byte {
                case quote:
                    flushPiece(upTo: index)
                    inQuotes = true
                    index += 1
                    pieceStart = index
                case comma:
                    flushPiece(upTo: index)
                    record.append(field)
                    field = ""
                    index += 1
                    pieceStart = index
                case carriageReturn, lineFeed:
                    flushPiece(upTo: index)
                    record.append(field)
                    field = ""
                    records.append(record)
                    record = []
                    // CRLF is one line ending, not two; lone CR (old Mac)
                    // and lone LF each end a record on their own.
                    index += byte == carriageReturn && index + 1 < bytes.endIndex && bytes[index + 1] == lineFeed ? 2 : 1
                    pieceStart = index
                    if let maxRecords, records.count >= maxRecords { return records }
                default:
                    index += 1
                }
            }
        }
        flushPiece(upTo: bytes.endIndex)
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}

/// The `jsJson` archive format: a JS assignment wrapping a JSON
/// literal — `window.YTD.tweets.part0 = [ … ];`. Strip the prefix, parse,
/// concatenate `partN` shards into one list (the Twitter archive's entire
/// `data/` folder reads this way).
public enum ELVJSJSONReader {
    // The assignment prefix, a fixed pattern compiled once (the
    // static-pattern rule); it runs per shard.
    // swiftlint:disable:next force_try
    private static let assignmentRegex = try! NSRegularExpression(pattern: "^[\\w$][\\w$.\\[\\]\"']{0,200}?\\s*=\\s*")

    public static func parse(_ text: String) -> ELVRawJSON? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = Substring(source)
        if let match = assignmentRegex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
           let range = Range(match.range, in: source) {
            body = source[range.upperBound...]
        }
        var trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ELVRawJSON.parse(Data(trimmed.utf8))
    }

    /// Parses each shard and concatenates their top-level arrays in order,
    /// stopping at `ELVArchiveLimits.maxTotalItems`.
    public static func parseShards(_ shards: [String]) -> ELVRawJSON? {
        var combined: [ELVRawJSON] = []
        for shard in shards {
            if combined.count >= ELVArchiveLimits.maxTotalItems { break }
            guard let parsed = parse(shard) else { return nil }
            if let array = parsed.arrayValue {
                combined.append(contentsOf: array.prefix(ELVArchiveLimits.maxTotalItems - combined.count))
            } else {
                combined.append(parsed)
            }
        }
        return .array(combined)
    }
}
