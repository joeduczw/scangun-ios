import Foundation

/// 单据生成网络模块（对齐安卓 BillApi）：
/// - 地址与商品验证共用（内部 192.168.1.179:<端口> / 外部 www.joedu.vip:<端口>，端口用配对页「商品验证端口」配置）
/// - 智能选路：发请求前检测本机网卡是否持 192.168.1.x 地址——店内 WiFi 直接走内网；
///   外网环境（流量/外部 WiFi）且角色允许时直接走外网，不再白等内网 5 秒超时；
///   判断失误由回退机制兜底（失败自动换另一个地址重试一次）
/// - 外网规则：普通部门（normal）恒仅内网；管理员类（all）/办公室（office）内外网可回退；
///   部门登录（allowOuter=false）恒仅内网——登录时角色未知，且配置部门本就应在店内完成
/// - app_login：部门账号验证（主系统账号编号+密码）；barcode_batch：批量条码解析；save_bill：生成单据（每次带账号密码验证）
enum BillApi {

    /// 仓库/商店选项
    struct Opt { let code: String; let name: String }

    /// 部门登录结果
    struct DeptInfo { let deptName: String; let bianhao: String; let role: String;
                      let warehouses: [Opt]; let shops: [Opt] }

    /// 条码解析结果（一行一码）
    struct Sku { let bc: String; let spdm: String; let spmc: String; let unit: String;
                 let gg1dm: String; let gg1mc: String; let gg2dm: String; let gg2mc: String }

    /// 角色显示名
    static func roleLabel(_ role: String) -> String {
        switch role {
        case "all": return "管理员类"
        case "office": return "办公室"
        case "normal": return "普通部门"
        default: return "未知"
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 120   // 批量解析条码多时耗时较长
        return URLSession(configuration: cfg)
    }()

    /// api.php 地址（outer=true 用外部域名）
    private static func url(outer: Bool, action: String) -> String {
        let host = outer ? "www.joedu.vip" : "192.168.1.179"
        let port = outer ? Prefs.shared.verifyOuterPort : Prefs.shared.verifyInnerPort
        return "http://\(host):\(port)/api.php?action=\(action)"
    }

    /// 是否在店内网（本机任一 IPv4 网卡地址为 192.168.1.x）
    private static func onInnerNetwork() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var addr = sockaddr_in()
            memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = addr.sin_addr
            if inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                if String(cString: buf).hasPrefix("192.168.1.") { return true }
            }
        }
        return false
    }

    /// POST 表单：智能选路 + 失败自动换地址重试一次。回调统一回主线程，网络/解析失败回调 nil
    private static func post(action: String, params: [String: String],
                             cb: @escaping ([String: Any]?) -> Void, allowOuter: Bool = true) {
        func go(outer: Bool, allowFallback: Bool) {
            guard let url = URL(string: url(outer: outer, action: action)) else {
                DispatchQueue.main.async { cb(nil) }; return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            let body = URLComponents()
            body.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            session.dataTask(with: req) { data, resp, _ in
                var obj: [String: Any]? = nil
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let d = data, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    obj = o
                }
                if obj != nil {
                    DispatchQueue.main.async { cb(obj) }
                } else if allowFallback && allowOuter && Prefs.shared.deptRole != "normal" {
                    go(outer: !outer, allowFallback: false)
                } else {
                    DispatchQueue.main.async { cb(nil) }
                }
            }.resume()
        }
        // 智能选路：不在店内网且角色允许 → 直接走外网（免 5 秒内网超时）；在店内网 → 内网。失误由回退兜底
        let startOuter = allowOuter && Prefs.shared.deptRole != "normal" && !onInnerNetwork()
        go(outer: startOuter, allowFallback: true)
    }

    /// 网络失败提示：普通部门明确告知需店内网络；其余角色报网络异常
    private static func netErr() -> String {
        Prefs.shared.deptRole == "normal"
            ? "生成单据需在店内网络使用（当前无法连接店内服务器）"
            : "网络异常，无法连接服务器"
    }

    /// 部门账号验证（仅内网）：成功回调 DeptInfo；失败回调错误信息
    static func login(name: String, pass: String, cb: @escaping (DeptInfo?, String?) -> Void) {
        post(action: "app_login", params: ["name": name, "password": pass], allowOuter: false) { obj in
            guard let obj = obj else { cb(nil, "无法连接服务器，请确认手机已连接店内网络"); return }
            guard obj["success"] as? Bool == true else {
                cb(nil, (obj["message"] as? String) ?? "账号或密码错误"); return
            }
            func opts(_ key: String) -> [Opt] {
                guard let arr = obj[key] as? [Any] else { return [] }
                return arr.compactMap { item in
                    guard let o = item as? [String: Any] else { return nil }
                    return Opt(code: o["code"] as? String ?? "", name: o["name"] as? String ?? "")
                }
            }
            cb(DeptInfo(deptName: obj["dept_name"] as? String ?? "",
                        bianhao: obj["bianhao"] as? String ?? "",
                        role: obj["role"] as? String ?? "",
                        warehouses: opts("warehouses"), shops: opts("shops")), nil)
        }
    }

    /// 批量条码解析：rows=解析成功明细；failed=失败条码清单（空数组的差异靠 msg 区分）；
    /// msg=网络/服务端错误（此时 rows=nil 中止生成）
    static func barcodeBatch(bcs: [String],
                             cb: @escaping (_ rows: [Sku]?, _ failed: [String]?, _ msg: String?) -> Void) {
        let jsonData = (try? JSONSerialization.data(withJSONObject: bcs)) ?? Data("[]".utf8)
        let bcsJson = String(data: jsonData, encoding: .utf8) ?? "[]"
        post(action: "barcode_batch", params: ["bcs": bcsJson]) { obj in
            guard let obj = obj else { cb(nil, nil, netErr()); return }
            guard obj["success"] as? Bool == true else {
                cb(nil, nil, (obj["message"] as? String) ?? "解析失败"); return
            }
            var failed: [String] = []
            if let f = obj["failed"] as? [Any] { failed = f.compactMap { $0 as? String } }
            var rows: [Sku] = []
            if let r = obj["rows"] as? [Any] {
                for item in r {
                    guard let o = item as? [String: Any] else { continue }
                    rows.append(Sku(bc: o["bc"] as? String ?? "",
                                    spdm: o["spdm"] as? String ?? "",
                                    spmc: o["spmc"] as? String ?? "",
                                    unit: o["unit"] as? String ?? "",
                                    gg1dm: o["gg1dm"] as? String ?? "",
                                    gg1mc: o["gg1mc"] as? String ?? "",
                                    gg2dm: o["gg2dm"] as? String ?? "",
                                    gg2mc: o["gg2mc"] as? String ?? ""))
                }
            }
            cb(rows, failed.isEmpty ? nil : failed, nil)
        }
    }

    /// 生成单据：成功回调单据编号；失败回调错误信息
    static func saveBill(bizDate: String, shopCode: String, whCode: String, billType: String,
                         skus: [[String: Any]], cb: @escaping (String?, String?) -> Void) {
        let jsonData = (try? JSONSerialization.data(withJSONObject: skus)) ?? Data("[]".utf8)
        post(action: "save_bill", params: [
            "biz_date": bizDate, "shop_code": shopCode, "wh_code": whCode,
            "bill_type": billType, "skus": String(data: jsonData, encoding: .utf8) ?? "[]",
            "app_user": Prefs.shared.deptUser, "app_pass": Prefs.shared.deptPass
        ]) { obj in
            guard let obj = obj else { cb(nil, netErr()); return }
            guard obj["success"] as? Bool == true else {
                cb(nil, (obj["message"] as? String) ?? "生成失败"); return
            }
            cb(obj["bill_no"] as? String, nil)
        }
    }
}
