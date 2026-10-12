import Foundation

/// The computed param gating `cdn.syndication.twimg.com`'s tweet-result
/// JSON (`x.syndicationToken`): `((id / 1e15) · π).toString(36)` with
/// `0` and `.` stripped. The computation is an undocumented client detail
/// that can change; its churn surfaces as an empty `{}` response mapped to
/// `formatDrift`, never silence.
enum ELVSyndicationToken {
    static func compute(tweetId: String) -> String? {
        guard let id = Double(tweetId), id > 0 else { return nil }
        let value = id / 1e15 * Double.pi
        let token = doubleToRadix36(value)
            .replacingOccurrences(of: "0", with: "")
            .replacingOccurrences(of: ".", with: "")
        return token.isEmpty ? nil : token
    }

    /// JavaScript `Number.prototype.toString(36)` for finite positive
    /// doubles: integer digits in base 36, then fractional digits emitted
    /// with V8's delta-termination and carry-propagating rounding, so the
    /// output matches what X's own client computes character for character.
    private static func doubleToRadix36(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")

        var integer = value.rounded(.down)
        var fraction = value - integer

        var fractionalDigits: [Int] = []
        if fraction > 0 {
            // Half an ulp of the input: the point past which further digits
            // carry no information.
            var delta = max(0.5 * value.ulp, Double.leastNonzeroMagnitude)
            var carryIntoInteger = false
            repeat {
                fraction *= 36
                delta *= 36
                let digit = Int(fraction)
                fraction -= Double(digit)
                fractionalDigits.append(digit)
                if fraction > 0.5 || (fraction == 0.5 && digit % 2 == 1), fraction + delta > 1 {
                    // Round up, propagating the carry toward the integer part.
                    var index = fractionalDigits.count - 1
                    while true {
                        if index < 0 {
                            carryIntoInteger = true
                            break
                        }
                        if fractionalDigits[index] + 1 < 36 {
                            fractionalDigits[index] += 1
                            break
                        }
                        fractionalDigits[index] = 0
                        index -= 1
                    }
                    break
                }
            } while fraction >= delta && fractionalDigits.count < 64
            if carryIntoInteger {
                integer += 1
            }
        }

        var integerDigits = ""
        if integer < 1 {
            integerDigits = "0"
        }
        while integer >= 1 {
            let digit = integer.truncatingRemainder(dividingBy: 36)
            integerDigits.insert(digits[Int(digit)], at: integerDigits.startIndex)
            integer = (integer - digit) / 36
        }

        guard !fractionalDigits.isEmpty else { return integerDigits }
        return integerDigits + "." + String(fractionalDigits.map { digits[$0] })
    }
}
