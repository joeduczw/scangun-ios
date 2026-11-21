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

    /// 最近一次网络失败详情（外网问题诊断）：「地址，错误码：描述」；请求成功时清空。
    /// ATS 拦截（-1022）、超时（-1001/-1004）、DNS 解析失败（-1003）各有特征文案，真机外网问题定位用
    private(set) static var lastNetErrDetail: String?

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8    // 单请求 8 秒：外网地址失败时回退内网更快（原 15 秒白等）
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
    /// noRoleLimit：不设角色限制（v27 手动输入与商品验证同口径，普通部门也允许外网）
    /// （cb 放参数列表末位：所有调用点用尾随闭包传入）
    private static func post(action: String, params: [String: String],
                             allowOuter: Bool = true, noRoleLimit: Bool = false,
                             cb: @escaping ([String: Any]?) -> Void) {
        func canOuter() -> Bool { noRoleLimit || Prefs.shared.deptRole != "normal" }
        func go(outer: Bool, allowFallback: Bool) {
            guard let url = URL(string: url(outer: outer, action: action)) else {
                DispatchQueue.main.async { cb(nil) }; return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            var body = URLComponents()
            body.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            session.dataTask(with: req) { data, resp, error in
                var obj: [String: Any]? = nil
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let d = data, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    obj = o
                }
                if obj != nil {
                    lastNetErrDetail = nil
                    DispatchQueue.main.async { cb(obj) }
                } else {
                    // 记录失败详情（地址+系统错误描述），netErr() 会拼进提示，真机弹窗直接显示根因
                    var detail = outer ? "外网 www.joedu.vip:\(Prefs.shared.verifyOuterPort)"
                                       : "内网 192.168.1.179:\(Prefs.shared.verifyInnerPort)"
                    if let http = resp as? HTTPURLResponse { detail += "，HTTP \(http.statusCode)" }
                    if let err = error as NSError? { detail += "，错误\(err.code)：\(err.localizedDescription)" }
                    lastNetErrDetail = detail
                    if allowFallback && allowOuter && canOuter() {
                        go(outer: !outer, allowFallback: false)
                    } else {
                        DispatchQueue.main.async { cb(nil) }
                    }
                }
            }.resume()
        }
        // 智能选路：不在店内网且角色允许 → 直接走外网（免 5 秒内网超时）；在店内网 → 内网。失误由回退兜底
        let startOuter = allowOuter && canOuter() && !onInnerNetwork()
        go(outer: startOuter, allowFallback: true)
    }

    /// 网络失败提示：普通部门明确告知需店内网络；其余角色报网络异常
    private static func netErr() -> String {
        var msg = Prefs.shared.deptRole == "normal"
            ? "生成单据需在店内网络使用（当前无法连接店内服务器）"
            : "网络异常，无法连接服务器"
        if let d = lastNetErrDetail { msg += "\n" + d }
        return msg
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

    /// 生成单据：成功回调单据编号；失败回调错误信息（remark=单据备注，可留空，服务端限 50 字）
    static func saveBill(bizDate: String, shopCode: String, whCode: String, billType: String,
                         skus: [[String: Any]], remark: String, cb: @escaping (String?, String?) -> Void) {
        let jsonData = (try? JSONSerialization.data(withJSONObject: skus)) ?? Data("[]".utf8)
        post(action: "save_bill", params: [
            "biz_date": bizDate, "shop_code": shopCode, "wh_code": whCode,
            "bill_type": billType, "skus": String(data: jsonData, encoding: .utf8) ?? "[]",
            "app_user": Prefs.shared.deptUser, "app_pass": Prefs.shared.deptPass,
            "remark": remark
        ]) { obj in
            guard let obj = obj else { cb(nil, netErr()); return }
            guard obj["success"] as? Bool == true else {
                cb(nil, (obj["message"] as? String) ?? "生成失败"); return
            }
            cb(obj["bill_no"] as? String, nil)
        }
    }

    // ---- 手动输入（v27）：不设角色限制（与商品验证同口径，普通部门也允许外网） ----

    /// 商品代码模糊搜索：kw=前缀或名称包含；成功回调代码列表（最多 20 条），失败回调错误信息
    static func spSearch(kw: String, cb: @escaping ([String]?, String?) -> Void) {
        post(action: "sp_search", params: ["kw": kw], noRoleLimit: true) { obj in
            guard let obj = obj else { cb(nil, netErr()); return }
            guard obj["success"] as? Bool == true else {
                cb(nil, (obj["message"] as? String) ?? "搜索失败"); return
            }
            let codes = (obj["codes"] as? [Any])?.compactMap { $0 as? String } ?? []
            cb(codes, nil)
        }
    }

    /// 商品规格结果：颜色/尺码选项 + 商品名称/单位
    struct GgInfo { let spmc: String; let unit: String; let colors: [Opt]; let sizes: [Opt] }

    /// 商品规格：spdm → 颜色（SPGG1）与尺码（SPGG2）列表，附商品名称/单位；失败回调错误信息
    static func spGg(spdm: String, cb: @escaping (GgInfo?, String?) -> Void) {
        post(action: "sp_gg", params: ["spdm": spdm], noRoleLimit: true) { obj in
            guard let obj = obj else { cb(nil, netErr()); return }
            guard obj["success"] as? Bool == true else {
                cb(nil, (obj["message"] as? String) ?? "查询失败"); return
            }
            func opts(_ key: String) -> [Opt] {
                guard let arr = obj[key] as? [Any] else { return [] }
                return arr.compactMap { item in
                    guard let o = item as? [String: Any] else { return nil }
                    return Opt(code: o["code"] as? String ?? "", name: o["name"] as? String ?? "")
                }
            }
            cb(GgInfo(spmc: obj["spmc"] as? String ?? "",
                      unit: obj["unit"] as? String ?? "",
                      colors: opts("colors"), sizes: opts("sizes")), nil)
        }
    }

    /// SKU 反查条码：spdm+颜色+尺码 → 服务端按 TM 条码方案构造真实条码与完整 8 段信息；失败回调错误信息
    static func spBarcode(spdm: String, gg1dm: String, gg2dm: String, cb: @escaping (Sku?, String?) -> Void) {
        post(action: "sp_barcode", params: ["spdm": spdm, "gg1dm": gg1dm, "gg2dm": gg2dm], noRoleLimit: true) { obj in
            guard let obj = obj else { cb(nil, netErr()); return }
            guard obj["success"] as? Bool == true else {
                cb(nil, (obj["message"] as? String) ?? "查询失败"); return
            }
            cb(Sku(bc: obj["bc"] as? String ?? "",
                  spdm: obj["spdm"] as? String ?? "",
                  spmc: obj["spmc"] as? String ?? "",
                  unit: obj["unit"] as? String ?? "",
                  gg1dm: obj["gg1dm"] as? String ?? "",
                  gg1mc: obj["gg1mc"] as? String ?? "",
                  gg2dm: obj["gg2dm"] as? String ?? "",
                  gg2mc: obj["gg2mc"] as? String ?? ""), nil)
        }
    }
}
