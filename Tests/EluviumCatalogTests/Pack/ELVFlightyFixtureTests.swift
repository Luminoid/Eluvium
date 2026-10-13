import EluviumCatalog
import Foundation
import Testing
@testable import EluviumCore

/// The P3 share-page fixture: live.flighty.app share pages rot in
/// weeks, so a real share page serving full flight data, captured
/// 2026-08-29 with the source's declared `crawler` persona, is pinned as an
/// SPM resource before the TripDays port needs it. The traveler's name and
/// Flighty's client keys (the MapKit JS token, the analytics key) are
/// redacted; the share id in the test URL is a placeholder. The test runs
/// the real pack source over the saved bytes offline: the `{"flight":…}`
/// island parse, the og:title ladder, and
/// the drift sentinel staying quiet on a healthy page.
@Suite("Flighty share-page fixture")
struct ELVFlightyFixtureTests {
    @Test
    func `The captured share page assembles the full flight record with no drift`() throws {
        let pack = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
        let source = try #require(pack.source(withId: "flighty.flight"))
        let url = try #require(URL(string: "https://live.flighty.app/00000000f-0000-4000-8000-000000000000"))
        let recognition = try #require(pack.registry.recognize(url))
        #expect(recognition.sourceId == "flighty.flight")

        let fixtureURL = try #require(Bundle.module.url(forResource: "flighty_share", withExtension: "html", subdirectory: "Fixtures"))
        let document = try ELVDocument(html: String(contentsOf: fixtureURL, encoding: .utf8))
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: recognition.params, document: document))

        // The fixture is a captured share with its ids zeroed and its dates shifted;
        // the drift sentinel stays quiet on it; a re-captured
        // fixture that trips it names exactly which key moved.
        #expect(record.fields["formatDrift"] == nil)
        #expect(record.kind == "flight")
        #expect(record.externalId == "AS6208")
        #expect(record.fields["title"] == .text("AS6208 to Jackson Hole"))
        #expect(record.fields["label"] == .text("AS6208 to Jackson Hole"))
        #expect(record.fields["departureTimeZone"] != nil)
        #expect(record.fields["arrivalTimeZone"] != nil)
        #expect(record.fields["designator"] == .text("AS6208"))
        #expect(record.fields["airline"] == .text("Alaska"))
        #expect(record.fields["departureIata"] == .text("LAX"))
        #expect(record.fields["arrivalIata"] == .text("JAC"))
        #expect(record.fields["departureAirport"] == .text("Los Angeles (LAX)"))
        #expect(record.fields["arrivalAirport"] == .text("Jackson Hole (JAC)"))
        #expect(record.fields["terminal"] == .text("4"))
        #expect(record.fields["gate"] == .text("52F"))
        // Gate times ride `schedule.gate.estimated` epochs.
        #expect(record.fields["departureTime"] == .date(Date(timeIntervalSince1970: 1_781_986_620), precision: .time))
        #expect(record.fields["arrivalTime"] == .date(Date(timeIntervalSince1970: 1_781_995_500), precision: .time))
        #expect(record.fields["arrivalGeo"] == .geo(latitude: 43.599998474121094, longitude: -110.73999786376953))
    }

    @Test
    func `A mutated real capture trips the drift sentinel, naming the moved key`() throws {
        let pack = try ELVStarterPack.load(capabilities: ELVCapabilities(fetchModes: ["http", "json", "archive", "feed", "dom"], binaryVersion: "0.1"))
        let source = try #require(pack.source(withId: "flighty.flight"))
        let url = try #require(URL(string: "https://live.flighty.app/00000000f-0000-4000-8000-000000000000"))
        let recognition = try #require(pack.registry.recognize(url))
        let fixtureURL = try #require(Bundle.module.url(forResource: "flighty_share", withExtension: "html", subdirectory: "Fixtures"))
        let captured = try String(contentsOf: fixtureURL, encoding: .utf8)
        // A format change the parser cannot see past: the departure block's
        // key renamed, as a redesign would.
        let mutated = captured.replacingOccurrences(of: "\"departure\":{", with: "\"origin\":{")
        #expect(mutated != captured)
        let record = ELVAssembler.assemble(source: source, context: ELVExtractionContext(url: url, params: recognition.params, document: ELVDocument(html: mutated)))
        guard case let .text(drift)? = record.fields["formatDrift"] else {
            Issue.record("Expected the drift sentinel to name the missing key")
            return
        }
        #expect(drift.contains("departure"))
        // No flight parsed, so no route label; the og:title still names it.
        #expect(record.fields["designator"] == nil)
        #expect(record.fields["label"] == .text("AS6208 to Jackson Hole"))
    }
}
