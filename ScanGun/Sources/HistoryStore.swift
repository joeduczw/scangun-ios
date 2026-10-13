import Foundation

/// 扫码历史数据（内存级，APP 关闭后清空）：
/// 扫码页写入，扫描历史页读取显示
final class HistoryStore {
    static let shared = HistoryStore()

    enum Status: Int {
        case pending = 0   // 待确认
        case ok = 1        // 成功录入
        case fail = 2      // 失败
        case stored = 3    // 已存储（存储模式）
    }

    struct Item {
        let msgId: String
        let content: String
        let time: String
        var status: Status
        var reason: String
    }

    private var items: [Item] = []   // 新的在前（index 0）
    private let maxCount = 50
    private let lock = NSLock()
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {}

    func addPending(_ msgId: String, _ content: String) {
        add(Item(msgId: msgId, content: content, time: fmt.string(from: Date()),
                 status: .pending, reason: ""))
    }

    /// 存储模式的历史行：直接记录"已存储"状态（无 ACK 流程）
    func addStored(_ content: String) {
        add(Item(msgId: "stored", content: content, time: fmt.string(from: Date()),
                 status: .stored, reason: ""))
    }

    private func add(_ item: Item) {
        lock.lock()
        items.insert(item, at: 0)
        while items.count > maxCount { items.removeLast() }
        lock.unlock()
    }

    /// 更新指定消息的状态；返回是否更新成功
    @discardableResult
    func update(_ msgId: String, status: Status, reason: String = "") -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = items.firstIndex(where: { $0.msgId == msgId }) else { return false }
        items[idx].status = status
        items[idx].reason = reason
        return true
    }

    func snapshot() -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func clear() {
        lock.lock()
        items.removeAll()
        lock.unlock()
    }
}
