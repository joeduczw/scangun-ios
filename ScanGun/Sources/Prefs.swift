import Foundation
import UIKit

/// 配置持久化（UserDefaults），字段与安卓版一一对应
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    private let kHost = "host"
    private let kPort = "port"
    private let kToken = "token"
    private let kDeviceName = "deviceName"
    private let kManualMode = "manualMode"       // 扫描模式（默认手动：按一下扫一次）
    private let kStorageMode = "storageMode"     // 存储扫描开关（默认开启：只存不发）
    private let kSendIntervalMs = "sendIntervalMs" // 文件批量发送条间隔（默认500ms）
    private let kVerifyMode = "verifyMode"       // 商品验证开关（每次启动强制开启，可临时关闭）
    private let kVerifyInnerPort = "verifyInnerPort" // 商品验证内部端口（默认171）
    private let kVerifyOuterPort = "verifyOuterPort" // 商品验证外部端口（默认172）
    private let kVerifyUseOuter = "verifyUseOuter"   // 验证地址回退标志（false=内部 192.168.1.179，true=外部 www.joedu.vip）
    private let kPairHistory = "pair_history"    // 配对历史（连接成功的客户机记录）

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

    /// 扫描模式：true=手动（按一下扫描按钮扫一次），false=自动连续扫描
    var manualMode: Bool {
        get { d.object(forKey: kManualMode) == nil ? true : d.bool(forKey: kManualMode) }
        set { d.set(newValue, forKey: kManualMode) }
    }

    /// 存储扫描开关（默认开启）：开启时扫码只存不发，统一在「储存发送」页批量发送
    var storageMode: Bool {
        get { d.object(forKey: kStorageMode) == nil ? true : d.bool(forKey: kStorageMode) }
        set { d.set(newValue, forKey: kStorageMode) }
    }

    /// 文件批量发送的条间隔（毫秒，默认500）：电脑程序处理慢时调大，防止连续敲入丢码
    var sendIntervalMs: Int {
        get { d.object(forKey: kSendIntervalMs) as? Int ?? 500 }
        set { d.set(newValue, forKey: kSendIntervalMs) }
    }

    /// 商品验证开关：扫码先经单据核对系统验证，完整匹配才发送/存储。
    /// 每次启动 APP 强制开启（主界面 viewDidLoad 写 true），用户可临时关闭但不记忆关闭状态
    var verifyMode: Bool {
        get { d.object(forKey: kVerifyMode) == nil ? true : d.bool(forKey: kVerifyMode) }
        set { d.set(newValue, forKey: kVerifyMode) }
    }

    /// 商品验证内部端口（默认171）：验证地址 http://192.168.1.179:<端口>/api.php
    var verifyInnerPort: Int {
        get { d.object(forKey: kVerifyInnerPort) as? Int ?? 171 }
        set { d.set(newValue, forKey: kVerifyInnerPort) }
    }

    /// 商品验证外部端口（默认172）：验证地址 http://www.joedu.vip:<端口>/api.php
    var verifyOuterPort: Int {
        get { d.object(forKey: kVerifyOuterPort) as? Int ?? 172 }
        set { d.set(newValue, forKey: kVerifyOuterPort) }
    }

    /// 验证地址回退标志：记住最近一次验证成功的地址（false=内部，true=外部），
    /// 网络异常时自动切换到另一个地址重试并记住切换结果
    var verifyUseOuter: Bool {
        get { d.bool(forKey: kVerifyUseOuter) }
        set { d.set(newValue, forKey: kVerifyUseOuter) }
    }

    // ---- 配对历史（连接成功的客户机记录，持久保存，最多 20 条） ----

    struct PairHistItem: Codable {
        let name: String    // 客户机名（WELCOME 回报）
        let host: String
        let port: Int
        let token: String
        let lastTime: Date  // 最后连接时间
    }

    /// 读取配对历史（按最后连接时间倒序）
    var pairHistory: [PairHistItem] {
        guard let data = d.data(forKey: kPairHistory),
              let list = try? JSONDecoder().decode([PairHistItem].self, from: data) else { return [] }
        return list.sorted { $0.lastTime > $1.lastTime }
    }

    /// 连接成功（收到 WELCOME）时调用：新增/更新该客户机记录并刷新最后连接时间。
    /// 同一台机器（host+port 相同）只保留一条，最多保留 20 条
    func recordPairHistory(name: String, host: String, port: Int, token: String) {
        guard !host.isEmpty, !token.isEmpty else { return }
        var list = pairHistory
        list.removeAll { $0.host == host && $0.port == port }
        list.insert(PairHistItem(name: name, host: host, port: port, token: token, lastTime: Date()), at: 0)
        if list.count > 20 { list = Array(list.prefix(20)) }
        if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: kPairHistory) }
    }
}
