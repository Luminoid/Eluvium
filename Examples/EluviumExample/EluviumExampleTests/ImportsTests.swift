import EluviumCore
import Foundation
import Testing
@testable import EluviumExample

/// The archive-import demos: the bundled samples through the real sources,
/// the mirror merge arithmetic, and the file reader's cap copy.
@Suite("Imports")
@MainActor
struct ImportsTests {
    @Test
    func `The imports flow builds an account mirror that dedups and preserves edits on re-import`() async throws {
        // The real source, not a redeclared copy: its timezone fields call
        // the airport.timeZone@1 op, which registers in the store's init.
        await ExampleStore.shared.ready()
        let source = FlightySource.source
        let csv = FlightySource.sampleCSV
        let first = try ELVArchiveImporter.importRecords(source: source, fileName: "FlightyExport-sample.csv", data: Data(csv.utf8))
        try #require(first.count == 3)
        var mirror = ELVRecord(sourceId: source.id, kind: "account", collections: ["flights": first])
        mirror.collections["flights"]?[0].fields["note"] = .text("edited")

        // Re-import the same file under fill-empty: no duplicates, note kept.
        let again = try ELVArchiveImporter.importRecords(source: source, fileName: "FlightyExport-sample.csv", data: Data(csv.utf8))
        let incoming = ELVRecord(sourceId: source.id, kind: "account", collections: ["flights": again])
        mirror = mirror.merging(incoming, policy: .fillEmptyOnly)

        #expect(mirror.collections["flights"]?.count == 3)
        #expect(mirror.collections["flights"]?.first?.fields["note"] == .text("edited"))
    }

    @Test
    func `The import demo reports the merge counts and the preserved edit the screen summarizes`() async throws {
        await ExampleStore.shared.ready()
        let demo = ImportDemo.flighty
        let rows = try demo.files.flatMap { file in
            try ELVArchiveImporter.importRecords(source: demo.source, fileName: file.fileName, data: Data(file.text.utf8))
        }
        let first = demo.merge(rows, into: nil, policy: .preferIncoming)
        #expect(first.countBefore == 0)
        #expect(first.countAfter == 3)
        #expect(!first.noteKept)
        #expect(demo.summary(imported: rows.count, fileCount: 1, policy: .preferIncoming, outcome: first) == "Imported 3 rows from 1 file (prefer-incoming). Mirror 0 → 3 flights, deduped on ID.")

        var edited = first.mirror
        edited.collections[demo.collection]?[0].fields["note"] = .text("edited")
        let again = demo.merge(rows, into: edited, policy: .fillEmptyOnly)
        #expect(again.countBefore == 3)
        #expect(again.countAfter == 3)
        #expect(again.noteKept)
        #expect(demo.summary(imported: rows.count, fileCount: 1, policy: .fillEmptyOnly, outcome: again).hasSuffix("Edited note preserved."))

        // Shard imports say so.
        let twitter = ImportDemo.twitter
        let shardOutcome = twitter.merge([], into: nil, policy: .preferIncoming)
        #expect(twitter.summary(imported: 0, fileCount: 2, policy: .preferIncoming, outcome: shardOutcome).contains("2 shards, concatenated in part order"))
    }

    @Test
    func `File recognition routes a pick to its demo and unrecognized picks stay on Flighty`() {
        let recognized = ELVFileRecognizer.recognize(fileName: "tweets-part1.js", data: Data(TwitterArchiveSource.sampleShards[1].text.utf8), sources: ImportDemo.recognizableSources)
        #expect(ImportDemo.demo(for: recognized) == .twitter)
        let opml = ELVFileRecognizer.recognize(fileName: "Subscriptions.opml", data: Data(OPMLSource.sampleOPML.utf8), sources: ImportDemo.recognizableSources)
        #expect(ImportDemo.demo(for: opml) == .opml)
        #expect(ImportDemo.demo(for: nil) == .flighty)
    }

    @Test
    func `The import cap copy is formatted from the one constant`() {
        #expect(ImportFileReader.maxImportBytes == 20 * 1024 * 1024)
        #expect(ImportFileReader.maxImportBytesDescription == "20 MB")
    }

    @Test
    func `The OPML sample imports subscriptions that dedup on feed URL and chain by member url`() throws {
        let records = try ELVArchiveImporter.importRecords(source: OPMLSource.source, fileName: "Subscriptions.opml", data: Data(OPMLSource.sampleOPML.utf8))
        #expect(records.count == 4)
        #expect(records.first?.kind == "feed")
        #expect(records.first?.externalId == "https://daringfireball.net/feeds/main")
        #expect(records.first?.fields["group"] == .text("Blogs"))
        // Every row's member url is its feed URL: the generic.feed chain.
        #expect(records.allSatisfy { RecordBrowsing.memberURL(of: $0) != nil })

        // Re-import dedups on externalId under the mirror merge.
        var mirror = ELVRecord(sourceId: OPMLSource.source.id, kind: "account", collections: ["feeds": records])
        let again = try ELVArchiveImporter.importRecords(source: OPMLSource.source, fileName: "Subscriptions.opml", data: Data(OPMLSource.sampleOPML.utf8))
        mirror = mirror.merging(ELVRecord(sourceId: OPMLSource.source.id, kind: "account", collections: ["feeds": again]), policy: .fillEmptyOnly)
        #expect(mirror.collections["feeds"]?.count == 4)

        // The content probe refuses non-OPML bytes under the .opml name.
        #expect(throws: ELVArchiveImporter.Failure.formatMismatch(expected: "<opml")) {
            try ELVArchiveImporter.importRecords(source: OPMLSource.source, fileName: "Subscriptions.opml", data: Data("<html/>".utf8))
        }
    }

    @Test
    func `The jsJson sample import concatenates shards and dedup preserves edits on re-import`() throws {
        let source = TwitterArchiveSource.source
        // Each shard file runs the same archive import path; records
        // concatenate in shard (partN) order.
        let records = try TwitterArchiveSource.sampleShards.flatMap { shard in
            try ELVArchiveImporter.importRecords(source: source, fileName: shard.fileName, data: Data(shard.text.utf8))
        }
        #expect(records.map(\.externalId) == ["9001", "9002", "9003", "9004"])
        #expect(records.first?.fields["text"] == .text("Shipped the feed engine today"))
        // The pack-declared created_at format parsed to a real date.
        #expect(records.allSatisfy { record in
            if case .date? = record.fields["date"] { true } else { false }
        })

        var mirror = ELVRecord(sourceId: source.id, kind: "account", collections: ["tweets": records])
        mirror.collections["tweets"]?[0].fields["note"] = .text("edited")
        let again = try TwitterArchiveSource.sampleShards.flatMap { shard in
            try ELVArchiveImporter.importRecords(source: source, fileName: shard.fileName, data: Data(shard.text.utf8))
        }
        mirror = mirror.merging(ELVRecord(sourceId: source.id, kind: "account", collections: ["tweets": again]), policy: .fillEmptyOnly)
        #expect(mirror.collections["tweets"]?.count == 4) // deduped on id_str, no duplicates
        #expect(mirror.collections["tweets"]?.first?.fields["note"] == .text("edited"))
    }

    @Test
    func `The Flighty source resolves IANA time zones from the IATA columns`() async throws {
        // airport.timeZone@1 registers with the built-in op roster in the
        // store's init; the source's tz fields resolve through the registry.
        await ExampleStore.shared.ready()
        let csv = """
        Date,Flight,Flight Flighty ID,From,To,Seat
        2026-05-01,UA123,uuid-1,SFO,JFK,12A
        2026-06-12,NH211,uuid-2,HND,LHR,2A
        """
        let records = try ELVArchiveImporter.importRecords(source: FlightySource.source, fileName: "FlightyExport-test.csv", data: Data(csv.utf8))
        try #require(records.count == 2)
        #expect(records[0].fields["departureTimeZone"] == .text("America/Los_Angeles"))
        #expect(records[0].fields["arrivalTimeZone"] == .text("America/New_York"))
        #expect(records[1].fields["departureTimeZone"] == .text("Asia/Tokyo"))
        #expect(records[1].fields["arrivalTimeZone"] == .text("Europe/London"))
    }

    @Test
    func `Archive-import failure copy is typed and mentions the expected columns`() {
        let mismatch = ELVArchiveImporter.Failure.formatMismatch(expected: "Date, Flight")
        #expect(FailureCopy.message(for: mismatch).contains("Date, Flight"))
        #expect(FailureCopy.message(for: .noRows) != FailureCopy.message(for: .unreadable))
    }

    @Test
    func `The app's reader recognizes a WeRead export and an eBird CSV through the pack's file sources`() async throws {
        await ExampleStore.shared.ready()
        let catalog = ExampleStore.shared.loadedPack.fileSources
        let weread = try #require(catalog.first { $0.id == "weread.notes" })
        #expect(ImportFileReader.target(fileName: WeReadNotesSample.fileName, data: Data(WeReadNotesSample.text.utf8), catalogSources: catalog) == .catalog(weread))

        // The real read path: size gate, decode, recognition, off the main thread.
        let ebirdCSV = """
        Submission ID,Common Name,Scientific Name,Taxonomic Order,Count,State/Province,County,Location ID,Location,Latitude,Longitude,Date,Time
        S44230333,Northern Cardinal,Cardinalis cardinalis,31270,2,US-NY,Tompkins,L99381,Sapsucker Woods,42.4797,-76.4527,2018-04-03,07:00 AM
        """
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("MyEBirdData.csv")
        try Data(ebirdCSV.utf8).write(to: file)
        let outcome = await ImportFileReader.read(at: file, catalogSources: catalog)
        guard case let .text(text, target) = outcome, case let .catalog(source) = target else {
            Issue.record("expected a catalog import, got \(outcome)")
            return
        }
        #expect(source.id == "ebird.mydata")
        #expect(text.hasPrefix("Submission ID"))

        // The demos still claim their own files first, and an unrecognized
        // file stays on Flighty for its typed failure copy.
        #expect(ImportFileReader.target(fileName: "Subscriptions.opml", data: Data(OPMLSource.sampleOPML.utf8), catalogSources: catalog) == .demo(.opml))
        #expect(ImportFileReader.target(fileName: "FlightyExport.csv", data: Data(FlightySource.sampleCSV.utf8), catalogSources: catalog) == .demo(.flighty))
        #expect(ImportFileReader.target(fileName: "notes.txt", data: Data("hello".utf8), catalogSources: catalog) == .demo(.flighty))
    }

    @Test
    func `The WeRead sample imports its notes through the catalog source and dedups on re-import`() async throws {
        await ExampleStore.shared.ready()
        let source = try #require(ExampleStore.shared.loadedPack.source(withId: "weread.notes"))
        let records = try ELVArchiveImporter.importRecords(source: source, fileName: WeReadNotesSample.fileName, data: Data(WeReadNotesSample.text.utf8))
        try #require(records.count == 2)
        #expect(records.map { $0.fields["noteType"] } == [.text("highlight"), .text("thought")])
        #expect(records[1].fields["title"] == .text("读到这里停了很久。"))
        let sameBook = records.allSatisfy { $0.fields["book"] == .text("活着") }
        #expect(sameBook)

        let first = CatalogImport.merge(records, into: nil, source: source, policy: .preferIncoming)
        #expect(first.countBefore == 0)
        #expect(first.countAfter == 2)
        let again = CatalogImport.merge(records, into: first.mirror, source: source, policy: .preferIncoming)
        #expect(again.countAfter == 2)
        #expect(CatalogImport.summary(source: source, imported: 2, outcome: first).hasPrefix("Imported 2 rows through weread.notes."))
        // The generic row: the note's own words, then its chapter.
        #expect(CatalogImport.rowTitle(records[1]) == "读到这里停了很久。")
        #expect(CatalogImport.rowSecondary(records[0])?.hasPrefix("第一章") == true)
    }
}
