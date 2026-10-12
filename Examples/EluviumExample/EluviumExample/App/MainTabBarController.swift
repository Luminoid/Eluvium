import LumiKitUI
import UIKit

/// The five tabs on LumiKit's `LMKTabBarController`: lazy roots (launch
/// pays for the Paste screen only), identifier-based selection through the
/// `UITab` model (never the tab bar's own items), the theme's bar
/// appearance, and an `AppNavigationController` per tab.
///
/// Keyboard: iPhone has no main menu, so it keeps LumiKit's ⌘1…⌘5 tab
/// commands. iPad and Mac build the menu bar (`AppDelegate.buildMenu`):
/// Go ▸ the tabs, File ▸ Import… and Resolve. The menu's commands land here
/// through the responder chain; a screen action (Resolve) is handed to the
/// screen in front. Like LumiKit's own commands, they stand down while a
/// sheet is up.
final class MainTabBarController: LMKTabBarController {
    // MARK: - Types

    /// The tabs in bar order.
    enum Tab: String, CaseIterable {
        case paste
        case sources
        case catalogs
        case imports
        case identity

        var identifier: String { rawValue }

        var title: String {
            switch self {
            case .paste: "Paste"
            case .sources: "Sources"
            case .catalogs: "Catalogs"
            case .imports: "Imports"
            case .identity: "Identity"
            }
        }

        var systemImage: String {
            switch self {
            case .paste: "doc.on.clipboard"
            case .sources: "shippingbox"
            case .catalogs: "square.stack.3d.up"
            case .imports: "square.and.arrow.down"
            case .identity: "link"
            }
        }

        @MainActor
        func makeRoot() -> UIViewController {
            switch self {
            case .paste: PasteViewController()
            case .sources: SourcesViewController()
            case .catalogs: CatalogsViewController()
            case .imports: ImportsViewController()
            case .identity: IdentityViewController()
            }
        }
    }

    // MARK: - Constants

    /// The menu bar commands this controller performs itself.
    private static let menuActions: Set<Selector> = [
        #selector(selectTabFromMenu(_:)),
        #selector(importFromMenu(_:)),
    ]

    /// The menu bar commands the screen in front performs (Paste resolves,
    /// Identity confirms its first suggestion); disabled elsewhere.
    private static let screenActions: Set<Selector> = [
        #selector(PasteViewController.resolveFromMenu(_:)),
    ]

    // MARK: - Init

    init() {
        super.init(
            tabs: Tab.allCases.map { tab in
                LMKTab(identifier: tab.identifier, title: tab.title, systemImage: tab.systemImage) { tab.makeRoot() }
            },
            navigationControllerFactory: { AppNavigationController(rootViewController: $0) }
        )
        // Registering ⌘1…⌘5 here and in the menu bar would leave UIKit to
        // pick one; the menu bar owns them wherever it exists.
        tabKeyCommandsEnabled = UIDevice.current.userInterfaceIdiom == .phone
    }

    // MARK: - Actions

    /// Go ▸ <tab> (⌘1…⌘5) on iPad and Mac.
    @objc func selectTabFromMenu(_ sender: Any?) {
        guard let identifier = (sender as? UICommand)?.propertyList as? String else { return }
        selectTab(identifier: identifier)
    }

    /// File ▸ Import… (⌘O): the Imports tab, then its document picker.
    @objc func importFromMenu(_: Any?) {
        selectTab(identifier: Tab.imports.identifier)
        (rootViewController(for: Tab.imports.identifier) as? ImportsViewController)?.pickFile()
    }

    // MARK: - Menu validation

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if Self.menuActions.contains(action) {
            return presentedViewController == nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Checks the selected tab in the Go menu.
    override func validate(_ command: UICommand) {
        super.validate(command)
        guard command.action == #selector(selectTabFromMenu(_:)), let identifier = command.propertyList as? String else { return }
        command.state = identifier == selectedIdentifier ? .on : .off
    }

    /// Hands a screen action to the screen in front when nothing below this
    /// controller in the responder chain answered it (nothing focused).
    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if Self.screenActions.contains(action), presentedViewController == nil,
           let screen = (selectedViewController as? UINavigationController)?.topViewController,
           screen.canPerformAction(action, withSender: sender) {
            return screen
        }
        return super.target(forAction: action, withSender: sender)
    }
}
