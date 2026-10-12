/// One spelling for numbers that arrived as page or feed JSON: an
/// integer-valued double prints without a fractional part ("6208", never
/// "6208.0"), anything else prints as Swift does. The magnitude guard is
/// load-bearing, not cosmetic: `Int64(_:)` traps past its range, and `1e300`
/// is ordinary JSON-LD, so the integer path is taken only below 1e15.
enum ELVNumberFormat {
    static func compactString(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }
}
