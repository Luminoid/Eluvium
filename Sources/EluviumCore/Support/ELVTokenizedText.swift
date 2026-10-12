/// Word-bounded keyword containment with `\b` semantics and no pattern
/// compile: the text is lowercased and tokenized once, then every keyword
/// probe is a set lookup. A single-word keyword must be a whole token ("bar"
/// never matches "barn"); a multi-word keyword must appear verbatim AND
/// word-for-word in the token set ("embed and breakfast" contains the
/// phrase "bed and breakfast" but not the token "bed", so it does not
/// match). Keyword tables here are pack-authored or binary-owned strings; a
/// keyword never becomes a regex pattern.
struct ELVTokenizedText {
    let lowered: String
    let tokens: Set<String>

    init(_ text: String) {
        lowered = text.lowercased()
        tokens = Set(Self.words(in: lowered))
    }

    /// Whether `keyword` (already lowercased) occurs word-bounded in the text.
    func contains(keyword: String) -> Bool {
        let keywordTokens = Self.words(in: keyword)
        guard keywordTokens.count > 1 else { return tokens.contains(keywordTokens.first ?? keyword) }
        return lowered.contains(keyword) && keywordTokens.allSatisfy(tokens.contains)
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
