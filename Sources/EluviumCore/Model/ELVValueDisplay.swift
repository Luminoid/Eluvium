import Foundation

/// Formats `ELVValue` leaves for display — the default rendering the
/// record preview uses. A consumer that wants different formatting renders
/// records itself (mapper seam); this is the offered default, not a
/// requirement.
public enum ELVValueDisplay {
    public static func string(_ value: ELVValue) -> String {
        switch value {
        case let .text(text): text
        case let .number(number): ELVNumberFormat.compactString(number)
        case let .money(minorUnits, currencyCode): moneyString(minorUnits, currencyCode: currencyCode)
        case let .date(date, precision): dateString(date, precision: precision)
        case let .duration(seconds): duration(seconds)
        case let .url(url): url.absoluteString
        case let .phone(phone): phone
        case let .address(address): address.formatted ?? [address.street, address.locality, address.region].compactMap(\.self).joined(separator: ", ")
        case let .geo(latitude, longitude): String(format: "%.5f, %.5f", latitude, longitude)
        case let .media(media): media.url.absoluteString
        case let .rating(rating, scale): String(format: "%.1f / %.0f", rating, scale.upperBound)
        case let .tags(tags): tags.joined(separator: ", ")
        case let .list(values): values.map(string).joined(separator: ", ")
        case let .record(record): record.fields["title"].map(string) ?? record.kind
        case let .unknown(typeTag, _): "(\(typeTag))"
        }
    }

    /// Divides by the currency's real minor-unit exponent from the one
    /// `ELVCurrency` table the coercion engine also reads: JPY and XOF in
    /// whole units (exponent 0), KWD in fils (exponent 3), so a hardcoded
    /// /100 would render ¥500 as "5.0 JPY" and 12.345 KWD as "123.45 KWD".
    private static func moneyString(_ minorUnits: Int64, currencyCode: String) -> String {
        let exponent = ELVCurrency.minorUnitExponent(for: currencyCode)
        guard exponent > 0 else { return "\(minorUnits) \(currencyCode)" }
        var divisor: Int64 = 1
        for _ in 0 ..< exponent {
            divisor *= 10
        }
        let sign = minorUnits < 0 ? "-" : ""
        let magnitude = minorUnits.magnitude
        let major = magnitude / UInt64(divisor)
        let fraction = magnitude % UInt64(divisor)
        return "\(sign)\(major).\(String(format: "%0\(exponent)llu", fraction)) \(currencyCode)"
    }

    // DateFormatter costs ~1 ms per init; these run once per rendered cell
    // on the scroll path, so they are cached per precision. `DateFormatter`
    // is thread-safe (Apple documents it as such since iOS 7 / macOS 10.9),
    // which is what makes shared instances sound from any executor — this
    // type is non-isolated Core API, not EluviumUI's MainActor.
    private static let yearFormatter = utcFormatter("yyyy")
    private static let monthFormatter = utcFormatter("yyyy-MM")
    private static let dayFormatter = utcFormatter("yyyy-MM-dd")
    private static let timeFormatter = utcFormatter("yyyy-MM-dd HH:mm 'UTC'")

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    private static func dateString(_ date: Date, precision: ELVDatePrecision) -> String {
        let formatter = switch precision {
        case .year: yearFormatter
        case .month: monthFormatter
        // An unknown precision (a newer binary's token) renders at the
        // conservative middle.
        case .day, .unknown: dayFormatter
        case .time: timeFormatter
        }
        return formatter.string(from: date)
    }

    /// `1h 30m` / `4m 5s`. Public so hosts that render durations outside a
    /// record (an episode row, a player bar) share one spelling instead of
    /// keeping a twin formatter.
    public static func duration(_ seconds: TimeInterval) -> String {
        // Bounded before Int conversion: a hostile duration leaf must render
        // as garbage, not trap the process. The finiteness check comes
        // first — Swift's `max(.nan, 0)` returns NaN, so the clamp alone
        // would hand `Int(_:)` a NaN and trap.
        let bounded = seconds.isFinite ? min(max(seconds, 0), ELVBounds.numberMagnitude) : 0
        let total = Int(bounded)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(total % 60)s"
    }
}
