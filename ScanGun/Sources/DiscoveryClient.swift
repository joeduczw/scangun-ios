import Foundation

/// UDP 广播自动发现客户机（对齐安卓 DiscoveryClient）。
/// 协议：APP 广播 "SCANGUN_DISCOVER_V1"，客户机回 "SCANGUN_HERE_V1|机器名|端口|需要配对码"
enum DiscoveryClient {

    static let discoverPort: UInt16 = 39391
    private static let magicReq = "SCANGUN_DISCOVER_V1"
    private static let magicRsp = "SCANGUN_HERE_V1"

    struct Device {
        let name: String
        let ip: String
        let port: Int
    }

    /// 广播发现（默认 3 秒窗口），结果在主线程回调（可能为空列表）。
    /// 同时向 255.255.255.255 与各网卡的定向广播地址发送，兼容各种路由器。
    static func discover(timeoutMs: Int = 3000, onResult: @escaping ([Device]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var found = [String: Device]()
            let sock = socket(AF_INET, SOCK_DGRAM, 0)
            guard sock >= 0 else { return finish(onResult, found) }
            defer { close(sock) }

            // 开启广播 + 1 秒接收超时（总时长由 deadline 控制）
            var on: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            // 向全部广播地址发送发现请求
            let req = Array(magicReq.utf8)
            for target in broadcastTargets() {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = discoverPort.bigEndian
                addr.sin_addr = in_addr(s_addr: target)
                req.withUnsafeBytes { raw in
                    withUnsafePointer(to: &addr) { ap in
                        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            _ = sendto(sock, raw.baseAddress, raw.count, 0, sa,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }

            // 接收响应直到超时（同 IP:端口 去重）
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
            var buf = [UInt8](repeating: 0, count: 1024)
            while Date() < deadline {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(sock, &buf, buf.count, 0, sa, &fromLen)
                    }
                }
                guard n > 0 else { continue }   // 1 秒超时：deadline 未到继续等
                let text = String(decoding: buf[0..<n], as: UTF8.self)
                let parts = text.split(separator: "|").map(String.init)
                guard parts.count >= 4, parts[0] == magicRsp, let port = Int(parts[2]) else { continue }
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: ipBuf)
                found["\(ip):\(port)"] = Device(name: parts[1], ip: ip, port: port)
            }
            finish(onResult, found)
        }
    }

    private static func finish(_ onResult: @escaping ([Device]) -> Void, _ found: [String: Device]) {
        DispatchQueue.main.async { onResult(Array(found.values)) }
    }

    /// 广播目标：255.255.255.255 + 各 WiFi 网卡的定向广播地址（IP | ~掩码）
    private static func broadcastTargets() -> [in_addr_t] {
        var targets: [in_addr_t] = [INADDR_BROADCAST]
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return targets }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let maskSA = p.pointee.ifa_netmask,
                  maskSA.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = maskSA.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let bc = ip | ~mask
            if !targets.contains(bc) { targets.append(bc) }
        }
        freeifaddrs(first)
        return targets
    }
}
