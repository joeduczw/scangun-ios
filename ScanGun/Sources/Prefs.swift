import Foundation
import UIKit

/// 配置持久化（UserDefaults）
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    private let kHost = "host"
    private let kPort = "port"
    private let kToken = "token"
    private let kDeviceName = "deviceName"
    private let kAutoMode = "autoMode"       // 自动扫描模式（默认手动）
    private let kResend = "resendEnabled"    // 历史点击重发（默认关）

    var host: String {
        get { d.string(forKey: kHost) ?? "" }
        set { d.set(newValue, forKey: kHost) }
    }
    var port: Int {
        get { d.object(forKey: kPort) as? Int ?? 8899 }
        set { d.set(newValue, forKey: kPort) }
    }
    var token: String {
        get { d.string(forKey: kToken) ?? "" }
        set { d.set(newValue, forKey: kToken) }
    }
    var isPaired: Bool { !host.isEmpty && !token.isEmpty }

    var deviceName: String {
        get {
            if let n = d.string(forKey: kDeviceName), !n.isEmpty { return n }
            let n = UIDevice.current.model + "-" + String(format: "%03d", Int.random(in: 100...999))
            d.set(n, forKey: kDeviceName)
            return n
        }
        set { d.set(newValue, forKey: kDeviceName) }
    }

    var autoMode: Bool {
        get { d.bool(forKey: kAutoMode) }
        set { d.set(newValue, forKey: kAutoMode) }
    }
    var resendEnabled: Bool {
        get { d.bool(forKey: kResend) }
        set { d.set(newValue, forKey: kResend) }
    }
}
