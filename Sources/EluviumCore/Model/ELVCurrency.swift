import Foundation

/// ISO 4217 minor-unit conventions, shared by the money coercion (which
/// emits minor units) and any display layer (which must divide by the same
/// exponent — a UI that hardcodes /100 renders ¥500 JPY as "5.0 JPY").
public enum ELVCurrency {
    /// ISO 4217's minor units for every active code whose exponent is not
    /// the dominant 2 (the ISO maintenance agency's list A). Pinned, not read
    /// from the system: stored money is minor units with no exponent beside
    /// them, so the table must never move under saved records. The platform's
    /// CLDR data would (it prints cash digits, 0 for HUF/IDR/COP/PKR and IQD,
    /// where ISO says 2 or 3), and an OS update could rescale every stored
    /// amount in a code it changes.
    private static let exponents: [String: Int] = [
        // 0 digits
        "BIF": 0, "CLP": 0, "DJF": 0, "GNF": 0, "ISK": 0, "JPY": 0, "KMF": 0, "KRW": 0,
        "PYG": 0, "RWF": 0, "UGX": 0, "UYI": 0, "VND": 0, "VUV": 0, "XAF": 0, "XOF": 0, "XPF": 0,
        // 3 digits
        "BHD": 3, "IQD": 3, "JOD": 3, "KWD": 3, "LYD": 3, "OMR": 3, "TND": 3,
        // 4 digits
        "CLF": 4, "UYW": 4,
    ]

    private static let defaultExponent = 2

    /// The number of minor-unit digits for `code` (ISO 4217, any case).
    /// Unknown codes use the dominant convention of 2.
    public static func minorUnitExponent(for code: String) -> Int {
        exponents[code.uppercased()] ?? defaultExponent
    }
}
