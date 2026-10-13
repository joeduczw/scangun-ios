import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        // 每次打开 APP 自动封存上次的活动文件（本次扫码开新文件，对齐安卓版）
        ScanStorage.sealStaleFile()
        let window = UIWindow(windowScene: ws)
        // 已配对直接进扫码页，否则进配对页
        window.rootViewController = Prefs.shared.isPaired
            ? ScanViewController()
            : PairingViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
