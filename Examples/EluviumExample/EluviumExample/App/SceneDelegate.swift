import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    // MARK: - Properties

    var window: UIWindow?

    // MARK: - Scene Lifecycle

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let window = UIWindow(windowScene: windowScene)
        self.window = window

        // The tab bar controller is the root; each tab owns its own
        // AppNavigationController. Wrapping the whole tab UI in another
        // navigation controller would draw a second (system) nav bar above
        // every screen's LMKNavigationBar.
        window.rootViewController = MainTabBarController()
        window.makeKeyAndVisible()
    }
}
