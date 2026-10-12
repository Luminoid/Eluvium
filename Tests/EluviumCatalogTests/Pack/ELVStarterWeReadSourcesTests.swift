import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The 微信读书 trio (2026-10-10): book pages and the app's share link,
/// shared 想法/书评 over the public review JSON, and the notes export file.
@Suite("Starter pack WeRead sources")
struct ELVStarterWeReadSourcesTests {
    private func loaded() throws -> ELVLoadedPack {
        try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
    }

    private func assemble(_ url: String, document: ELVDocument) throws -> ELVRecord {
        let pack = try loaded()
        let target = try #require(URL(string: url))
        let recognition = try #require(pack.registry.recognize(target), "\(url) did not recognize")
        let source = try #require(pack.source(withId: recognition.sourceId))
        let canonical = source.canonicalize?.apply(to: target) ?? target
        return ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: canonical, params: recognition.params, document: document))
    }

    @Test
    func `Book pages, reader pages, the app's share link, and shared notes recognize`() throws {
        let cases: [(url: String, sourceId: String)] = [
            ("https://weread.qq.com/web/bookDetail/ce032b305a9bc1ce0b0dd2a", "weread.book"),
            ("https://weread.qq.com/web/reader/8bc329705e46708bcb0c164", "weread.book"),
            ("https://weread.qq.com/web/reader/8bc329705e46708bcb0c164k16732dc0161679091c5aeb1", "weread.book"),
            ("https://weread.qq.com/book-detail?type=1&v=d4a322a05d0f04d4a01f0d6&senderVid=123&wvid=456", "weread.book"),
            ("https://weread.qq.com/web/review/detail/2100205_73IB5RiZD", "weread.review"),
        ]
        let registry = try loaded().registry
        for (url, sourceId) in cases {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target)?.sourceId == sourceId, "\(url)")
        }
        for url in ["https://weread.qq.com.evil.cn/web/bookDetail/ce032b305a9bc1ce0b0dd2a", "https://weread.qq.com/web/shelf"] {
            let target = try #require(URL(string: url))
            #expect(registry.recognize(target) == nil, "\(url)")
        }
    }

    @Test
    func `The share link drops the sharer's ids and fetches the book's detail page`() throws {
        let source = try #require(try loaded().source(withId: "weread.book"))
        let share = try #require(URL(string: "https://weread.qq.com/book-detail?type=1&v=d4a322a05d0f04d4a01f0d6&senderVid=11&wtheme=white&wfrom=app&wvid=22&scene=bottomSheetShare"))
        let canonical = try #require(source.canonicalize?.apply(to: share))
        let query = URLComponents(url: canonical, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name).sorted()
        #expect(query == ["type", "v"])
        let steps = try #require(source.fetch?.resolvedSteps)
        // Exactly one step answers each shape.
        #expect(steps.map { $0.when?.urlPermits(canonical) ?? true } == [false, true])
        let template = try #require(steps.last?.url)
        #expect(ELVURLTemplate.fillInput(template, from: canonical) == "https://weread.qq.com/web/bookDetail/d4a322a05d0f04d4a01f0d6")
    }

    @Test
    func `A book page assembles from its JSON-LD, with ISBN as a strong identity only when present`() throws {
        func page(isbn: String) -> ELVDocument {
            ELVDocument(html: """
            <html><head>
            <meta property="og:title" content="活着"><meta property="og:description" content="《活着》讲述了农村人福贵悲惨的人生遭遇。">
            <meta property="og:image" content="https://cdn.weread.qq.com/weread/cover/22/YueWen_834464/t6_YueWen_834464.jpg">
            <script type="application/ld+json">{"@context":"http://schema.org","@Id":"834464","@type":"Book","name":"活着",
            "author":{"@context":"http://schema.org","@type":"Person","name":"余华"},"isbn":"\(isbn)"}</script>
            </head><body></body></html>
            """)
        }
        let record = try assemble("https://weread.qq.com/web/bookDetail/33332bf05cbba0333b1efb4", document: page(isbn: "9787530221532"))
        #expect(record.kind == "book")
        #expect(record.externalId == "834464")
        #expect(record.fields["title"] == .text("活着"))
        #expect(record.fields["author"] == .text("余华"))
        #expect(record.identities.contains(ELVIdentity(namespace: "isbn13", value: "9787530221532", origin: .declared)))
        #expect(record.identities.contains { $0.namespace == "weread.book" && $0.value == "834464" })

        let noIsbn = try assemble("https://weread.qq.com/web/bookDetail/ce032b305a9bc1ce0b0dd2a", document: page(isbn: ""))
        #expect(noIsbn.fields["isbn"] == nil)
        #expect(!noIsbn.identities.contains { $0.namespace == "isbn13" })
    }

    @Test
    func `A shared note assembles its words, passage, and book, and never maps other readers' data`() throws {
        let body = """
        {"reviewId": "2100205_73IB5RiZD", "review": {
          "reviewId": "2100205_73IB5RiZD", "type": 1, "content": "六世达赖情歌第二十四首最著名的译作", "abstract": "恐为多情弃习佛",
          "chapterTitle": "二十四 往还", "createTime": 1541478776,
          "book": {"bookId": "933820", "title": "仓央嘉措情歌六十六首（七绝版）", "author": "仓央嘉措", "cover": "https://cdn.weread.qq.com/weread/cover/1/cover.jpg"},
          "author": {"userVid": 2100205, "name": "sample reader"}
        }, "likes": [{"name": "someone else"}], "comments": [{"content": "13800000000"}]}
        """
        let node: ELVRawJSON = try #require(ELVRawJSON.parse(Data(body.utf8)))
        let record = try assemble("https://weread.qq.com/web/review/detail/2100205_73IB5RiZD", document: ELVDocument(json: node))
        #expect(record.kind == "note")
        #expect(record.externalId == "2100205_73IB5RiZD")
        #expect(record.fields["title"] == .text("仓央嘉措情歌六十六首（七绝版）"))
        #expect(record.fields["summary"] == .text("六世达赖情歌第二十四首最著名的译作"))
        #expect(record.fields["passage"] == .text("恐为多情弃习佛"))
        #expect(record.fields["chapter"] == .text("二十四 往还"))
        guard case .date? = record.fields["created"] else {
            Issue.record("expected the epoch createTime as a date")
            return
        }
        #expect(record.fields["rating"] == nil)
        let mapped = record.fields.values.compactMap { value -> String? in
            if case let .text(text) = value { return text }
            return nil
        }
        #expect(!mapped.contains("13800000000"))
        #expect(!mapped.contains("someone else"))
    }

    @Test
    func `The notes export recognizes by content and imports through the catalog source`() throws {
        let pack = try loaded()
        let export = """
        《活着》

        余华
        2个笔记

        第一章

        ◆ 人是为活着本身而活着，而不是为了活着之外的任何事物所活着。

        ◆ 2024/03/05发表想法

        读到这里停了很久。

        原文：少年去游荡，中年想掘藏，老年做和尚。

        -- 来自微信读书
        """
        let data = Data(export.utf8)
        let source = try #require(ELVFileRecognizer.recognize(fileName: "活着.txt", data: data, sources: pack.fileSources))
        #expect(source.id == "weread.notes")
        let records = try ELVArchiveImporter.importRecords(source: source, fileName: "活着.txt", data: data)
        #expect(records.count == 2)
        #expect(records.map { $0.fields["noteType"] } == [.text("highlight"), .text("thought")])
        #expect(records[1].fields["title"] == .text("读到这里停了很久。"))
        #expect(records[1].fields["passage"] == .text("少年去游荡，中年想掘藏，老年做和尚。"))
        #expect(records.allSatisfy { $0.fields["book"] == .text("活着") && $0.fields["chapter"] == .text("第一章") })
        // Re-importing the same export keys identically (merge dedups).
        let again = try ELVArchiveImporter.importRecords(source: source, fileName: "活着.txt", data: data)
        #expect(again.map(\.externalId) == records.map(\.externalId))
    }
}
