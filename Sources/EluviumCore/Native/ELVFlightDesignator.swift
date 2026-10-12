import Foundation

/// Flight designator extraction (`flight.designatorFromURL`): an IATA
/// ("UA123") or ICAO ident ("UAL123") in any path segment, so a pasted
/// tracker link names the flight instead of the brand.
enum ELVFlightDesignator {
    // Fixed pattern, compiled once (the static-pattern rule); it runs per
    // path segment of every pasted tracker URL.
    // swiftlint:disable:next force_try
    private static let designatorRegex = try! NSRegularExpression(pattern: "^[A-Z]{2,3}[0-9]{1,4}$")

    static func designator(in url: String) -> String? {
        for segment in url.split(separator: "/") {
            let token = segment.uppercased()
            if designatorRegex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil {
                return token
            }
        }
        return nil
    }
}
