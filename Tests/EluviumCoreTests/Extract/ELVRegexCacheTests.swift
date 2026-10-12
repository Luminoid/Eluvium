import Foundation
import Testing
@testable import EluviumCore

/// The evaluation budget: the input cap bounds how much a pack pattern
/// reads, the budget bounds what it costs, so a backtracking pattern over a
/// hostile body is a miss instead of a hang.
@Suite("Pack regex evaluation budget")
struct ELVRegexCacheTests {
    @Test
    func `A catastrophic backtrack stops at the budget and reads as a miss`() throws {
        // `(a+)+$` against a run of a's ending in a non-match is exponential.
        let regex = try #require(ELVRegexCache.regex("(a+)+$"))
        let hostile = String(repeating: "a", count: 40) + "!"
        let elapsed = ContinuousClock().measure {
            #expect(ELVRegexCache.boundedMatches(of: regex, in: hostile, budget: .milliseconds(100)) == nil)
        }
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test
    func `Within budget, matches honor the limit and rewrites match Foundation's`() throws {
        let regex = try #require(ELVRegexCache.regex("(\\d+)-(\\d+)"))
        let text = "1-2, 30-40, 500-600"
        let matches = try #require(ELVRegexCache.boundedMatches(of: regex, in: text, limit: 2))
        #expect(matches.count == 2)
        let bounded = ELVRegexCache.boundedReplacing(regex, in: text, template: "$2..$1")
        let foundation = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$2..$1")
        #expect(bounded == foundation)
        #expect(bounded == "2..1, 40..30, 600..500")
        #expect(ELVRegexCache.boundedReplacing(regex, in: "no digits", template: "x") == "no digits")
    }
}
