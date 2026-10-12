import LumiKitUI
import UIKit

/// The app's inline status lines are LumiKit's `LMKStatusLabel`: stage
/// progress, warnings, and failure copy, colored per `LMKStatus` (`.neutral`
/// for progress and info, `.warning`, `.error`). A label, not a toast or
/// banner: the text is a live readout that persists and updates in place.
///
/// VoiceOver hears outcomes, not progress. `show(_:status:)` stays silent
/// (the label's `announces` is off), so a resolve's stage lines don't stack
/// up as announcements; the line that ends a flow goes through
/// `showOutcome(_:status:)`, which also reads it out.
extension LMKStatusLabel {
    /// Shows `message` and announces it: the final line of a resolve, walk,
    /// or import.
    func showOutcome(_ message: String, status: LMKStatus) {
        show(message, status: status)
        Self.announce(message)
    }

    /// Reads `message` to VoiceOver without touching any label (an outcome
    /// whose screen shows it elsewhere, such as a presented record).
    static func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
