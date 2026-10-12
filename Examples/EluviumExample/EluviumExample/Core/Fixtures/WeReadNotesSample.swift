/// A short 微信读书 (WeRead) notes export: the text the app's own
/// 笔记 → 导出 → 复制到剪贴板 produces, which readers save as a `.txt` file.
/// The Imports screen's sample runs it through the same recognition and
/// archive path a picked file takes, so the format is visible without one:
/// the loaded pack's `weread.notes` source recognizes it by content (a
/// `《title》` header and the `N个笔记` count) and maps each highlight and
/// thought to a `note` record. Unlike the three demo sources, the source
/// itself is catalog data; only this sample text is app-authored.
enum WeReadNotesSample {
    static let fileName = "活着-笔记.txt"

    /// The current (2024 on) grammar: header, then a chapter with one
    /// highlight and one thought on the passage it quotes.
    static let text = """
    《活着》

    余华
    2个笔记

    第一章

    ◆ 人是为活着本身而活着，而不是为了活着之外的任何事物所活着。

    ◆ 2024/03/05发表想法

    读到这里停了很久。

    原文：少年去游荡，中年想掘藏，老年做和尚。

    -- 来自微信读书
    """
}
