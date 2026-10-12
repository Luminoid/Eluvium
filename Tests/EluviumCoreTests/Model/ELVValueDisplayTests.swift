import Foundation
import Testing
@testable import EluviumCore

@Suite("Value display")
struct ELVValueDisplayTests {
    @Test
    func `Every leaf type renders non-empty with stable formats`() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let samples: [ELVValue] = [
            .text("hi"), .number(4), .money(minorUnits: 1299, currencyCode: "USD"),
            .date(Date(timeIntervalSince1970: 0), precision: .day), .duration(5400),
            .url(url), .phone("+1 415"), .geo(latitude: 1, longitude: 2),
            .rating(value: 4.5, scale: 0 ... 5), .tags(["a", "b"]),
        ]
        for value in samples {
            #expect(!ELVValueDisplay.string(value).isEmpty)
        }
        #expect(ELVValueDisplay.string(.number(4)) == "4")
        #expect(ELVValueDisplay.string(.duration(5400)) == "1h 30m")
        #expect(ELVValueDisplay.string(.rating(value: 4.5, scale: 0 ... 5)) == "4.5 / 5")
        #expect(ELVValueDisplay.string(.date(Date(timeIntervalSince1970: 0), precision: .year)) == "1970")
        #expect(ELVValueDisplay.string(.tags(["a", "b"])) == "a, b")
    }

    @Test
    func `Unknown and nested values degrade readably`() {
        let inner = ELVRecord(sourceId: "s", kind: "movie", fields: ["title": .text("Star Wars")])
        #expect(ELVValueDisplay.string(.record(inner)) == "Star Wars")
        #expect(ELVValueDisplay.string(.list([.text("x"), .number(2)])) == "x, 2")
        #expect(ELVValueDisplay.string(.unknown(typeTag: "hologram", raw: .null)) == "(hologram)")
        // A newer binary's precision renders at the conservative middle.
        #expect(ELVValueDisplay.string(.date(Date(timeIntervalSince1970: 0), precision: .unknown("fortnight"))) == "1970-01-01")
    }

    @Test
    func `Money divides by the currency's own minor-unit exponent`() {
        #expect(ELVValueDisplay.string(.money(minorUnits: 1299, currencyCode: "USD")) == "12.99 USD")
        #expect(ELVValueDisplay.string(.money(minorUnits: 12345, currencyCode: "KWD")) == "12.345 KWD")
        #expect(ELVValueDisplay.string(.money(minorUnits: 500, currencyCode: "XOF")) == "500 XOF")
        #expect(ELVValueDisplay.string(.money(minorUnits: 500, currencyCode: "JPY")) == "500 JPY")
        #expect(ELVValueDisplay.string(.money(minorUnits: -150, currencyCode: "EUR")) == "-1.50 EUR")
    }
}
