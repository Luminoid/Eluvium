import Foundation
import Testing
@testable import EluviumCore

@Suite("Flight page island scan")
struct ELVFlightPageTests {
    private let flightJSON = """
    {"flight": {
      "flight_number": "6208",
      "airline": {"iata": "AS", "name": "Alaska Airlines", "note": "braces {inside} a string"},
      "departure": {
        "airport": {"iata": "LAX", "city": "Los Angeles", "timezone": "America/Los_Angeles"},
        "terminal": "6", "gate": "68A",
        "schedule": {"gate": {"original": 1786371600, "estimated": 1786372200}}
      },
      "arrival": {
        "scheduled_airport": {"iata": "JAC", "city": "Jackson Hole", "timezone": "America/Denver", "location": {"latitude": 43.607, "longitude": -110.738}},
        "schedule": {"gate": {"original": 1786379700}}
      }
    }}
    """

    private func page(_ island: String) -> String {
        "<html><head><meta property=\"og:title\" content=\"Track AS6208\"></head><body><script>window.__DATA__ = \(island);</script></body></html>"
    }

    @Test
    func `The balanced-brace scan lifts the island, string braces included`() throws {
        let island = try #require(ELVFlightPage.island(in: page(flightJSON)))
        #expect(island.hasPrefix("{\"flight\":"))
        #expect(island.contains("braces {inside} a string"))
        #expect(ELVRawJSON.parse(Data(island.utf8)) != nil)
    }

    @Test
    func `A full island parses into the flight with the estimated gate time preferred`() {
        guard case let .flight(flight) = ELVFlightPage.parse(html: page(flightJSON)) else {
            Issue.record("Expected a flight")
            return
        }
        #expect(flight.designator == "AS6208")
        #expect(flight.departureIata == "LAX")
        #expect(flight.arrivalIata == "JAC")
        #expect(flight.departureAirport == "Los Angeles (LAX)")
        #expect(flight.arrivalAirport == "Jackson Hole (JAC)")
        #expect(flight.departure == Date(timeIntervalSince1970: 1_786_372_200))
        #expect(flight.arrival == Date(timeIntervalSince1970: 1_786_379_700))
        #expect(flight.terminal == "6")
        #expect(flight.gate == "68A")
        #expect(flight.arrivalLatitude == 43.607)
    }

    @Test
    func `The v2 drift sentinel names every vanished key, never a silent nil`() {
        let drifted = flightJSON
            .replacingOccurrences(of: "\"iata\": \"JAC\", ", with: "")
            .replacingOccurrences(of: "\"schedule\": {\"gate\": {\"original\": 1786379700}}", with: "\"sched\": {}")
        guard case let .drift(missing) = ELVFlightPage.parse(html: page(drifted)) else {
            Issue.record("Expected drift")
            return
        }
        #expect(missing == "arrival.airport.iata, arrival.schedule.gate")

        guard case let .drift(absent) = ELVFlightPage.parse(html: "<html><body>challenge shell</body></html>") else {
            Issue.record("Expected drift for a missing island")
            return
        }
        #expect(absent == "flight island")
    }

    @Test
    func `A 1e300 flight_number renders as text instead of trapping Int64`() {
        // Pre-guard, truncatingRemainder(dividingBy: 1) == 0 held for 1e300
        // and Int64(1e300) trapped the process on page-island JSON.
        let hostile = flightJSON.replacingOccurrences(of: "\"flight_number\": \"6208\"", with: "\"flight_number\": 1e300")
        guard case let .flight(flight) = ELVFlightPage.parse(html: page(hostile)) else {
            Issue.record("Expected a flight")
            return
        }
        #expect(flight.designator == "AS1e+300")
    }

    @Test
    func `A gate epoch outside the plausibility window is a missing key; millisecond epochs scale`() {
        let hostile = flightJSON.replacingOccurrences(of: "\"original\": 1786379700", with: "\"original\": 1e300")
        guard case let .drift(missing) = ELVFlightPage.parse(html: page(hostile)) else {
            Issue.record("Expected drift")
            return
        }
        #expect(missing == "arrival.schedule.gate")
        let millis = flightJSON.replacingOccurrences(of: "\"original\": 1786379700", with: "\"original\": 1786379700000")
        guard case let .flight(flight) = ELVFlightPage.parse(html: page(millis)) else {
            Issue.record("Expected a flight")
            return
        }
        #expect(flight.arrival == Date(timeIntervalSince1970: 1_786_379_700))
    }

    @Test
    func `CJK string content rides the byte scan intact`() throws {
        let cjk = flightJSON.replacingOccurrences(of: "Alaska Airlines", with: "阿拉斯加航空 {括号} 测试")
        let island = try #require(ELVFlightPage.island(in: page(cjk)))
        #expect(island.contains("阿拉斯加航空 {括号} 测试"))
        #expect(ELVRawJSON.parse(Data(island.utf8)) != nil)
    }

    @Test
    func `The op emits typed outputs on success and a formatDrift output on drift`() throws {
        ELVNativeOps.registerBuiltins()
        let op = try #require(ELVNativeOps.lookup("flighty.flightFromPage@2"))
        let outputs = try #require(op(["html": page(flightJSON)], ELVExtractionContext()))
        #expect(outputs["designator"] == .text("AS6208"))
        #expect(outputs["departureTime"] == .date(Date(timeIntervalSince1970: 1_786_372_200), precision: .time))
        #expect(outputs["arrivalGeo"] == .geo(latitude: 43.607, longitude: -110.738))
        #expect(outputs["departureTimeZone"] == .text("America/Los_Angeles"))
        #expect(outputs["formatDrift"] == nil)

        // The document fallback: an http/dom step's scanned page retains its
        // raw HTML for exactly this kind of island scan.
        let document = ELVDocument(html: page(flightJSON))
        let fromDocument = try #require(op([:], ELVExtractionContext(document: document)))
        #expect(fromDocument["designator"] == .text("AS6208"))

        let drift = try #require(op(["html": "<html></html>"], ELVExtractionContext()))
        #expect(drift["formatDrift"] == .text("flight island"))
        #expect(drift["designator"] == nil)
    }
}
