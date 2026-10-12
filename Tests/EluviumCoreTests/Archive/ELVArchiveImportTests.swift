import Foundation
import Testing
@testable import EluviumCore

@Suite("Archive import")
struct ELVArchiveImportTests {
    private let flightySource = ELVSource(
        id: "flighty.export",
        kind: "flight",
        match: ELVMatchRule(file: ELVFileMatchRule(name: "FlightyExport-*.csv", csvHeader: ["Date", "Airline", "Flight"])),
        fetch: ELVFetchPlan(mode: "archive", format: "csv"),
        rows: [
            ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .column("Flight Flighty ID"))]),
            ELVFieldSpec(name: "designator", candidates: [ELVCandidate(from: .column("Flight"))]),
            ELVFieldSpec(name: "seat", candidates: [ELVCandidate(from: .column("Seat"))]),
            ELVFieldSpec(name: "date", candidates: [ELVCandidate(from: .column("Date"), coercion: ELVCoercion(kind: "date"))]),
        ]
    )

    private let flightyCSV = """
    Date,Airline,Flight,Flight Flighty ID,Seat
    2026-05-01,UAL,UA123,uuid-1,12A
    2026-06-12,ASA,AS1276,uuid-2,6F
    """

    @Test
    func `File recognition needs both the name glob and the header probe`() {
        let data = Data(flightyCSV.utf8)
        #expect(ELVFileRecognizer.recognize(fileName: "FlightyExport-2026-08-11.csv", data: data, sources: [flightySource])?.id == "flighty.export")
        #expect(ELVFileRecognizer.recognize(fileName: "SomethingElse.csv", data: data, sources: [flightySource]) == nil)
        let wrongHeaders = Data("X,Y\n1,2".utf8)
        #expect(ELVFileRecognizer.recognize(fileName: "FlightyExport-2026-08-11.csv", data: wrongHeaders, sources: [flightySource]) == nil)
    }

    @Test
    func `A wrong CSV header fails the source's own probe with formatMismatch`() {
        let wrongHeader = Data("X,Y\n1,2".utf8)
        #expect(throws: ELVArchiveImporter.Failure.formatMismatch(expected: "Date, Airline, Flight")) {
            try ELVArchiveImporter.importRecords(source: flightySource, fileName: "FlightyExport-2026-08-11.csv", data: wrongHeader)
        }
    }

    @Test
    func `An oversized archive is refused before any decoding, with the limit in the failure`() {
        #expect(throws: ELVArchiveImporter.Failure.tooLarge(limit: 16)) {
            try ELVArchiveImporter.importRecords(source: flightySource, fileName: "FlightyExport-2026-08-11.csv", data: Data(flightyCSV.utf8), maxBytes: 16)
        }
        #expect(ELVArchiveLimits.maxImportBytes == 50 * 1024 * 1024)
        #expect(throws: ELVArchiveImporter.Failure.unreadable) {
            try ELVArchiveImporter.importRecords(source: flightySource, fileName: "FlightyExport-2026-08-11.csv", data: Data())
        }
    }

    @Test
    func `Recognition and the import probe read a bounded head, so a huge archive is judged by its header`() throws {
        var csv = flightyCSV
        while csv.utf8.count < ELVArchiveLimits.probeBytes * 3 {
            csv += "\n2026-06-12,ASA,AS1276,uuid-\(csv.utf8.count),6F"
        }
        let data = Data(csv.utf8)
        #expect(ELVFileRecognizer.recognize(fileName: "FlightyExport-2026-08-11.csv", data: data, sources: [flightySource])?.id == "flighty.export")
        let records = try ELVArchiveImporter.importRecords(source: flightySource, fileName: "FlightyExport-2026-08-11.csv", data: data)
        #expect(records.count > 2)
        // A wrong header stays wrong however many rows follow it.
        let wrong = Data(("X,Y\n" + String(repeating: "1,2\n", count: 60000)).utf8)
        #expect(ELVFileRecognizer.recognize(fileName: "FlightyExport-2026-08-11.csv", data: wrong, sources: [flightySource]) == nil)
        #expect(throws: ELVArchiveImporter.Failure.formatMismatch(expected: "Date, Airline, Flight")) {
            try ELVArchiveImporter.importRecords(source: flightySource, fileName: "FlightyExport-2026-08-11.csv", data: wrong)
        }
    }

    @Test
    func `A Flighty-shaped CSV imports one record per row with externalId promoted`() throws {
        let records = try ELVArchiveImporter.importRecords(source: flightySource, fileName: "FlightyExport-2026-08-11.csv", data: Data(flightyCSV.utf8))
        #expect(records.count == 2)
        #expect(records.map(\.externalId) == ["uuid-1", "uuid-2"])
        #expect(records.first?.fields["designator"] == .text("UA123"))
        #expect(records.first?.kind == "flight")
        #expect(records.first?.fields["date"] == .date(Date(timeIntervalSince1970: 1_777_593_600), precision: .day))
    }

    @Test
    func `An IMDb-shaped ratings CSV lands Const as both externalId and a strong identity`() throws {
        let source = ELVSource(
            id: "imdb.ratings",
            kind: "movie",
            fetch: ELVFetchPlan(mode: "archive", format: "csv"),
            rows: [
                ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .column("Const"))]),
                ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .column("Title"))]),
                ELVFieldSpec(name: "myRating", candidates: [ELVCandidate(from: .column("Your Rating"), coercion: ELVCoercion(kind: "rating", scaleMin: 0, scaleMax: 10))]),
            ],
            identities: [
                ELVIdentitySpec(namespace: "imdb", from: .column("Const")),
            ]
        )
        let csv = """
        Const,Your Rating,Date Rated,Title,Year
        tt0076759,9,2019-04-01,Star Wars,1977
        tt0111161,10,2019-05-20,The Shawshank Redemption,1994
        """
        let records = try ELVArchiveImporter.importRecords(source: source, fileName: "ratings.csv", data: Data(csv.utf8))
        #expect(records.count == 2)
        #expect(records.first?.externalId == "tt0076759")
        #expect(records.first?.identities == [ELVIdentity(namespace: "imdb", value: "tt0076759", origin: .declared)])
        #expect(records.first?.fields["myRating"] == .rating(value: 9, scale: 0 ... 10))
    }

    @Test
    func `A Twitter-archive shard imports through the jsJson path keyed on id_str`() throws {
        let source = ELVSource(
            id: "x.archive.tweets",
            kind: "post",
            fetch: ELVFetchPlan(mode: "archive", format: "jsJson"),
            rows: [
                ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.tweet.id_str"))]),
                ELVFieldSpec(name: "text", candidates: [ELVCandidate(from: .json("$.tweet.full_text"))]),
            ]
        )
        let shard = #"window.YTD.tweets.part0 = [ {"tweet": {"id_str": "20", "full_text": "just setting up my twttr"}} ];"#
        let records = try ELVArchiveImporter.importRecords(source: source, fileName: "tweets.js", data: Data(shard.utf8))
        #expect(records.count == 1)
        #expect(records.first?.externalId == "20")
        #expect(records.first?.fields["text"] == .text("just setting up my twttr"))
    }

    @Test
    func `Re-import folds through merge with externalId dedup preserving user edits`() throws {
        let first = try ELVArchiveImporter.importRecords(source: flightySource, fileName: "FlightyExport-2026-08-11.csv", data: Data(flightyCSV.utf8))
        var mirror = ELVRecord(sourceId: "flighty.export", kind: "account", collections: ["flights": first])
        mirror.collections["flights"]?[0].fields["notes"] = .text("user note")

        let updatedCSV = flightyCSV.replacingOccurrences(of: "12A", with: "14C") + "\n2026-07-04,DAL,DL9,uuid-3,1A"
        let second = try ELVArchiveImporter.importRecords(source: flightySource, fileName: "FlightyExport-2026-09-01.csv", data: Data(updatedCSV.utf8))
        let merged = mirror.merging(ELVRecord(sourceId: "flighty.export", kind: "account", collections: ["flights": second]), policy: .preferIncoming)

        let flights = try #require(merged.collections["flights"])
        #expect(flights.count == 3)
        #expect(flights[0].fields["seat"] == .text("14C"))
        #expect(flights[0].fields["notes"] == .text("user note"))
    }

    @Test
    func `A JSON export imports the items its list selector picks, or the root array without one`() throws {
        let rows = [
            ELVFieldSpec(name: "externalId", candidates: [ELVCandidate(from: .json("$.id"))]),
            ELVFieldSpec(name: "title", candidates: [ELVCandidate(from: .json("$.title"))]),
        ]
        let wrapped = Data(#"{"exportedAt": "2026-10-10", "items": [{"id": "a", "title": "A"}, {"id": "b", "title": "B"}]}"#.utf8)
        let listed = ELVSource(
            id: "json.export", kind: "book",
            fetch: ELVFetchPlan(mode: "archive", format: "json"),
            rows: rows,
            list: ELVListSpec(seed: "https://example.com/export", items: .json("$.items[*]"))
        )
        let records = try ELVArchiveImporter.importRecords(source: listed, fileName: "export.json", data: wrapped)
        #expect(records.map(\.externalId) == ["a", "b"])

        // Without a selector the root object is the one item.
        var unlisted = listed
        unlisted.list = nil
        #expect(throws: ELVArchiveImporter.Failure.noRows) {
            try ELVArchiveImporter.importRecords(source: unlisted, fileName: "export.json", data: wrapped)
        }
        let rootArray = Data(#"[{"id": "c", "title": "C"}]"#.utf8)
        #expect(try ELVArchiveImporter.importRecords(source: unlisted, fileName: "export.json", data: rootArray).map(\.externalId) == ["c"])
    }
}
