import Foundation
import Testing
@testable import EluviumCore

@Suite("Number formatting")
struct ELVNumberFormatTests {
    @Test
    func `Integer-valued doubles print without a fraction; huge, fractional, and non-finite values print as Swift does`() {
        #expect(ELVNumberFormat.compactString(6208) == "6208")
        #expect(ELVNumberFormat.compactString(-3) == "-3")
        #expect(ELVNumberFormat.compactString(0) == "0")
        #expect(ELVNumberFormat.compactString(4.7) == "4.7")
        // The magnitude guard: at and past 1e15 the Int64 path is never
        // taken, so the value prints as Swift prints the double.
        #expect(ELVNumberFormat.compactString(1e300) == "1e+300")
        #expect(ELVNumberFormat.compactString(1e16) == "1e+16")
        #expect(ELVNumberFormat.compactString(1e15) == String(1e15))
        #expect(ELVNumberFormat.compactString(1e15) != "1000000000000000")
        #expect(ELVNumberFormat.compactString(999_999_999_999_999) == "999999999999999")
        #expect(ELVNumberFormat.compactString(.infinity) == "inf")
        #expect(ELVNumberFormat.compactString(.nan) == "nan")
    }

    @Test
    func `Every number-to-text site agrees`() {
        #expect(ELVValueDisplay.string(.number(42)) == "42")
        #expect(ELVValueDisplay.string(.number(1e300)) == "1e+300")
        #expect(ELVSelectorEngine.stringForm(of: .number(42)) == .string("42"))
        #expect(ELVExtractedValue.json(.number(42)).singleString == "42")
        #expect(ELVJSONLDPlaceNode.asString(.number(42)) == "42")
        #expect(ELVJSONLDPlaceNode.asString(.number(1e300)) == "1e+300")
    }
}
