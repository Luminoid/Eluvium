import Foundation
import Testing
@testable import EluviumCore

@Suite("Airport time zones")
struct ELVAirportTimeZoneTests {
    @Test
    func `Known IATA codes resolve to valid IANA identifiers, unknown codes to nothing`() throws {
        #expect(ELVAirportTimeZones.timeZoneId(forIATA: "LAX") == "America/Los_Angeles")
        #expect(ELVAirportTimeZones.timeZoneId(forIATA: "jac") == "America/Denver")
        #expect(ELVAirportTimeZones.timeZoneId(forIATA: "HND") == "Asia/Tokyo")
        #expect(ELVAirportTimeZones.timeZoneId(forIATA: "XXX") == nil)

        ELVNativeOps.registerBuiltins()
        let op = try #require(ELVNativeOps.lookup("airport.timeZone"))
        #expect(op(["iata": "SFO"], ELVExtractionContext())?["timeZone"] == .text("America/Los_Angeles"))
        #expect(op(["iata": "ZZZ"], ELVExtractionContext()) == nil)
    }

    @Test
    func `Every table entry names a zone the system recognizes`() {
        for code in ["ATL", "LHR", "CDG", "DXB", "SIN", "SYD", "GRU", "EZE", "IST", "DEL", "PEK", "ICN", "MEX", "YYZ", "JNB", "KEF", "KTM", "DPS", "HNL", "ANC"] {
            let zone = ELVAirportTimeZones.timeZoneId(forIATA: code)
            #expect(zone != nil, "\(code) missing from the table")
            if let zone {
                #expect(TimeZone(identifier: zone) != nil, "\(code) → \(zone) is not a valid IANA zone")
            }
        }
    }
}
