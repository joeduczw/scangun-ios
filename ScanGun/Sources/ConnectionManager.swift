import Foundation
import AVFoundation
import UIKit

/// 声音+振动反馈（系统音效 + Taptic）
enum Beep {
    static func ok() {
        AudioServicesPlaySystemSound(1057)              // 成功提示音
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func fail() {
        AudioServicesPlaySystemSound(1053)              // 错误提示音
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    static func vibrate() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}

/// WebSocket 连接管理（对齐安卓版：ACK确认/3秒超时/指数退避重连/断线outbox补发）
final class ConnectionManager {
    static let shared = ConnectionManager()

    enum State { case disconnected, connecting, connected }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var state: State = .disconnected
    private var reconnectAttempt = 0
    private var manualClosed = false
    private var outbox: [(code: String, type: String)] = []   // 断线待发队列
    private var pendingAcks: [String: (code: String, sentAt: Date)] = [:]
    private var ackTimeoutTimer: Timer?
    private var keepAliveTimer: Timer?
    private let queue = DispatchQueue(label: "ws.conn")

    /// UI 回调（主线程）
    var onStateChanged: ((State) -> Void)?
    var onWelcome: ((String) -> Void)?
    /// ok=false 且 reason="超时" 时若为迟到回执会被再次以 ok=true 调用
    var onAck: ((_ msgId: String, _ code: String, _ ok: Bool, _ reason: String) -> Void)?

    private init() {
        session = URLSession(configuration: .default)
    }

    private var wsURL: URL? {
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = Prefs.shared.host
        comps.port = Prefs.shared.port
        comps.path = "/ws"
        comps.queryItems = [URLQueryItem(name: "token", value: Prefs.shared.token)]
        return comps.url
    }

    // MARK: - 连接
    func connect() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.state == .disconnected else { return }
            guard let url = self.wsURL else { return }
            self.manualClosed = false
            self.setState(.connecting)
            let t = self.session.webSocketTask(with: url)
            self.task = t
            t.resume()
            self.receiveLoop(t)
            // 连接后发送 HELLO（稍等握手完成）
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.sendRaw("HELLO|\(Prefs.shared.deviceName)")
            }
            self.startTimers()
        }
    }

    func disconnect(manual: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.manualClosed = manual
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.setState(.disconnected)
            self.stopTimers()
            if manual { self.outbox.removeAll(); self.pendingAcks.removeAll() }
        }
    }

    /// 配对信息变更后重连
    func reconnectWithNewPrefs() {
        disconnect(manual: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connect() }
    }

    private func setState(_ s: State) {
        state = s
        DispatchQueue.main.async { self.onStateChanged?(s) }
    }

    // MARK: - 收发
    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self = self, self.task === t else { return }
            switch result {
            case .failure:
                self.handleDisconnected()
            case .success(let msg):
                if case .string(let text) = msg { self.handleMessage(text) }
                self.receiveLoop(t)
            }
        }
    }

    private func handleMessage(_ text: String) {
        let parts = text.split(separator: "|", maxSplits: 4).map(String.init)
        guard let cmd = parts.first else { return }   // 空消息防御（越界崩溃）
        if cmd == "WELCOME" {
            let machine = parts.count > 1 ? parts[1] : "客户机"
            DispatchQueue.main.async { self.onWelcome?(machine) }
            queue.async {
                // ⚠️ 核心修复：WELCOME 到达才算连接真正建立（原 bug：漏了这行，
                // state 永远停在 .connecting，扫码全部进待发队列报"未连接客户机"）
                self.setState(.connected)
                self.reconnectAttempt = 0
                self.flushOutbox()
            }
        } else if cmd == "ACK", parts.count >= 3 {
            let msgId = parts[1]
            let ok = parts[2] == "0"
            let reason = parts.count > 3 ? parts[3] : ""
            queue.async {
                if let p = self.pendingAcks.removeValue(forKey: msgId) {
                    DispatchQueue.main.async { self.onAck?(msgId, p.code, ok, reason) }
                }
            }
        }
    }

    /// 发送扫码内容，返回 msgId
    @discardableResult
    func sendScan(_ code: String, type: String) -> String {
        let msgId = UUID().uuidString.prefix(8).lowercased()
        let payload = "SCAN|\(msgId)|\(type)|\(code)"
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.state == .connected {
                self.sendRaw(payload)
                self.pendingAcks[msgId] = (code, Date())
            } else {
                self.outbox.append((code, type))   // 断线缓存，重连补发
                DispatchQueue.main.async {
                    self.onAck?(msgId, code, false, "未连接客户机（已进待发队列）")
                }
            }
        }
        return msgId
    }

    private func flushOutbox() {
        guard !outbox.isEmpty else { return }
        let items = outbox
        outbox.removeAll()
        var delay: TimeInterval = 0
        for item in items {
            delay += 0.15
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendScan(item.code, type: item.type)
            }
        }
    }

    private func sendRaw(_ text: String) {
        task?.send(.string(text)) { [weak self] error in
            if error != nil { self?.handleDisconnected() }
        }
    }

    // MARK: - 定时器（ACK超时 + 保活）
    // ⚠️ Timer 必须在有 RunLoop 的线程创建：GCD 后台队列无 RunLoop，
    // 在那里 scheduledTimer 会永不触发（原 bug：ACK 超时与保活全部失效）
    private func startTimers() {
        stopTimers()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.ackTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkAckTimeout()
            }
            self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
                self?.queue.async {
                    self?.task?.sendPing { error in
                        if error != nil { self?.handleDisconnected() }
                    }
                }
            }
        }
    }

    private func stopTimers() {
        DispatchQueue.main.async { [weak self] in
            self?.ackTimeoutTimer?.invalidate(); self?.ackTimeoutTimer = nil
            self?.keepAliveTimer?.invalidate(); self?.keepAliveTimer = nil
        }
    }

    private func checkAckTimeout() {
        let deadline = Date().addingTimeInterval(-3.0)
        // timer 在主线程触发，回 queue 异步取数（原 queue.sync 若在 queue 上下文调用会死锁）
        queue.async { [weak self] in
            guard let self = self else { return }
            var timedOut: [(String, String)] = []
            for (id, p) in self.pendingAcks where p.sentAt < deadline {
                self.pendingAcks.removeValue(forKey: id)
                timedOut.append((id, p.code))
            }
            for (id, code) in timedOut {
                DispatchQueue.main.async { self.onAck?(id, code, false, "客户机3秒内未确认") }
            }
        }
    }

    // MARK: - 断线重连（指数退避 1s→30s）
    private func handleDisconnected() {
        queue.async { [weak self] in
            guard let self = self, self.state != .disconnected else { return }
            self.task?.cancel()
            self.task = nil
            self.setState(.disconnected)
            self.stopTimers()
            if self.manualClosed { return }
            self.reconnectAttempt += 1
            let wait = min(30.0, pow(2.0, Double(self.reconnectAttempt - 1)))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self = self, !self.manualClosed else { return }
                self.connect()
            }
        }
    }
}
