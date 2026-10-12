import Foundation
import Testing
@testable import EluviumCore

@Suite("Coercions")
struct ELVCoercionTests {
    private let context = ELVExtractionContext()

    private func coerce(_ raw: String, _ coercion: ELVCoercion, context: ELVExtractionContext? = nil) -> ELVValue? {
        ELVCoercionEngine.apply(coercion, to: .string(raw), context: context ?? self.context)
    }

    @Test
    func `Money infers the decimal convention from the last separator and emits minor units`() {
        let eur = ELVCoercion(kind: "money", currency: "EUR")
        #expect(coerce("1.299,00", eur) == .money(minorUnits: 129_900, currencyCode: "EUR"))
        #expect(coerce("€9,99", eur) == .money(minorUnits: 999, currencyCode: "EUR"))
        let usd = ELVCoercion(kind: "money", currency: "USD")
        #expect(coerce("$1,299.00", usd) == .money(minorUnits: 129_900, currencyCode: "USD"))
        #expect(coerce("1.299", usd) == .money(minorUnits: 129_900, currencyCode: "USD"))
        #expect(coerce("1,299", usd) == .money(minorUnits: 129_900, currencyCode: "USD"))
        #expect(coerce("54.99", usd) == .money(minorUnits: 5499, currencyCode: "USD"))
        #expect(coerce("-12.50", usd) == .money(minorUnits: -1250, currencyCode: "USD"))
    }

    @Test
    func `Money fails the candidate when no currency can be established`() {
        #expect(coerce("$54.99", ELVCoercion(kind: "money")) == nil)
        #expect(coerce("¥1200", ELVCoercion(kind: "money")) == nil)
        #expect(coerce("€9,99", ELVCoercion(kind: "money")) == .money(minorUnits: 999, currencyCode: "EUR"))
    }

    @Test
    func `Money reads currency from a selector before the constant`() {
        let context = ELVExtractionContext(document: ELVDocument(metas: ["product:price:currency": "gbp"]))
        let coercion = ELVCoercion(kind: "money", currency: "USD", currencyFrom: .meta("product:price:currency"))
        #expect(coerce("10.00", coercion, context: context) == .money(minorUnits: 1000, currencyCode: "GBP"))
    }

    @Test
    func `Zero-decimal currencies use their real exponent`() {
        #expect(coerce("1,200", ELVCoercion(kind: "money", currency: "JPY")) == .money(minorUnits: 1200, currencyCode: "JPY"))
        #expect(coerce("54.99", ELVCoercion(kind: "money", currency: "JPY")) == .money(minorUnits: 54, currencyCode: "JPY"))
    }

    @Test
    func `Numeric coercions clamp in Double space so 1e300 can never trap an Int conversion`() {
        #expect(coerce("1e300", ELVCoercion(kind: "int")) == .number(9e15))
        #expect(coerce("4.7 stars from 1,234 reviews", ELVCoercion(kind: "double")) == .number(4.7))
        #expect(coerce("not a number", ELVCoercion(kind: "double")) == nil)
        #expect(ELVCoercionEngine.apply(ELVCoercion(kind: "double"), to: .json(.number(.infinity)), context: context) == nil)
    }

    @Test
    func `Dates parse ISO 8601, date-only forms with their precision, and epochs`() throws {
        guard case let .date(iso, precision) = try #require(coerce("2026-08-11T10:30:00Z", ELVCoercion(kind: "date"))) else {
            Issue.record("Expected date")
            return
        }
        #expect(precision == .time)
        #expect(abs(iso.timeIntervalSince1970 - 1_786_185_000) < 86400 * 366)

        #expect(coerce("2026-08-11", ELVCoercion(kind: "date")) == .date(Date(timeIntervalSince1970: 1_786_406_400), precision: .day))
        #expect(coerce("1977", ELVCoercion(kind: "date")) == .date(Date(timeIntervalSince1970: 220_924_800), precision: .year))
        #expect(coerce("junk", ELVCoercion(kind: "date")) == nil)

        let formatted = coerce("08/11/2026", ELVCoercion(kind: "date", format: "MM/dd/yyyy"))
        #expect(formatted == .date(Date(timeIntervalSince1970: 1_786_406_400), precision: .day))
    }

    @Test
    func `Dates parse RFC 1123 through the shared ladder`() {
        // The coercion path used to lack RFC 822/1123; `ELVDateParser`
        // parses a page-sourced date like a feed-sourced one.
        #expect(coerce("Mon, 10 Aug 2026 12:00:00 GMT", ELVCoercion(kind: "date"))
            == .date(Date(timeIntervalSince1970: 1_786_363_200), precision: .time))
        #expect(coerce("Mon, 10 Aug 2026 05:00:00 -0700", ELVCoercion(kind: "date"))
            == .date(Date(timeIntervalSince1970: 1_786_363_200), precision: .time))
    }

    @Test
    func `Durations parse ISO 8601, clock forms, and bare seconds`() {
        #expect(coerce("PT1H30M", ELVCoercion(kind: "duration")) == .duration(5400))
        #expect(coerce("P1DT2H", ELVCoercion(kind: "duration")) == .duration(93600))
        #expect(coerce("1:02:03", ELVCoercion(kind: "duration")) == .duration(3723))
        #expect(coerce("45:10", ELVCoercion(kind: "duration")) == .duration(2710))
        #expect(coerce("5400", ELVCoercion(kind: "duration")) == .duration(5400))
        #expect(coerce("soon", ELVCoercion(kind: "duration")) == nil)
        // A feed's `<itunes:duration>P` plus a megabyte of digits was
        // quadratic in the component regex; past any real length it is
        // refused before the regex runs.
        let hostile = "P" + String(repeating: "9", count: 1_000_000)
        let elapsed = ContinuousClock().measure {
            #expect(coerce(hostile, ELVCoercion(kind: "duration")) == nil)
        }
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }

    @Test
    func `Duration leaves are bounded at a century whether they arrive as text or as a JSON number`() {
        let duration = ELVCoercion(kind: "duration")
        #expect(coerce("9223372036854775807:00", duration) == nil)
        #expect(ELVCoercionEngine.apply(duration, to: .json(.number(1e300)), context: context) == nil)
        #expect(ELVCoercionEngine.apply(duration, to: .json(.number(ELVBounds.centurySeconds)), context: context) == nil)
        #expect(ELVCoercionEngine.apply(duration, to: .json(.number(-1)), context: context) == nil)
        #expect(ELVCoercionEngine.apply(duration, to: .json(.number(90)), context: context) == .duration(90))
    }

    @Test
    func `JSON epochs pass the shared plausibility window and scale milliseconds`() {
        let date = ELVCoercion(kind: "date")
        let expected = ELVValue.date(Date(timeIntervalSince1970: 1_786_406_400), precision: .time)
        #expect(ELVCoercionEngine.apply(date, to: .json(.number(1_786_406_400)), context: context) == expected)
        #expect(ELVCoercionEngine.apply(date, to: .json(.number(1_786_406_400_000)), context: context) == expected)
        #expect(ELVCoercionEngine.apply(date, to: .json(.number(12)), context: context) == nil)
        #expect(ELVCoercionEngine.apply(date, to: .json(.number(1e300)), context: context) == nil)
        #expect(ELVDateParser.date(fromEpoch: .nan) == nil)
    }

    @Test
    func `URL coercion resolves relative forms and rejects non-web schemes`() throws {
        let base = try #require(URL(string: "https://example.com/page"))
        let context = ELVExtractionContext(url: base)
        #expect(try ELVCoercionEngine.apply(ELVCoercion(kind: "url"), to: .string("/img/a.jpg"), context: context)
            == .url(#require(URL(string: "https://example.com/img/a.jpg"))))
        #expect(ELVCoercionEngine.apply(ELVCoercion(kind: "url"), to: .string("javascript:alert(1)"), context: context) == nil)
        #expect(try ELVCoercionEngine.apply(ELVCoercion(kind: "url"), to: .string("//cdn.example.com/a.jpg"), context: context)
            == .url(#require(URL(string: "https://cdn.example.com/a.jpg"))))
    }

    @Test
    func `Geo parses lat,lng pairs and rejects out-of-range or null island values`() {
        #expect(coerce("43.7904, -110.7624", ELVCoercion(kind: "geo")) == .geo(latitude: 43.7904, longitude: -110.7624))
        #expect(coerce("99, 10", ELVCoercion(kind: "geo")) == nil)
        #expect(coerce("0,0", ELVCoercion(kind: "geo")) == nil)
    }

    @Test
    func `Geo reads latitude-longitude objects, quoted numbers included, under the same range rules`() throws {
        /// themeparks.wiki's `location` and schema.org GeoCoordinates are
        /// objects; `$.location` used to reach the coercion and fill nothing.
        func geo(_ json: String) throws -> ELVValue? {
            let node = try #require(ELVRawJSON.parse(Data(json.utf8)))
            return ELVCoercionEngine.apply(ELVCoercion(kind: "geo"), to: .json(node), context: context)
        }
        #expect(try geo(#"{"latitude": 28.388195, "longitude": -81.569324}"#) == .geo(latitude: 28.388195, longitude: -81.569324))
        #expect(try geo(#"{"latitude": "35.6329", "longitude": "139.8804"}"#) == .geo(latitude: 35.6329, longitude: 139.8804))
        #expect(try geo(#"{"lat": 44.34, "lon": -72.46}"#) == .geo(latitude: 44.34, longitude: -72.46))
        #expect(try geo(#"{"lat": 44.34, "lng": -72.46}"#) == .geo(latitude: 44.34, longitude: -72.46))
        #expect(try geo(#"{"latitude": 91, "longitude": 10}"#) == nil)
        #expect(try geo(#"{"latitude": 28.4}"#) == nil)
        #expect(try geo(#"{"latitude": 0, "longitude": 0}"#) == nil)
    }

    @Test
    func `Ratings validate against their declared scale`() {
        #expect(coerce("4.7", ELVCoercion(kind: "rating")) == .rating(value: 4.7, scale: 0 ... 5))
        #expect(coerce("8.6", ELVCoercion(kind: "rating", scaleMin: 0, scaleMax: 10)) == .rating(value: 8.6, scale: 0 ... 10))
        #expect(coerce("11", ELVCoercion(kind: "rating", scaleMin: 0, scaleMax: 10)) == nil)
    }

    @Test
    func `An unknown coercion kind invalidates the candidate`() {
        #expect(coerce("anything", ELVCoercion(kind: "hologram")) == nil)
    }

    @Test
    func `Tags split on commas and drop empties`() {
        #expect(coerce("hiking, waterfall, , views ", ELVCoercion(kind: "tags")) == .tags(["hiking", "waterfall", "views"]))
    }

    @Test
    func `Audio coerces to a typed media ref beside image and video`() throws {
        let url = try #require(URL(string: "https://p.scdn.co/mp3-preview/abc123"))
        #expect(coerce("https://p.scdn.co/mp3-preview/abc123", ELVCoercion(kind: "audio")) == .media(ELVMediaRef(url: url, kind: ELVMediaRef.audio)))
    }

    @Test
    func `A media ref on a dotless host does not coerce`() {
        // fujifilm-x.com's og:image is a bare attachment id on most lens
        // pages (2026-10-12): no record carries `https://92884` as its image.
        #expect(coerce("http://92884", ELVCoercion(kind: "image")) == nil)
        #expect(coerce("http://92884", ELVCoercion(kind: "url")) == nil)
    }

    @Test
    func `Three-decimal and CFA currencies use their ISO minor units`() {
        #expect(coerce("12.345", ELVCoercion(kind: "money", currency: "KWD")) == .money(minorUnits: 12345, currencyCode: "KWD"))
        #expect(coerce("KWD 1,250.500", ELVCoercion(kind: "money", currency: "KWD")) == .money(minorUnits: 1_250_500, currencyCode: "KWD"))
        // Tunisian prices write the comma as the decimal mark.
        #expect(coerce("12,345 DT", ELVCoercion(kind: "money", currency: "TND")) == .money(minorUnits: 12345, currencyCode: "TND"))
        #expect(coerce("500", ELVCoercion(kind: "money", currency: "XOF")) == .money(minorUnits: 500, currencyCode: "XOF"))
        #expect(coerce("1.500 F CFA", ELVCoercion(kind: "money", currency: "XOF")) == .money(minorUnits: 1500, currencyCode: "XOF"))
        // Pinned to ISO 4217, not the platform's cash digits: HUF, IDR, COP,
        // and PKR stay 2 and IQD 3 even where CLDR prints 0.
        for (code, exponent) in [
            ("KWD", 3), ("bhd", 3), ("OMR", 3), ("JOD", 3), ("TND", 3), ("IQD", 3), ("PYG", 0), ("UGX", 0), ("XOF", 0), ("XAF", 0), ("JPY", 0),
            ("CLF", 4), ("HUF", 2), ("IDR", 2), ("COP", 2), ("PKR", 2), ("USD", 2), ("ZZZ", 2),
        ] {
            #expect(ELVCurrency.minorUnitExponent(for: code) == exponent, "\(code)")
        }
    }

    @Test
    func `An uncoerced JSON number becomes a number leaf only inside the safe magnitude`() {
        func uncoerced(_ number: Double) -> ELVValue? {
            ELVCoercionEngine.apply(nil, to: .json(.number(number)), context: context)
        }
        #expect(uncoerced(4.5) == .number(4.5))
        #expect(uncoerced(8_999_999_999_999_998) == .number(8_999_999_999_999_998))
        // Past it the text form rides instead, so a host Int(_:) can't trap.
        #expect(uncoerced(1e300) == .text("1e+300"))
        #expect(uncoerced(-9e15) == .text("-9000000000000000.0"))
        #expect(ELVBounds.isSafeNumber(1e300) == false)
        #expect(ELVBounds.clampedNumber(.nan) == nil)
    }
}
