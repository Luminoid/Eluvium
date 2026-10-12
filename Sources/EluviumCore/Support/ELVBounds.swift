import Foundation

/// Numeric ceilings shared across extraction surfaces. Page, feed, and pack
/// numbers are hostile input; a bound applied in one place cannot drift
/// between the coercion engine and the feed normalizer.
public enum ELVBounds {
    /// The ceiling every duration leaf respects, a century in seconds. A
    /// clock form like `9223372036854775807:0` multiplies past `Int64`
    /// range, and a later `Int(seconds)` display conversion would trap;
    /// durations at or past the ceiling are rejected, not clamped, because
    /// no real media or activity lasts a century.
    public static let centurySeconds: TimeInterval = 3_200_000_000

    /// The magnitude every `.number` leaf stays under. Hosts convert
    /// numbers with `Int(_:)` / `Int64(_:)`, which trap past their range,
    /// and `1e300` is ordinary JSON-LD; below `9e15` every value also stays
    /// an exactly representable integer when it is one (2^53 ≈ 9.007e15).
    public static let numberMagnitude: Double = 9e15

    /// Whether `number` may ride a `.number` leaf: finite and under
    /// `numberMagnitude`.
    public static func isSafeNumber(_ number: Double) -> Bool {
        number.isFinite && abs(number) < numberMagnitude
    }

    /// `number` clamped into `±numberMagnitude`; nil for NaN or infinity.
    public static func clampedNumber(_ number: Double) -> Double? {
        guard number.isFinite else { return nil }
        return min(max(number, -numberMagnitude), numberMagnitude)
    }
}
