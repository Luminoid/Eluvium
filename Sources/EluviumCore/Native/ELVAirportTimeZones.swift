import Foundation

/// IATA → IANA time-zone table (`airport.timeZone`): flight
/// exports and share pages routinely carry offset-less local timestamps
/// ("2026-05-01 08:35" at LAX), and the airport code is the only timezone
/// signal in the record. Curated to the world's busiest ~130 airports —
/// enough for the flight sources' real traffic; an unknown code produces
/// nothing, and the caller keeps the timestamp zoneless rather than guess.
enum ELVAirportTimeZones {
    static func timeZoneId(forIATA code: String) -> String? {
        table[code.uppercased()]
    }

    private static let table: [String: String] = [
        // United States
        "ATL": "America/New_York", "JFK": "America/New_York", "LGA": "America/New_York",
        "EWR": "America/New_York", "BOS": "America/New_York", "PHL": "America/New_York",
        "DCA": "America/New_York", "IAD": "America/New_York", "BWI": "America/New_York",
        "MIA": "America/New_York", "FLL": "America/New_York", "MCO": "America/New_York",
        "TPA": "America/New_York", "CLT": "America/New_York", "DTW": "America/New_York",
        "ORD": "America/Chicago", "MDW": "America/Chicago", "DFW": "America/Chicago",
        "DAL": "America/Chicago", "IAH": "America/Chicago", "HOU": "America/Chicago",
        "AUS": "America/Chicago", "MSP": "America/Chicago", "STL": "America/Chicago",
        "BNA": "America/Chicago", "MSY": "America/Chicago", "MCI": "America/Chicago",
        "DEN": "America/Denver", "SLC": "America/Denver", "ABQ": "America/Denver",
        "JAC": "America/Denver", "BZN": "America/Denver",
        "PHX": "America/Phoenix",
        "LAX": "America/Los_Angeles", "SFO": "America/Los_Angeles", "SAN": "America/Los_Angeles",
        "SJC": "America/Los_Angeles", "OAK": "America/Los_Angeles", "SMF": "America/Los_Angeles",
        "SEA": "America/Los_Angeles", "PDX": "America/Los_Angeles", "LAS": "America/Los_Angeles",
        "ANC": "America/Anchorage", "HNL": "Pacific/Honolulu", "OGG": "Pacific/Honolulu",
        // Canada
        "YYZ": "America/Toronto", "YUL": "America/Toronto", "YOW": "America/Toronto",
        "YVR": "America/Vancouver", "YYC": "America/Edmonton", "YEG": "America/Edmonton",
        // Mexico, Central & South America
        "MEX": "America/Mexico_City", "CUN": "America/Cancun", "SJD": "America/Mazatlan",
        "GDL": "America/Mexico_City", "PTY": "America/Panama", "SJO": "America/Costa_Rica",
        "GRU": "America/Sao_Paulo", "GIG": "America/Sao_Paulo", "BSB": "America/Sao_Paulo",
        "EZE": "America/Argentina/Buenos_Aires", "AEP": "America/Argentina/Buenos_Aires",
        "SCL": "America/Santiago", "LIM": "America/Lima", "BOG": "America/Bogota",
        "UIO": "America/Guayaquil", "MDE": "America/Bogota",
        // Europe
        "LHR": "Europe/London", "LGW": "Europe/London", "STN": "Europe/London",
        "MAN": "Europe/London", "EDI": "Europe/London", "DUB": "Europe/Dublin",
        "CDG": "Europe/Paris", "ORY": "Europe/Paris", "NCE": "Europe/Paris",
        "AMS": "Europe/Amsterdam", "BRU": "Europe/Brussels", "LUX": "Europe/Luxembourg",
        "FRA": "Europe/Berlin", "MUC": "Europe/Berlin", "BER": "Europe/Berlin",
        "DUS": "Europe/Berlin", "HAM": "Europe/Berlin", "ZRH": "Europe/Zurich",
        "GVA": "Europe/Zurich", "VIE": "Europe/Vienna", "PRG": "Europe/Prague",
        "WAW": "Europe/Warsaw", "BUD": "Europe/Budapest", "MAD": "Europe/Madrid",
        "BCN": "Europe/Madrid", "PMI": "Europe/Madrid", "AGP": "Europe/Madrid",
        "LIS": "Europe/Lisbon", "OPO": "Europe/Lisbon", "FCO": "Europe/Rome",
        "MXP": "Europe/Rome", "LIN": "Europe/Rome", "VCE": "Europe/Rome",
        "NAP": "Europe/Rome", "ATH": "Europe/Athens", "IST": "Europe/Istanbul",
        "SAW": "Europe/Istanbul", "CPH": "Europe/Copenhagen", "OSL": "Europe/Oslo",
        "ARN": "Europe/Stockholm", "HEL": "Europe/Helsinki", "KEF": "Atlantic/Reykjavik",
        // Middle East & Africa
        "DXB": "Asia/Dubai", "AUH": "Asia/Dubai", "DOH": "Asia/Qatar",
        "RUH": "Asia/Riyadh", "JED": "Asia/Riyadh", "TLV": "Asia/Jerusalem",
        "AMM": "Asia/Amman", "CAI": "Africa/Cairo", "JNB": "Africa/Johannesburg",
        "CPT": "Africa/Johannesburg", "NBO": "Africa/Nairobi", "ADD": "Africa/Addis_Ababa",
        "LOS": "Africa/Lagos", "CMN": "Africa/Casablanca", "RAK": "Africa/Casablanca",
        // Asia
        "HND": "Asia/Tokyo", "NRT": "Asia/Tokyo", "KIX": "Asia/Tokyo",
        "ITM": "Asia/Tokyo", "NGO": "Asia/Tokyo", "CTS": "Asia/Tokyo",
        "FUK": "Asia/Tokyo", "OKA": "Asia/Tokyo",
        "ICN": "Asia/Seoul", "GMP": "Asia/Seoul", "PUS": "Asia/Seoul",
        "PEK": "Asia/Shanghai", "PKX": "Asia/Shanghai", "PVG": "Asia/Shanghai",
        "SHA": "Asia/Shanghai", "CAN": "Asia/Shanghai", "SZX": "Asia/Shanghai",
        "CTU": "Asia/Shanghai", "CKG": "Asia/Shanghai", "XIY": "Asia/Shanghai",
        "HGH": "Asia/Shanghai", "NKG": "Asia/Shanghai", "KMG": "Asia/Shanghai",
        "HKG": "Asia/Hong_Kong", "MFM": "Asia/Macau", "TPE": "Asia/Taipei",
        "TSA": "Asia/Taipei", "SIN": "Asia/Singapore", "KUL": "Asia/Kuala_Lumpur",
        "BKK": "Asia/Bangkok", "DMK": "Asia/Bangkok", "HKT": "Asia/Bangkok",
        "CNX": "Asia/Bangkok", "SGN": "Asia/Ho_Chi_Minh", "HAN": "Asia/Ho_Chi_Minh",
        "DAD": "Asia/Ho_Chi_Minh", "CGK": "Asia/Jakarta", "DPS": "Asia/Makassar",
        "MNL": "Asia/Manila", "CEB": "Asia/Manila",
        "DEL": "Asia/Kolkata", "BOM": "Asia/Kolkata", "BLR": "Asia/Kolkata",
        "MAA": "Asia/Kolkata", "HYD": "Asia/Kolkata", "CCU": "Asia/Kolkata",
        "CMB": "Asia/Colombo", "DAC": "Asia/Dhaka", "KTM": "Asia/Kathmandu",
        "ISB": "Asia/Karachi", "KHI": "Asia/Karachi",
        // Oceania
        "SYD": "Australia/Sydney", "MEL": "Australia/Melbourne", "BNE": "Australia/Brisbane",
        "PER": "Australia/Perth", "ADL": "Australia/Adelaide", "AKL": "Pacific/Auckland",
        "CHC": "Pacific/Auckland", "WLG": "Pacific/Auckland", "NAN": "Pacific/Fiji",
        "PPT": "Pacific/Tahiti",
    ]
}
