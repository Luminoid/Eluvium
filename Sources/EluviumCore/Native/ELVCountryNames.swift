import Foundation

/// Country-name recognition backing the little-endian label fold: resolves
/// free-text country spellings ("Italy", "USA", "IT") against the ISO region
/// catalog plus the alias spellings addresses actually carry. Ported from
/// TripDays' `CountryResolver` (`place.littleEndianLabel`); a general
/// country table, peer of `ELVAirportTimeZones`.
enum ELVCountryNames {
    /// All two-letter ISO country codes (excludes continents / subdivisions).
    private static let countryCodes: Set<String> = Set(
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
    )

    private static let nameLocale = Locale(identifier: "en_US")

    /// Lowercased English display name → code, built once: the ~250 ICU
    /// `localizedString(forRegionCode:)` lookups happen at first use, never
    /// per call. Matching on lowercased keys is the O(1) form of a
    /// case-insensitive compare over en_US country names.
    private static let nameToCode: [String: String] = {
        var map: [String: String] = [:]
        for code in countryCodes {
            guard let name = nameLocale.localizedString(forRegionCode: code) else { continue }
            map[name.lowercased()] = code
        }
        return map
    }()

    /// Spellings addresses and users actually write that the ISO display-name
    /// comparison can't reach ("USA" is neither a code nor the en name).
    private static let nameAliases: [String: String] = [
        "usa": "US",
        "u.s.a.": "US",
        "u.s.": "US",
        "united states of america": "US",
        "uk": "GB",
        "u.k.": "GB",
        "great britain": "GB",
    ]

    /// Maps "Italy", "italy", or "IT" to "IT"; nil when nothing matches.
    static func code(for input: String?) -> String? {
        let trimmed = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if let alias = nameAliases[lowered] { return alias }
        let upper = trimmed.uppercased()
        if upper.count == 2, countryCodes.contains(upper) { return upper }
        return nameToCode[lowered]
    }

    /// True when the input is spelled out as a country ("United States",
    /// "USA", "Japan") rather than naming a place. Two-letter tokens never
    /// count: "LA" is a city shorthand far more often than Laos.
    static func namesCountry(_ input: String?) -> Bool {
        let trimmed = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return false }
        return code(for: trimmed) != nil
    }
}

/// Public country lookups over the same table, for modules outside Core
/// (the Places address-anchor plausibility check).
public enum ELVCountry {
    /// The ISO code for "Italy", "italy", "IT", "USA"; nil when nothing
    /// matches.
    public static func code(for input: String?) -> String? {
        ELVCountryNames.code(for: input)
    }

    /// The ISO code an address's last comma component names, digits
    /// dropped ("Jr. de la Unión 621, Lima 15001, Peru" → "PE"); nil when the
    /// tail names no country.
    public static func code(fromAddressTail address: String?) -> String? {
        guard let last = address?.split(separator: ",").last else { return nil }
        let cleaned = last.filter { !$0.isNumber }.trimmingCharacters(in: .whitespacesAndNewlines)
        return ELVCountryNames.code(for: cleaned)
    }

    /// True when the text is spelled out as a country rather than a place.
    public static func namesCountry(_ input: String?) -> Bool {
        ELVCountryNames.namesCountry(input)
    }
}
