import EluviumCore
import LumiKitUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    // MARK: - Properties

    private var warmupTask: Task<Void, Never>?

    // MARK: - Application Lifecycle

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Phase 1: Core Infrastructure
        configureLogging()
        configureLumiKit()

        // Phase 2: System Services
        setupMemoryWarningObserver()

        // Phase 3: Deferred Work
        deferPostLaunchWork()

        return true
    }

    deinit {
        warmupTask?.cancel()
    }

    // MARK: - Scene Configuration

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    // MARK: - Menu Bar

    /// The iPad and Mac menu bar (iPhone has no main menu; its screens
    /// register the same shortcuts as key commands): File ▸ Import… (⌘O)
    /// and Resolve (⌘↩, the front screen's primary action), and a Go menu
    /// with the five tabs (⌘1…⌘5). `MainTabBarController` performs them,
    /// selecting tabs through the tab model, never the tab bar's items.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }

        let importCommand = UIKeyCommand(
            title: "Import…",
            action: #selector(MainTabBarController.importFromMenu(_:)),
            input: "o",
            modifierFlags: .command
        )
        let resolveCommand = UIKeyCommand(
            title: "Resolve",
            action: #selector(PasteViewController.resolveFromMenu(_:)),
            input: "\r",
            modifierFlags: .command
        )
        builder.insertChild(UIMenu(options: .displayInline, children: [importCommand, resolveCommand]), atStartOfMenu: .file)

        let tabCommands = MainTabBarController.Tab.allCases.enumerated().map { index, tab in
            UIKeyCommand(
                title: tab.title,
                action: #selector(MainTabBarController.selectTabFromMenu(_:)),
                input: String(index + 1),
                modifierFlags: .command,
                propertyList: tab.identifier
            )
        }
        builder.insertSibling(UIMenu(title: "Go", identifier: Self.goMenuIdentifier, children: tabCommands), afterMenu: .view)
    }

    private static let goMenuIdentifier = UIMenu.Identifier("dev.luminoid.EluviumExample.go")

    // MARK: - Logging

    /// The framework writes under the `dev.luminoid.eluvium` subsystem at
    /// `.info` and up by default. Debug builds also keep its per-step and
    /// per-page detail lines, so a resolve can be followed step by step:
    /// `log stream --level debug --predicate 'subsystem == "dev.luminoid.eluvium"'`.
    private func configureLogging() {
        #if DEBUG
            ELVLog.minimumLevel = .debug
        #endif
    }

    // MARK: - LumiKit Configuration

    private func configureLumiKit() {
        LMKTheme.apply(.eluviumExample)
    }

    // MARK: - Memory Warning

    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning(_ notification: Notification) {
        NotificationCenter.default.post(name: AppNotification.memoryWarningReceived, object: nil)
    }

    // MARK: - Deferred Work

    /// Post-launch warmup: touching the store kicks off its background
    /// starter-pack load so the first tab interaction finds it ready
    /// (the store itself does the heavy lifting off the main thread).
    private func deferPostLaunchWork() {
        warmupTask = Task { @MainActor in
            await ExampleStore.shared.ready()
        }
    }
}
