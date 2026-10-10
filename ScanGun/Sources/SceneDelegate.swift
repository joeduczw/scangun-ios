import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: ws)
        // 已配对直接进扫码页，否则进配对页
        window.rootViewController = Prefs.shared.isPaired
            ? ScanViewController()
            : PairingViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
