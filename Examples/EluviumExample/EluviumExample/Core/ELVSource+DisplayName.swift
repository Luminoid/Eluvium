import EluviumCore
import Foundation

extension ELVSource {
    /// The title as the app shows it, with pinyin after each Chinese run
    /// ("豆瓣 (Douban)", "小红书 (Xiaohongshu) short links"), so a reader who
    /// doesn't read Chinese can still tell the sources apart. Every surface
    /// that names a source (rows, headers, status lines) reads this.
    var displayName: String {
        ChineseName.annotated(title ?? id)
    }

    /// The title with each Chinese run replaced by its pinyin ("Douban"),
    /// so lists sort a Chinese source among the Latin ones by how it reads.
    var sortName: String {
        ChineseName.romanized(title ?? id)
    }

    /// Every kind this source's inference tables can produce, sorted; empty
    /// for a source that authors its kind.
    var inferredKinds: [String] {
        guard kind.isEmpty, let inference else { return [] }
        let tables = [inference.jsonldType, inference.categoryKeyword, inference.poiCategory, inference.hostBrand]
        return Set(tables.flatMap(\.values)).sorted()
    }
}

/// Pinyin for the Chinese runs in a title, word by word: Apple's Chinese
/// word tokenizer segments the run and transcribes each word ("微信读书" →
/// "Weixin Dushu"), and a one-character word joins the word before it, the
/// way brand names are written ("小红书" → "Xiaohongshu", not "Xiaohong
/// Shu").
enum ChineseName {
    /// One run of Chinese words and their pinyin.
    private struct Run {
        var range: Range<String.Index>
        var words: [String]
    }

    /// `text` with "(Pinyin)" after each Chinese run.
    static func annotated(_ text: String) -> String {
        replacingRuns(in: text) { original, pinyin in "\(original) (\(pinyin))" }
    }

    /// `text` with each Chinese run replaced by its pinyin.
    static func romanized(_ text: String) -> String {
        replacingRuns(in: text) { _, pinyin in pinyin }
    }

    private static func replacingRuns(in text: String, _ render: (Substring, String) -> String) -> String {
        // Most titles are Latin: skip the tokenizer for them.
        guard text.unicodeScalars.contains(where: \.properties.isIdeographic) else { return text }
        let runs = chineseRuns(in: text)
        var result = ""
        var cursor = text.startIndex
        for run in runs {
            result += text[cursor ..< run.range.lowerBound]
            result += render(text[run.range], run.words.joined(separator: " "))
            cursor = run.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    private static func chineseRuns(in text: String) -> [Run] {
        let string = text as CFString
        let tokenizer = CFStringTokenizerCreate(
            nil, string, CFRange(location: 0, length: CFStringGetLength(string)),
            kCFStringTokenizerUnitWord, Locale(identifier: "zh-Hans") as CFLocale
        )
        var runs: [Run] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard let range = Range(NSRange(location: tokenRange.location, length: tokenRange.length), in: text) else { continue }
            let word = text[range]
            guard word.unicodeScalars.allSatisfy(\.properties.isIdeographic),
                  let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                  let plain = latin.applyingTransform(.stripDiacritics, reverse: false)?.replacingOccurrences(of: " ", with: ""),
                  !plain.isEmpty
            else { continue }
            if var last = runs.last, last.range.upperBound == range.lowerBound {
                if word.count == 1 {
                    last.words[last.words.count - 1] += plain.lowercased()
                } else {
                    last.words.append(capitalized(plain))
                }
                last.range = last.range.lowerBound ..< range.upperBound
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(range: range, words: [capitalized(plain)]))
            }
        }
        return runs
    }

    private static func capitalized(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst().lowercased()
    }
}
