import Foundation

/// The one date-parsing ladder every date surface routes through: ISO 8601
/// with and without fractional seconds, RFC 822/1123, date-only forms, and
/// epoch seconds/millis. A page-sourced RFC 1123 date and a feed-sourced
/// ISO date parse identically because there is exactly one ladder.
///
/// All fixed formatters are cached: `DateFormatter` costs ~1 ms per init and
/// these run per field per record. Both classes are documented thread-safe;
/// `ISO8601DateFormatter` just lacks the Sendable annotation in the SDK,
/// which is what the `nonisolated(unsafe)` on those two asserts.
public enum ELVDateParser {
    // MARK: - Cached formatters

    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let iso = ISO8601DateFormatter()

    private static let rfc822Formatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z",
    ].map(utcFormatter)

    private static let dateOnlyFormatters: [(DateFormatter, String, ELVDatePrecision)] = [
        ("yyyy-MM-dd", ELVDatePrecision.day),
        ("yyyy-MM", .month),
        ("yyyy", .year),
    ].map { (utcFormatter($0.0), $0.0, $0.1) }

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    /// Pack-declared custom formats are arbitrary strings, so their
    /// formatters live in a bounded cache rather than a per-format static.
    private static let customFormatters = ELVBoundedCache<String, DateFormatter>(capacity: 32)

    // MARK: - Parsing

    /// Parses `string` through the full ladder. Returns the instant plus the
    /// precision the source text actually carried.
    public static func parse(_ string: String) -> (date: Date, precision: ELVDatePrecision)? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = isoFractional.date(from: trimmed) { return (date, .time) }
        if let date = iso.date(from: trimmed) { return (date, .time) }
        for formatter in rfc822Formatters {
            if let date = formatter.date(from: trimmed) { return (date, .time) }
        }
        for (formatter, pattern, precision) in dateOnlyFormatters where trimmed.count == pattern.count {
            if let date = formatter.date(from: trimmed) { return (date, precision) }
        }
        if let epoch = Double(trimmed), let date = date(fromEpoch: epoch) {
            return (date, .time)
        }
        return nil
    }

    /// An epoch number as an instant: seconds, or milliseconds past 3e10
    /// (the year 2920 in seconds, 1971 in millis, so the two ranges cannot
    /// overlap). Only values inside the plausibility window (1973 through
    /// the year 2096 in either unit) qualify; anything else is a mistyped
    /// or hostile number, not a date. The one rule for numeric epochs from
    /// pages, feeds, and script islands alike.
    public static func date(fromEpoch epoch: Double) -> Date? {
        guard epoch.isFinite, epoch > 1e8, epoch < 4e12 else { return nil }
        return Date(timeIntervalSince1970: epoch > 3e10 ? epoch / 1000 : epoch)
    }

    /// Parses with a pack-declared `DateFormat` pattern (UTC, POSIX locale).
    public static func parse(_ string: String, format: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = customFormatters.value(for: format) { utcFormatter(format) }
        return formatter.date(from: trimmed)
    }

    /// Canonical ISO 8601 for feed dates: every parseable input (RFC 822 or
    /// ISO alike) comes back in one form, so `published` is comparable
    /// across feeds. Unparseable strings return nil.
    public static func iso8601String(_ string: String) -> String? {
        parse(string).map { iso.string(from: $0.date) }
    }
}
