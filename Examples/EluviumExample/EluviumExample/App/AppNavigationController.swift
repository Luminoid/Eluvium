import LumiKitUI
import UIKit

/// App-wide navigation controller. Every screen draws its own
/// `LMKNavigationBar` (LumiKit's custom bar), so the system navigation bar
/// stays hidden for the entire stack; `LMKNavigationController` keeps the
/// interactive edge-swipe-to-go-back gesture working while it is hidden.
final class AppNavigationController: LMKNavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        setNavigationBarHidden(true, animated: false)
    }
}
