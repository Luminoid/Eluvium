import Foundation

/// 微信读书 (WeRead) notes-export reader: the text the app's own
/// 笔记 → 导出 → 复制到剪贴板 produces, saved by the user as a text file.
/// It is the only first-party export (every file-producing exporter rides
/// a logged-in cookie, which is out of scope), and it is a line grammar, not
/// CSV or JSON, so it gets a reader that turns it into item JSON for the
/// ordinary `rows` mapping, the way `ELVOPMLReader` does for OPML.
///
/// Two grammars are in circulation and both parse:
/// - **Current (2024 on)**: `《title》`, a blank line, the author, `N个笔记`;
///   a chapter is a bare line after two or more blank lines (the first
///   chapter after the header may have one); `◆ text` is a highlight whose
///   further paragraphs follow after one blank line; `◆ 2025/09/30发表想法`
///   opens a thought (its paragraphs, then `原文：` and the passage it
///   comments on, possibly twice for bilingual books); `点评` then
///   `◆ 2024/09/09 认为好看` is the reader's rating; `-- 来自微信读书` ends it.
/// - **Legacy (2020–2023)**: header lines adjacent; `◆  title` is a chapter;
///   `>> text` is a highlight (continuation lines unprefixed);
///   `2023/2/26 发表想法` opens a thought whose passage is the next `>>`.
///   The short-lived 2023 variant (`.h1 `/`.h2 ` chapters, reader links
///   after each highlight) reads as legacy with the link lines skipped.
///
/// Several books pasted back to back each restart at their own header. No
/// grammar carries a book id, positions, or highlight times; dates exist
/// only on thoughts and ratings, printed `yyyy/M/d`.
public enum ELVWeReadNotesReader {
    /// What a note records.
    public enum NoteKind: String, Sendable {
        case highlight
        case thought
        case rating
    }

    public struct Note: Sendable, Equatable {
        public var kind: NoteKind
        public var book: String
        public var author: String?
        public var chapter: String?
        /// The passage: a highlight's text, or the 原文 a thought comments on.
        public var text: String?
        /// The reader's own words: a thought, or a rating's verdict (好看,
        /// 推荐, 一般, 不行).
        public var comment: String?
        /// As printed (`yyyy/M/d`); thoughts and ratings only.
        public var date: String?

        public init(kind: NoteKind, book: String, author: String? = nil, chapter: String? = nil, text: String? = nil, comment: String? = nil, date: String? = nil) {
            self.kind = kind
            self.book = book
            self.author = author
            self.chapter = chapter
            self.text = text
            self.comment = comment
            self.date = date
        }

        /// A content key that survives re-export: the same note exported
        /// again keys identically, so a re-import dedups instead of
        /// duplicating. Editing a thought makes it a new note, which is
        /// what the export itself says happened.
        var stableId: String {
            ELVStableHash.fnv1a([kind.rawValue, book, chapter ?? "", text ?? "", comment ?? ""].joined(separator: "\u{1F}"))
        }
    }

    /// Parses export text. Nil when no `《title》` header (followed by its
    /// `N个笔记` count) appears, i.e. the text is not a WeRead export; an
    /// export with a header and no notes returns an empty list.
    public static func parse(_ text: String) -> [Note]? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var parser = Parser(lines: lines)
        return parser.run()
    }

    /// The notes as item JSON for the archive assembly path: `id` (the
    /// stable content key), `type`, `book`, `author`, `chapter`, `text`,
    /// `comment`, `date`, absent keys omitted.
    public static func itemsJSON(_ notes: [Note]) -> [ELVRawJSON] {
        notes.map { note in
            var node: [String: ELVRawJSON] = [
                "id": .string(note.stableId),
                "type": .string(note.kind.rawValue),
                "book": .string(note.book),
            ]
            node["author"] = note.author.map(ELVRawJSON.string)
            node["chapter"] = note.chapter.map(ELVRawJSON.string)
            node["text"] = note.text.map(ELVRawJSON.string)
            node["comment"] = note.comment.map(ELVRawJSON.string)
            node["date"] = note.date.map(ELVRawJSON.string)
            return .object(node)
        }
    }

    // MARK: - Grammar

    private static let countLine = regex("^[0-9]+个笔记$")
    private static let bookLine = regex("^《(.+)》$")
    private static let thoughtLine = regex("^◆?\\s*([0-9]{4}/[0-9]{1,2}/[0-9]{1,2})\\s*发表想法$")
    private static let ratingLine = regex("^◆?\\s*([0-9]{4}/[0-9]{1,2}/[0-9]{1,2})\\s*认为\\s*(.+)$")
    private static let footerPrefix = "-- 来自微信读书"

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Fixed patterns, compiled once (the static-pattern rule).
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// Capture groups of `regex` over the whole of `line`, or nil.
    private static func captures(_ regex: NSRegularExpression, in line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        return (1 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }

    /// The note the parser is still collecting lines for.
    private enum Pending {
        case none
        case highlight([String])
        case thought(date: String, comment: [String], quote: [String])
    }

    private struct Parser {
        let lines: [String]
        private var notes: [Note] = []
        private var sawHeader = false
        private var book: String?
        private var author: String?
        private var chapter: String?
        private var inHeader = false
        private var pending = Pending.none
        /// Blank lines immediately before the current line.
        private var blanks = 0
        /// Legacy grammar: `>>` highlights, `◆` chapters.
        private let legacy: Bool

        init(lines: [String]) {
            self.lines = lines
            legacy = lines.contains { $0.hasPrefix(">>") }
        }

        mutating func run() -> [Note]? {
            for (index, line) in lines.enumerated() {
                if line.isEmpty {
                    blanks += 1
                    continue
                }
                consume(line, at: index)
                blanks = 0
                // The ceiling every archive surface shares.
                if notes.count >= ELVArchiveLimits.maxTotalItems { break }
            }
            flush()
            return sawHeader ? Array(notes.prefix(ELVArchiveLimits.maxTotalItems)) : nil
        }

        private mutating func consume(_ line: String, at index: Int) {
            if line.hasPrefix(ELVWeReadNotesReader.footerPrefix) {
                flush()
                return
            }
            if let title = headerTitle(at: index) {
                flush()
                sawHeader = true
                book = title
                author = nil
                chapter = nil
                inHeader = true
                return
            }
            // Text before the first header is not part of any book.
            guard book != nil else { return }
            if inHeader {
                if ELVWeReadNotesReader.captures(ELVWeReadNotesReader.countLine, in: line) != nil {
                    inHeader = false
                } else if author == nil {
                    author = line
                }
                return
            }
            if line == "点评" || line == "◆ 点评" || line == "◆  点评" {
                flush()
                return
            }
            if let groups = ELVWeReadNotesReader.captures(ELVWeReadNotesReader.ratingLine, in: line) {
                flush()
                emit(.rating, comment: groups[1], date: groups[0])
                return
            }
            if let groups = ELVWeReadNotesReader.captures(ELVWeReadNotesReader.thoughtLine, in: line) {
                flush()
                pending = .thought(date: groups[0], comment: [], quote: [])
                return
            }
            if let passage = quoteBody(line) {
                if case let .thought(date, comment, quote) = pending {
                    pending = .thought(date: date, comment: comment, quote: quote + [passage])
                } else {
                    // An orphan 原文 still carries the passage.
                    flush()
                    pending = .highlight([passage])
                }
                return
            }
            if legacy {
                consumeLegacy(line)
            } else {
                consumeCurrent(line)
            }
        }

        /// The current grammar's body lines.
        private mutating func consumeCurrent(_ line: String) {
            if line.hasPrefix("◆") {
                flush()
                pending = .highlight([String(line.dropFirst()).trimmingCharacters(in: .whitespaces)])
                return
            }
            // A bare line after two blank lines is always a chapter.
            if blanks >= 2 {
                flush()
                chapter = line
                return
            }
            switch pending {
            case let .highlight(paragraphs):
                pending = .highlight(paragraphs + [line])
            case let .thought(date, comment, quote) where !quote.isEmpty:
                if blanks == 0 {
                    // A wrapped passage continues the last 原文 block.
                    pending = .thought(date: date, comment: comment, quote: Array(quote.dropLast()) + [(quote.last ?? "") + "\n" + line])
                } else {
                    flush()
                    chapter = line
                }
            case let .thought(date, comment, quote):
                pending = .thought(date: date, comment: comment + [line], quote: quote)
            case .none:
                chapter = line
            }
        }

        /// The legacy grammar's body lines (and the 2023 `.h1`/`.h2`
        /// variant's).
        private mutating func consumeLegacy(_ line: String) {
            if line.hasPrefix(">>") {
                let passage = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if case let .thought(date, comment, quote) = pending, quote.isEmpty {
                    pending = .thought(date: date, comment: comment, quote: [passage])
                } else {
                    flush()
                    pending = .highlight([passage])
                }
                return
            }
            if line.hasPrefix("◆") {
                flush()
                chapter = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                return
            }
            if line.hasPrefix(".h1 ") || line.hasPrefix(".h2 ") || line.hasPrefix(".h3 ") {
                flush()
                chapter = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                return
            }
            if line.hasPrefix("<http") || line.hasPrefix("https://weread.qq.com/") {
                return
            }
            switch pending {
            case let .highlight(lines):
                pending = .highlight(lines + [line])
            case let .thought(date, comment, quote) where quote.isEmpty:
                pending = .thought(date: date, comment: comment + [line], quote: quote)
            case let .thought(date, comment, quote):
                pending = .thought(date: date, comment: comment, quote: Array(quote.dropLast()) + [(quote.last ?? "") + "\n" + line])
            case .none:
                break
            }
        }

        /// The book title when `index` opens a header: `《title》` with its
        /// `N个笔记` count within the next three non-blank lines. The count
        /// is what tells a header from a highlight that is only a title.
        private func headerTitle(at index: Int) -> String? {
            guard let groups = ELVWeReadNotesReader.captures(ELVWeReadNotesReader.bookLine, in: lines[index]) else { return nil }
            let following = lines[(index + 1)...].lazy.filter { !$0.isEmpty }.prefix(3)
            guard following.contains(where: { ELVWeReadNotesReader.captures(ELVWeReadNotesReader.countLine, in: $0) != nil }) else { return nil }
            return groups[0]
        }

        /// The passage of a `原文：` line (full- or half-width colon).
        private func quoteBody(_ line: String) -> String? {
            for prefix in ["原文：", "原文:"] where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }

        private mutating func flush() {
            switch pending {
            case let .highlight(paragraphs):
                emit(.highlight, text: joined(paragraphs))
            case let .thought(date, comment, quote):
                let text = joined(quote)
                let words = joined(comment)
                if text != nil || words != nil {
                    emit(.thought, text: text, comment: words, date: date)
                }
            case .none:
                break
            }
            pending = .none
        }

        private func joined(_ parts: [String]) -> String? {
            let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        private mutating func emit(_ kind: NoteKind, text: String? = nil, comment: String? = nil, date: String? = nil) {
            guard let book else { return }
            if kind == .highlight, text == nil { return }
            notes.append(Note(kind: kind, book: book, author: author, chapter: chapter, text: text, comment: comment, date: date))
        }
    }
}
