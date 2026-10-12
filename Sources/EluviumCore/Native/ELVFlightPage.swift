import Foundation

/// The Flighty share-page parse (`flighty.flightFromPage@2`): the page
/// embeds the full flight record as a `{"flight":…}` JSON island in its
/// body. v2 adds the format-drift sentinel over v1: a required-key checklist
/// (both IATA codes, both gate times, airline, number) that reports WHICH
/// key vanished as a typed drift outcome, never a silent nil —
/// share-page formats churn, and the difference between "not a flight page"
/// and "the arrival airport key moved" is exactly what a maintainer needs.
enum ELVFlightPage {
    struct Flight: Equatable {
        var designator: String // "AS6208"
        var airlineName: String?
        var departureIata: String
        var arrivalIata: String
        var departureAirport: String // "Los Angeles (LAX)"
        var arrivalAirport: String
        var departureTimeZoneId: String?
        var arrivalTimeZoneId: String?
        var departure: Date
        var arrival: Date
        var terminal: String?
        var gate: String?
        var arrivalLatitude: Double?
        var arrivalLongitude: Double?
    }

    enum Outcome: Equatable {
        case flight(Flight)
        /// The island was reachable but the required-key checklist failed;
        /// the payload names every vanished key.
        case drift(missing: String)
    }

    static func parse(html: String) -> Outcome {
        guard let blob = island(in: html), let root = ELVRawJSON.parse(Data(blob.utf8)),
              let flight = root["flight"], flight.objectValue != nil else {
            return .drift(missing: "flight island")
        }
        let departure = flight["departure"]
        let arrival = flight["arrival"]
        let departureAirport = departure?["airport"]
        let arrivalAirport = arrival?["scheduled_airport"] ?? arrival?["actual_airport"] ?? arrival?["airport"]

        // The v2 sentinel: collect every missing required key, then report
        // them all — a drift usually moves a whole subtree.
        let required: [(key: String, present: Bool)] = [
            ("departure.airport.iata", departureAirport?["iata"]?.stringValue != nil),
            ("arrival.airport.iata", arrivalAirport?["iata"]?.stringValue != nil),
            ("departure.schedule.gate", gateTime(in: departure) != nil),
            ("arrival.schedule.gate", gateTime(in: arrival) != nil),
            ("airline.iata", flight["airline"]?["iata"]?.stringValue != nil),
            ("flight_number", numberString(flight["flight_number"]) != nil),
        ]
        let missing = required.filter { !$0.present }.map(\.key)
        guard missing.isEmpty,
              let depIata = departureAirport?["iata"]?.stringValue?.uppercased(),
              let arrIata = arrivalAirport?["iata"]?.stringValue?.uppercased(),
              let departureTime = gateTime(in: departure),
              let arrivalTime = gateTime(in: arrival),
              let airlineIata = flight["airline"]?["iata"]?.stringValue?.uppercased(),
              let number = numberString(flight["flight_number"])
        else {
            return .drift(missing: missing.joined(separator: ", "))
        }

        let arrivalLocation = arrivalAirport?["location"]
        return .flight(Flight(
            designator: airlineIata + number,
            airlineName: flight["airline"]?["name"]?.stringValue,
            departureIata: depIata,
            arrivalIata: arrIata,
            departureAirport: airportDisplay(departureAirport, iata: depIata),
            arrivalAirport: airportDisplay(arrivalAirport, iata: arrIata),
            departureTimeZoneId: departureAirport?["timezone"]?.stringValue,
            arrivalTimeZoneId: arrivalAirport?["timezone"]?.stringValue,
            departure: departureTime,
            arrival: arrivalTime,
            terminal: departure?["terminal"]?.stringValue,
            gate: departure?["gate"]?.stringValue,
            arrivalLatitude: arrivalLocation?["latitude"]?.numberValue,
            arrivalLongitude: arrivalLocation?["longitude"]?.numberValue
        ))
    }

    /// The balanced `{"flight":…}` object literal embedded in the page.
    /// String-aware so braces inside JSON string values don't unbalance the
    /// scan. Nil if absent.
    static func island(in html: String) -> String? {
        // A single-pass UTF-8 byte scan over the string's own storage when
        // it is contiguous (native strings), else over one copy. The
        // structural bytes ({, }, ", \) are ASCII and can never occur inside
        // a multi-byte scalar, so byte comparison is exact, and grapheme
        // iteration over a multi-MB body is orders of magnitude slower. An
        // unbalanced island scans to the end once, cheaply.
        html.utf8.withContiguousStorageIfAvailable { scanIsland(in: $0) } ?? scanIsland(in: Array(html.utf8))
    }

    private static func scanIsland<Bytes: RandomAccessCollection>(in bytes: Bytes) -> String? where Bytes.Element == UInt8, Bytes.Index == Int {
        let marker = Array("{\"flight\":".utf8)
        guard let start = firstIndex(of: marker, in: bytes) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < bytes.endIndex {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return String(bytes: bytes[start ... index], encoding: .utf8) }
            }
            index += 1
        }
        return nil
    }

    /// First occurrence of `needle` in `haystack` (byte-wise; the island
    /// marker is pure ASCII so no boundary subtlety applies).
    private static func firstIndex<Bytes: RandomAccessCollection>(of needle: [UInt8], in haystack: Bytes) -> Int? where Bytes.Element == UInt8, Bytes.Index == Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.endIndex - needle.count
        var index = haystack.startIndex
        while index <= limit {
            if haystack[index] == needle[0] {
                var offset = 1
                while offset < needle.count, haystack[index + offset] == needle[offset] {
                    offset += 1
                }
                if offset == needle.count { return index }
            }
            index += 1
        }
        return nil
    }

    /// Scheduled gate instant for a leg: `schedule.gate.estimated`, else
    /// `.original`. Page-island epochs pass the same plausibility window
    /// as every other numeric epoch (`ELVDateParser.date(fromEpoch:)`), so
    /// a hostile or mistyped number is a missing key, not a flight in the
    /// year 30000.
    private static func gateTime(in leg: ELVRawJSON?) -> Date? {
        guard let gate = leg?["schedule"]?["gate"] else { return nil }
        guard let epoch = gate["estimated"]?.numberValue ?? gate["original"]?.numberValue else { return nil }
        return ELVDateParser.date(fromEpoch: epoch)
    }

    /// "City (IATA)" display, falling back to the airport name, then the
    /// bare code.
    private static func airportDisplay(_ airport: ELVRawJSON?, iata: String) -> String {
        let name = airport?["city"]?.stringValue ?? airport?["name"]?.stringValue
        guard let name, !name.isEmpty else { return iata }
        return "\(name) (\(iata))"
    }

    /// The flight number as a string, whether the JSON encodes it as a
    /// number or a string.
    private static func numberString(_ value: ELVRawJSON?) -> String? {
        if let text = value?.stringValue, !text.isEmpty { return text }
        if let number = value?.numberValue { return ELVNumberFormat.compactString(number) }
        return nil
    }
}
