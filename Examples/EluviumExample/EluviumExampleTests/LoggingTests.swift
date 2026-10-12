import EluviumCore
import EluviumNet
import Foundation
import Testing
@testable import EluviumExample

/// The app's own log lines. The framework logs every resolve, walk, import,
/// and pack load itself (its tests pin those); what is left here is the
/// corpus verdict, which must agree with the Examples screen's status line
/// and never carry a full URL.
@Suite("Logging")
@MainActor
struct LoggingTests {
    private let example = ELVExample(input: "https://example.com/trail/1?s=token", expectedKind: "trail", expectedNonEmpty: ["title"])

    @Test
    func `A passing example logs its host and source, never the full URL`() throws {
        let record = ELVRecord(sourceId: "alltrails.trail", kind: "trail", fields: ["title": .text("Hidden Falls")])
        let verdict = try #require(ParseLog.verdict(example: example, result: .record(record), host: "example.com"))
        #expect(verdict == ParseLog.Verdict(passed: true, message: "Example passed host=example.com source=alltrails.trail"))
        #expect(!verdict.message.contains("token"))
    }

    @Test
    func `An unmet example reports the same lines the status line shows`() throws {
        let record = ELVRecord(sourceId: "alltrails.trail", kind: "product")
        let verdict = try #require(ParseLog.verdict(example: example, result: .record(record), host: "example.com"))
        let unmet = example.unmetExpectations(for: record)
        #expect(unmet == ["kind trail (got product)", "non-empty title (missing)"])
        #expect(!verdict.passed)
        #expect(verdict.message == "Example unmet host=example.com source=alltrails.trail: \(unmet.joined(separator: "; "))")
    }

    @Test
    func `A failed example names the failure, and a cancelled one logs nothing`() throws {
        let failed = try #require(ParseLog.verdict(example: example, result: .failed(.blocked(status: 403), sourceId: "alltrails.trail"), host: "example.com"))
        #expect(!failed.passed)
        #expect(failed.message.hasPrefix("Example failed host=example.com source=alltrails.trail: "))
        let unrecognized = try #require(ParseLog.verdict(example: example, result: .unrecognized, host: nil))
        #expect(unrecognized.message == "Example failed host=-: no source matched")
        #expect(ParseLog.verdict(example: example, result: .failed(ELVPipeline.cancelledMarker, sourceId: nil), host: "example.com") == nil)
    }

    @Test
    func `A collection pin's unmet line reaches the verdict as the framework wrote it`() throws {
        let pinned = ELVExample(input: "https://example.com/feed", expectedKind: "feed", expectedNonEmptyCollections: ["items"])
        let record = ELVRecord(sourceId: "generic.feed", kind: "feed")
        let unmet = pinned.unmetExpectations(for: record)
        try #require(!unmet.isEmpty)
        let verdict = try #require(ParseLog.verdict(example: pinned, result: .record(record), host: "example.com"))
        #expect(!verdict.passed)
        #expect(verdict.message.hasSuffix(unmet.joined(separator: "; ")))
    }
}
