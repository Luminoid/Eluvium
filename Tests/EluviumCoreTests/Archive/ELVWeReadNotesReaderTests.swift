import Foundation
import Testing
@testable import EluviumCore

/// The 微信读书 notes export: both grammars the app has printed,
/// built from real exports (the current one since 2024, the legacy `>>`
/// one from 2020–2023), parsed into notes and imported through the archive
/// path.
@Suite("WeRead notes reader")
struct ELVWeReadNotesReaderTests {
    /// The current grammar: blank-line framing, `◆` highlights, a dated
    /// thought with its 原文 (twice, a bilingual book), a multi-paragraph
    /// highlight, chapters after two blank lines, the 点评 rating, the footer.
    static let current = """
    《逊色：科学对女性做错了什么》

    安吉拉·萨伊尼
    22个笔记

    点评

    ◆ 2025/09/30 认为好看

    献辞页

    ◆ 2025/09/30发表想法

    原文：For my boys, Mukul and Aneurin

    原文：献给我的丈夫穆库尔，以及儿子安奈林


    导言

    ◆ 当我们想象早期人类的生活时，

    往往会想到男性狩猎。

    ◆ “这些来自学院的调查参与者，”


    第一章 女性逊色于男性

    ◆ 2025/09/30发表想法

    他的进化论理念或许是革命性的，但对女性的态度却是顽固的维多利亚式的。

    原文：达尔文在私人信件中所说的话
    与他的公开著作并不一致

    ◆ 他的进化论理念或许是革命性的，

    -- 来自微信读书
    """

    /// The legacy grammar: adjacent header lines, `◆  ` chapters, `>>`
    /// highlights with unprefixed continuation lines, an undashed thought.
    static let legacy = """
    《黑客与画家（10万册纪念版）》
    保罗·格雷厄姆
    2个笔记


    ◆  第二部分 黑客如何工作及影响世界

    >> Viaweb不是这样。

    ◆  我，以及其他的证人

    2023/2/26 发表想法
    为自己的日子，在自己的脸上留下伤口
    >> 为自己的日子
    在自己的脸上留下伤口
    """

    @Test
    func `The current grammar yields highlights, thoughts, and the rating with their chapters`() throws {
        let notes = try #require(ELVWeReadNotesReader.parse(Self.current))
        #expect(notes.allSatisfy { $0.book == "逊色：科学对女性做错了什么" && $0.author == "安吉拉·萨伊尼" })
        #expect(notes.map(\.kind) == [.rating, .thought, .highlight, .highlight, .thought, .highlight])

        let rating = notes[0]
        #expect(rating.comment == "好看")
        #expect(rating.date == "2025/09/30")

        // An empty thought still carries its passage; two 原文 blocks join.
        let dedication = notes[1]
        #expect(dedication.chapter == "献辞页")
        #expect(dedication.comment == nil)
        #expect(dedication.text == "For my boys, Mukul and Aneurin\n献给我的丈夫穆库尔，以及儿子安奈林")

        // A one-blank paragraph continues the highlight; two blanks open a chapter.
        #expect(notes[2].chapter == "导言")
        #expect(notes[2].text == "当我们想象早期人类的生活时，\n往往会想到男性狩猎。")
        #expect(notes[3].text == "“这些来自学院的调查参与者，”")

        let thought = notes[4]
        #expect(thought.chapter == "第一章 女性逊色于男性")
        #expect(thought.comment == "他的进化论理念或许是革命性的，但对女性的态度却是顽固的维多利亚式的。")
        #expect(thought.text == "达尔文在私人信件中所说的话\n与他的公开著作并不一致")
        #expect(thought.date == "2025/09/30")
        #expect(notes[5].chapter == "第一章 女性逊色于男性")
    }

    @Test
    func `The legacy grammar yields chapters from diamonds and thoughts from their next passage`() throws {
        let notes = try #require(ELVWeReadNotesReader.parse(Self.legacy))
        #expect(notes.count == 2)
        #expect(notes[0].kind == .highlight)
        #expect(notes[0].book == "黑客与画家（10万册纪念版）")
        #expect(notes[0].author == "保罗·格雷厄姆")
        #expect(notes[0].chapter == "第二部分 黑客如何工作及影响世界")
        #expect(notes[0].text == "Viaweb不是这样。")
        #expect(notes[1].kind == .thought)
        #expect(notes[1].chapter == "我，以及其他的证人")
        #expect(notes[1].comment == "为自己的日子，在自己的脸上留下伤口")
        // A continuation line with no prefix stays part of the passage.
        #expect(notes[1].text == "为自己的日子\n在自己的脸上留下伤口")
        #expect(notes[1].date == "2023/2/26")
    }

    @Test
    func `Books pasted back to back each restart at their own header, CRLF and object marks included`() throws {
        let second = "《活着》\r\n\r\n余华\r\n1个笔记\r\n\r\n第一章\r\n\r\n◆ 人是为活着本身而活着\u{FFFC}\r\n"
        let notes = try #require(ELVWeReadNotesReader.parse(Self.current + "\n\n" + second))
        let last = try #require(notes.last)
        #expect(last.book == "活着")
        #expect(last.author == "余华")
        #expect(last.chapter == "第一章")
        #expect(last.text == "人是为活着本身而活着")
    }

    @Test
    func `Text that is not an export is refused, and a title-only highlight is not a header`() throws {
        #expect(ELVWeReadNotesReader.parse("just some notes\n◆ a line") == nil)
        #expect(ELVWeReadNotesReader.parse("") == nil)
        // 《三体》 alone inside a book is a highlight, not a new book: no count follows.
        let text = "《活着》\n\n余华\n2个笔记\n\n第一章\n\n◆ 他提到了\n\n《三体》\n"
        let notes = try #require(ELVWeReadNotesReader.parse(text))
        #expect(notes.map(\.book) == ["活着"])
        #expect(notes.first?.text == "他提到了\n《三体》")
    }

    @Test
    func `Item JSON keys every note by content, so a re-export keys identically`() throws {
        let first = try ELVWeReadNotesReader.itemsJSON(#require(ELVWeReadNotesReader.parse(Self.current)))
        let again = try ELVWeReadNotesReader.itemsJSON(#require(ELVWeReadNotesReader.parse(Self.current)))
        #expect(first == again)
        let ids = first.compactMap { $0["id"]?.stringValue }
        #expect(ids.count == first.count)
        #expect(Set(ids).count == ids.count)
        #expect(first[1]["type"]?.stringValue == "thought")
        #expect(first[0]["text"] == nil)
    }

    @Test
    func `The importer runs the wereadNotes format through a source's rows`() throws {
        let source = ELVSource(
            id: "weread.notes.test",
            kind: "note",
            match: ELVMatchRule(file: ELVFileMatchRule(name: "*", contains: ["《", "个笔记"])),
            fetch: ELVFetchPlan(mode: "archive", format: "wereadNotes"),
            rows: [
                ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.id"))]),
                ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.comment")), ELVCandidate(from: .json("$.text"))]),
                ELVFieldSpec(name: "chapter", candidates: [ELVCandidate(from: .json("$.chapter"))]),
                ELVFieldSpec(name: "date", candidates: [ELVCandidate(from: .json("$.date"), coercion: ELVCoercion(kind: "date", format: "yyyy/M/d"))]),
            ]
        )
        let records = try ELVArchiveImporter.importRecords(source: source, fileName: "逊色.txt", data: Data(Self.legacy.utf8))
        #expect(records.count == 2)
        #expect(records[0].fields["title"] == .text("Viaweb不是这样。"))
        #expect(records[1].fields["title"] == .text("为自己的日子，在自己的脸上留下伤口"))
        guard case .date? = records[1].fields["date"] else {
            Issue.record("expected a parsed date, got \(String(describing: records[1].fields["date"]))")
            return
        }
        #expect(records.allSatisfy { $0.externalId?.isEmpty == false })
        // The content probe still guards the format: other text is a mismatch.
        #expect(throws: ELVArchiveImporter.Failure.self) {
            _ = try ELVArchiveImporter.importRecords(source: source, fileName: "x.txt", data: Data("hello".utf8))
        }
    }
}
