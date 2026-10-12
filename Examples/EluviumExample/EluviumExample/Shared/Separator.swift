/// The one inline separator user-visible text joins with. Every screen that
/// stitches a status line, a row's secondary text, or a section header from
/// parts uses this spelling, so a middle dot never drifts into double
/// spaces, triple spaces, or an em dash somewhere else.
enum Separator {
    static let dot = " · "
}
