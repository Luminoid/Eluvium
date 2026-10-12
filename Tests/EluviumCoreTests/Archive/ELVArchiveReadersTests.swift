import Foundation
import Testing
@testable import EluviumCore

@Suite("CSV reading")
struct ELVCSVReaderTests {
    @Test
    func `Quoted fields keep embedded commas, escaped quotes, and newlines`() throws {
        let csv = """
        Date,Airline,Flight,Notes
        2026-05-01,UAL,UA123,"Window seat, exit row"
        2026-06-12,ASA,AS1276,"He said ""hold my coffee""
        then boarded"
        """
        let table = try #require(ELVCSVReader.parse(csv))
        #expect(table.headers == ["Date", "Airline", "Flight", "Notes"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0]["Notes"] == "Window seat, exit row")
        #expect(table.rows[1]["Notes"] == "He said \"hold my coffee\"\nthen boarded")
    }

    @Test
    func `CRLF endings and trailing newlines parse cleanly`() throws {
        let csv = "A,B\r\n1,2\r\n3,4\r\n"
        let table = try #require(ELVCSVReader.parse(csv))
        #expect(table.rows == [["A": "1", "B": "2"], ["A": "3", "B": "4"]])
    }

    @Test
    func `Empty input yields nothing instead of a phantom table`() {
        #expect(ELVCSVReader.parse("") == nil)
    }

    @Test
    func `UTF-8 multibyte content survives the byte-level scan`() throws {
        let csv = "Title,Note\n星球大战,\"émoji 🎬, ok\"\n龙猫,café"
        let table = try #require(ELVCSVReader.parse(csv))
        #expect(table.rows[0]["Title"] == "星球大战")
        #expect(table.rows[0]["Note"] == "émoji 🎬, ok")
        #expect(table.rows[1]["Title"] == "龙猫")
        #expect(table.rows[1]["Note"] == "café")
    }

    @Test
    func `Quoted CRLF and escaped quotes land in the record grid verbatim`() {
        let csv = "A,B\r\n\"x\r\ny\",\"a\"\"b\"\r\n"
        #expect(ELVCSVReader.parseRecords(csv) == [["A", "B"], ["x\r\ny", "a\"b"]])
    }

    @Test
    func `Embedded commas, blank fields, and a final row without a newline parse exactly`() {
        let csv = "A,B,C\n\"1,5\",,3\nlast,,"
        #expect(ELVCSVReader.parseRecords(csv) == [["A", "B", "C"], ["1,5", "", "3"], ["last", "", ""]])
    }

    @Test
    func `Mixed line endings produce the same records`() {
        let mixed = "A,B\r\n1,2\n3,4\r5,6"
        #expect(ELVCSVReader.parseRecords(mixed) == [["A", "B"], ["1", "2"], ["3", "4"], ["5", "6"]])
    }
}

@Suite("jsJson reading")
struct ELVJSJSONReaderTests {
    @Test
    func `The window.YTD assignment wrapper strips and shards concatenate in order`() throws {
        let part0 = #"window.YTD.tweets.part0 = [ {"tweet": {"id_str": "1", "full_text": "first"}} ];"#
        let part1 = #"window.YTD.tweets.part1 = [ {"tweet": {"id_str": "2", "full_text": "second"}} ]"#
        let combined = try #require(ELVJSJSONReader.parseShards([part0, part1]))
        let ids = ELVJSONPath("$[*].tweet.id_str").evaluate(combined)
        #expect(ids == [.string("1"), .string("2")])
    }

    @Test
    func `Plain JSON without a wrapper still parses`() {
        #expect(ELVJSJSONReader.parse(#"{"a": 1}"#) == .object(["a": .number(1)]))
    }

    @Test
    func `A non-JSON body returns nil rather than a partial parse`() {
        #expect(ELVJSJSONReader.parse("window.YTD.tweets.part0 = function() {}") == nil)
    }

    @Test
    func `Shard concatenation stops at the total-item cap`() throws {
        let items = (0 ..< 6000).map { "{\"i\": \($0)}" }.joined(separator: ",")
        let shard = "window.YTD.tweets.part0 = [\(items)];"
        let combined = try #require(ELVJSJSONReader.parseShards([shard, shard, shard]))
        #expect(combined.arrayValue?.count == ELVArchiveLimits.maxTotalItems)
    }
}
