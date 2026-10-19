import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var privacyCover: UIView?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .dark // app + Instagram page are always dark
        window.rootViewController = BrowserViewController()
        window.makeKeyAndVisible()
        self.window = window
        if connectionOptions.shortcutItem != nil { openSettingsSoon() }
    }

    // Long-press the home-screen icon → "Privacy".
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        openSettingsSoon()
        completionHandler(true)
    }

    private func openSettingsSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            (self.window?.rootViewController as? BrowserViewController)?.showSettings()
        }
    }

    // Hide the feed/DMs in the app switcher and from screenshots iOS takes of the app.
    func sceneWillResignActive(_ scene: UIScene) {
        guard let window, privacyCover == nil else { return }
        let cover = UIView()
        cover.backgroundColor = .black // fully opaque: nothing of the feed or DMs shows through
        cover.frame = window.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(cover)
        privacyCover = cover
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        privacyCover?.removeFromSuperview()
        privacyCover = nil
    }
}
