import Foundation

/// The intermediate value flowing through a candidate: what a selector
/// produced, before coercion types it.
public enum ELVExtractedValue: Sendable, Equatable {
    case string(String)
    case list([String])
    case json(ELVRawJSON)

    /// All string forms of this value.
    var strings: [String] {
        switch self {
        case let .string(string): [string]
        case let .list(list): list
        case let .json(json): json.stringValue.map { [$0] } ?? []
        }
    }

    /// The single string form, or `nil` when this is a multi-value.
    var singleString: String? {
        switch self {
        case let .string(string): string
        case let .list(list): list.count == 1 ? list[0] : nil
        case let .json(json):
            switch json {
            case let .string(string): string
            case let .number(number): ELVNumberFormat.compactString(number)
            case let .bool(bool): bool ? "true" : "false"
            default: nil
            }
        }
    }

    func mapStrings(_ transform: (String) -> String) -> Self {
        switch self {
        case let .string(string): .string(transform(string))
        case let .list(list): .list(list.map(transform))
        case let .json(json): json.stringValue.map { .string(transform($0)) } ?? self
        }
    }

    /// Whether this counts as "nothing extracted".
    var isEmpty: Bool {
        switch self {
        case let .string(string): string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .list(list): list.isEmpty || list.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case let .json(json): json == .null
        }
    }
}

/// A candidate's type coercion. Coercion is part of the acceptance
/// test: a failure invalidates the candidate, never the field, so a junk
/// value falls through to the next candidate instead of poisoning the record.
///
/// Not coded on its own: the pack spells a coercion as keys beside the
/// candidate's `from` (`as`, `format`, `currency`, `currencyFrom`, `scale`),
/// and `ELVCandidate`'s decoder builds this value from them.
public struct ELVCoercion: Sendable, Equatable {
    /// One of `knownKinds`. Unknown kinds invalidate the candidate.
    public var kind: String

    /// Every kind `ELVCoercionEngine` implements. The pack validator flags
    /// anything else as a diagnostic; the candidate itself just degrades.
    public static let knownKinds: Set<String> = [
        "text", "int", "double", "money", "date", "duration", "url",
        "phone", "geo", "image", "video", "audio", "rating", "tags",
    ]
    /// `date`: an explicit `DateFormatter` pattern.
    public var format: String?
    /// `money`: a constant ISO 4217 code when the page carries none.
    public var currency: String?
    /// `money`: where to read the currency from (`product:price:currency`
    /// meta, JSON-LD `priceCurrency`, …). Checked before `currency`.
    public var currencyFrom: ELVSelector?
    /// `rating`: the scale the source uses (default 0–5).
    public var scaleMin: Double?
    public var scaleMax: Double?

    public init(
        kind: String,
        format: String? = nil,
        currency: String? = nil,
        currencyFrom: ELVSelector? = nil,
        scaleMin: Double? = nil,
        scaleMax: Double? = nil
    ) {
        self.kind = kind
        self.format = format
        self.currency = currency
        self.currencyFrom = currencyFrom
        self.scaleMin = scaleMin
        self.scaleMax = scaleMax
    }
}

/// Applies coercions. Pure; every function returns `nil` on failure so the
/// candidate falls through.
enum ELVCoercionEngine {
    // Fixed patterns compiled once: the `range(of:options:.regularExpression)`
    // string API compiles a throwaway regex per call, and these run per
    // candidate per field per record (the ELVPipe static-pattern rule).
    // swiftlint:disable force_try
    private static let numberTokenRegex = try! NSRegularExpression(pattern: "-?\\d[\\d,.]*")
    private static let currencyCodeRegex = try! NSRegularExpression(pattern: "^[A-Z]{3}$")
    private static let moneyAmountRegex = try! NSRegularExpression(pattern: "-?\\d[\\d.,\u{00A0} ']*")
    private static let durationComponentRegex = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)([DHMS])")
    // swiftlint:enable force_try
    /// The longest string `parseDuration` reads (`P1Y2M10DT2H30M15.5S` is 20).
    private static let maxDurationLength = 64

    private static func mediaKind(for coercionKind: String) -> String {
        switch coercionKind {
        case "image": ELVMediaRef.image
        case "video": ELVMediaRef.video
        default: ELVMediaRef.audio
        }
    }

    static func apply(_ coercion: ELVCoercion?, to value: ELVExtractedValue, context: ELVExtractionContext) -> ELVValue? {
        guard let coercion else { return defaultValue(for: value) }
        switch coercion.kind {
        case "text":
            return value.singleString.map { .text($0) } ?? (value.strings.isEmpty ? nil : .text(value.strings.joined(separator: ", ")))
        case "int":
            // Clamped like every .number leaf (`ELVBounds.numberMagnitude`):
            // arbitrary page JSON-LD contains 1e300, and an unclamped leaf
            // traps a host's later Int conversion.
            return parseDouble(value).flatMap { ELVBounds.clampedNumber($0.rounded()) }.map { .number($0) }
        case "double":
            return parseDouble(value).flatMap(ELVBounds.clampedNumber).map { .number($0) }
        case "money":
            return parseMoney(value, coercion: coercion, context: context)
        case "date":
            return parseDate(value, format: coercion.format)
        case "duration":
            return parseDuration(value)
        case "url":
            return parseURL(value, context: context).map { .url($0) }
        case "phone":
            guard let string = value.singleString?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty,
                  string.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
            return .phone(string)
        case "geo":
            return parseGeo(value)
        case "image", "video", "audio":
            // Media refs are fetched by the host app for display, where ATS
            // refuses plain http, so a page's `http://` og:image becomes an
            // https media ref — the same upgrade the pipeline's front door
            // applies to pasted links. Plain `url` fields stay as written:
            // they are opened, not fetched.
            return parseURL(value, context: context).map { url in
                .media(ELVMediaRef(url: ELVURLPolicy.httpsUpgraded(url), kind: mediaKind(for: coercion.kind)))
            }
        case "rating":
            guard let double = parseDouble(value) else { return nil }
            let scale = (coercion.scaleMin ?? 0) ... max(coercion.scaleMax ?? 5, (coercion.scaleMin ?? 0) + 1)
            guard scale.contains(double) else { return nil }
            return .rating(value: double, scale: scale)
        case "tags":
            let tags = value.strings
                .flatMap { $0.components(separatedBy: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return tags.isEmpty ? nil : .tags(tags)
        default:
            return nil
        }
    }

    /// No declared coercion: strings become text, JSON scalars keep their
    /// natural type. A JSON number becomes `.number` only inside the safe
    /// magnitude (`ELVBounds.isSafeNumber`); past it (`1e300` in page
    /// JSON-LD) it keeps its text form, so no host `Int(_:)` conversion of
    /// an uncoerced field can trap.
    private static func defaultValue(for value: ELVExtractedValue) -> ELVValue? {
        switch value {
        case let .string(string): .text(string)
        case let .list(list): list.isEmpty ? nil : .tags(list)
        case let .json(json):
            switch json {
            case let .string(string): .text(string)
            case let .number(number): numberLeaf(number)
            case let .bool(bool): .text(bool ? "true" : "false")
            default: nil
            }
        }
    }

    // MARK: - Numbers

    /// A JSON number as a leaf: `.number` inside `ELVBounds.isSafeNumber`,
    /// its text form past it.
    private static func numberLeaf(_ number: Double) -> ELVValue {
        guard ELVBounds.isSafeNumber(number) else { return .text(ELVNumberFormat.compactString(number)) }
        return .number(number)
    }

    /// Parses a Double from messy page text ("4.7 stars", "1,234"). Clamps
    /// in Double space: arbitrary page JSON-LD contains `1e300`.
    static func parseDouble(_ value: ELVExtractedValue) -> Double? {
        if case let .json(json) = value, let number = json.numberValue {
            return number.isFinite ? number : nil
        }
        guard var string = value.singleString?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        string = string.replacingOccurrences(of: "\u{2212}", with: "-")
        if let direct = Double(string) { return direct.isFinite ? direct : nil }
        // Fall back to the first numeric token in the text.
        guard let match = numberTokenRegex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let matchRange = Range(match.range, in: string) else { return nil }
        var token = String(string[matchRange])
        // "1,234" / "1,234.5": treat commas as grouping when a dot is the last separator or none follows.
        if token.contains(","), token.contains(".") {
            token = token.replacingOccurrences(of: ",", with: "")
        } else if token.contains(",") {
            let parts = token.split(separator: ",")
            token = parts.count == 2 && (parts[1].count == 1 || parts[1].count == 2)
                ? token.replacingOccurrences(of: ",", with: ".")
                : token.replacingOccurrences(of: ",", with: "")
        }
        guard let parsed = Double(token), parsed.isFinite else { return nil }
        return parsed
    }

    // MARK: - Money

    /// Currency-honest money: requires a currency (from selector or
    /// const), infers the decimal convention from the last separator, emits
    /// Int64 minor units, and fails without a currency rather than
    /// mislabeling.
    private static func parseMoney(_ value: ELVExtractedValue, coercion: ELVCoercion, context: ELVExtractionContext) -> ELVValue? {
        var currencyCode: String?
        if let currencyFrom = coercion.currencyFrom,
           let extracted = ELVSelectorEngine.evaluate(currencyFrom, context: context)?.singleString {
            let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !trimmed.isEmpty { currencyCode = trimmed }
        }
        if currencyCode == nil, let constant = coercion.currency {
            currencyCode = constant.uppercased()
        }
        if currencyCode == nil, let string = value.singleString {
            currencyCode = inferCurrencySymbol(string)
        }
        guard let currency = currencyCode,
              currencyCodeRegex.firstMatch(in: currency, range: NSRange(currency.startIndex..., in: currency)) != nil else { return nil }

        guard let string = value.singleString else { return nil }
        guard let amountMatch = moneyAmountRegex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let amountRange = Range(amountMatch.range, in: string) else { return nil }
        var digits = String(string[amountRange])
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")

        // Infer the decimal convention from the last separator. A lone
        // separator is decimal when it has 1–2 trailing digits, or up to the
        // currency's own exponent (12.345 KWD is 12 dinars 345 fils); any
        // other count is grouping ("1.299" EUR is 1299).
        let exponent = ELVCurrency.minorUnitExponent(for: currency)
        let lastDot = digits.range(of: ".", options: .backwards)
        let lastComma = digits.range(of: ",", options: .backwards)
        var decimalSeparator: String?
        if let dot = lastDot, let comma = lastComma {
            decimalSeparator = dot.lowerBound > comma.lowerBound ? "." : ","
        } else if let single = lastDot ?? lastComma {
            let trailing = digits.distance(from: single.upperBound, to: digits.endIndex)
            let separator = String(digits[single.lowerBound])
            let occurrences = digits.components(separatedBy: separator).count - 1
            decimalSeparator = (trailing >= 1 && trailing <= max(2, exponent) && occurrences == 1) ? separator : nil
        }

        var fractional = ""
        if let separator = decimalSeparator, let range = digits.range(of: separator, options: .backwards) {
            fractional = String(digits[range.upperBound...]).filter(\.isNumber)
            digits = String(digits[..<range.lowerBound])
        }
        let integral = digits.filter { $0.isNumber || $0 == "-" }
        guard integral.contains(where: \.isNumber) || !fractional.isEmpty else { return nil }

        // The fraction scales to exactly `exponent` digits: padded when
        // short, cut when longer than the currency's minor unit.
        let kept = fractional.prefix(exponent)
        let padded = kept + String(repeating: "0", count: exponent - kept.count)
        let negative = integral.hasPrefix("-")
        let magnitudeDigits = integral.filter(\.isNumber) + padded
        guard let magnitude = Int64(magnitudeDigits.isEmpty ? "0" : String(magnitudeDigits)) else { return nil }
        return .money(minorUnits: negative ? -magnitude : magnitude, currencyCode: currency)
    }

    /// The ISO code a currency glyph pins down unambiguously. `$` (USD, CAD,
    /// AUD, MXN, …) and `¥` (JPY, CNY) each name several currencies and
    /// infer nothing: the candidate then needs `currency` or `currencyFrom`,
    /// or it fails rather than mislabeling the amount.
    private static func inferCurrencySymbol(_ string: String) -> String? {
        if string.contains("€") { return "EUR" }
        if string.contains("£") { return "GBP" }
        if string.contains("₩") { return "KRW" }
        if string.contains("₹") { return "INR" }
        return nil
    }

    // MARK: - Dates

    private static func parseDate(_ value: ELVExtractedValue, format: String?) -> ELVValue? {
        if case let .json(json) = value, let epoch = json.numberValue {
            // The one epoch rule (plausibility window, seconds-vs-millis).
            return ELVDateParser.date(fromEpoch: epoch).map { .date($0, precision: .time) }
        }
        guard let string = value.singleString?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }

        if let format {
            guard let date = ELVDateParser.parse(string, format: format) else { return nil }
            return .date(date, precision: precision(ofFormat: format))
        }
        // The shared ladder (`ELVDateParser`: ISO ± fractional seconds,
        // RFC 822/1123, date-only forms with their precision, epoch s/ms):
        // one set of cached formatters, so a page-sourced date parses
        // exactly like a feed-sourced one.
        guard let parsed = ELVDateParser.parse(string) else { return nil }
        return .date(parsed.date, precision: parsed.precision)
    }

    private static func precision(ofFormat format: String) -> ELVDatePrecision {
        if format.contains("H") || format.contains("h") || format.contains("m") { return .time }
        if format.contains("d") { return .day }
        if format.contains("M") { return .month }
        return .year
    }

    // MARK: - Durations

    /// Accepts ISO 8601 (`PT1H30M`), clock forms (`1:30:00`, `45:10`), and
    /// bare seconds.
    private static func parseDuration(_ value: ELVExtractedValue) -> ELVValue? {
        if case let .json(json) = value, let seconds = json.numberValue {
            return boundedDuration(seconds)
        }
        guard let string = value.singleString?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !string.isEmpty else { return nil }
        // No real duration (ISO, clock, or seconds) is longer than this, and
        // the component regex retries a digit run from every digit: a feed's
        // `<itunes:duration>P` plus megabytes of digits was quadratic.
        guard string.utf16.count <= maxDurationLength else { return nil }

        if string.hasPrefix("P") {
            var total: TimeInterval = 0
            let regex = durationComponentRegex
            let timePart = string.contains("T") ? String(string.drop(while: { $0 != "T" })) : string
            let dayPart = String(string.prefix(while: { $0 != "T" }))
            let nsDay = dayPart as NSString
            for match in regex.matches(in: dayPart, range: NSRange(location: 0, length: nsDay.length)) {
                let amount = Double(nsDay.substring(with: match.range(at: 1))) ?? 0
                if nsDay.substring(with: match.range(at: 2)) == "D" { total += amount * 86400 }
            }
            let nsTime = timePart as NSString
            for match in regex.matches(in: timePart, range: NSRange(location: 0, length: nsTime.length)) {
                let amount = Double(nsTime.substring(with: match.range(at: 1))) ?? 0
                switch nsTime.substring(with: match.range(at: 2)) {
                case "H": total += amount * 3600
                case "M": total += amount * 60
                case "S": total += amount
                default: break
                }
            }
            return total > 0 ? boundedDuration(total) : nil
        }

        let clockParts = string.split(separator: ":").map(String.init)
        if clockParts.count >= 2, clockParts.count <= 3, clockParts.allSatisfy({ Int($0) != nil }) {
            let numbers = clockParts.compactMap { Double($0) }
            let seconds: TimeInterval = numbers.count == 3
                ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
                : numbers[0] * 60 + numbers[1]
            return boundedDuration(seconds)
        }
        if let seconds = Double(string), seconds >= 0 {
            return boundedDuration(seconds)
        }
        return nil
    }

    /// Rejects absurd durations instead of clamping (see
    /// `ELVBounds.centurySeconds`): every duration leaf, whether parsed from
    /// text or read as a JSON number, passes this one gate.
    private static func boundedDuration(_ seconds: TimeInterval) -> ELVValue? {
        guard seconds >= 0, seconds.isFinite, seconds < ELVBounds.centurySeconds else { return nil }
        return .duration(seconds)
    }

    /// Seconds from any supported duration text — ISO 8601 (`PT1H2M`), clock
    /// forms, bare seconds — bounded like every duration leaf. The feed
    /// path's `itunes:duration` shares this ladder instead of keeping its
    /// own clock-only copy.
    static func durationSeconds(from string: String) -> Double? {
        guard case let .duration(seconds)? = parseDuration(.string(string)) else { return nil }
        return seconds
    }

    // MARK: - URLs & geo

    /// Through `ELVURLPolicy`, the one scheme-allowlisted resolution (trims,
    /// resolves `//`-prefixed forms as https, admits http(s) only), shared
    /// with the `resolveURL` pipe so a coerced URL and a piped one can never
    /// disagree.
    private static func parseURL(_ value: ELVExtractedValue, context: ELVExtractionContext) -> URL? {
        guard let string = value.singleString else { return nil }
        return ELVURLPolicy.resolve(string, relativeTo: context.url)
    }

    /// Three shapes: a `[lat, lng]` array, a `"lat,lng"` string, or an
    /// object keyed `latitude`/`longitude` (schema.org GeoCoordinates, the
    /// themeparks.wiki entity) or `lat` with `lng`/`lon`. Numeric strings
    /// count, since JSON-LD often quotes them.
    private static func parseGeo(_ value: ELVExtractedValue) -> ELVValue? {
        let parts: [Double]
        if case let .json(json) = value, let array = json.arrayValue {
            parts = array.compactMap(\.numberValue)
        } else if case let .json(json) = value, let object = json.objectValue {
            func coordinate(_ keys: [String]) -> Double? {
                for key in keys {
                    if let number = object[key]?.numberValue { return number }
                    if let string = object[key]?.stringValue, let number = Double(string.trimmingCharacters(in: .whitespaces)) { return number }
                }
                return nil
            }
            guard let latitude = coordinate(["latitude", "lat"]), let longitude = coordinate(["longitude", "lng", "lon"]) else { return nil }
            parts = [latitude, longitude]
        } else if case let .list(list) = value {
            parts = list.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else if let string = value.singleString {
            parts = string.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        } else {
            return nil
        }
        guard parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180, parts != [0, 0] else { return nil }
        return .geo(latitude: parts[0], longitude: parts[1])
    }
}
