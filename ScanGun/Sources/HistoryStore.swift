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
        case unmatched = 4     // 未匹配（商品验证：部分匹配/未匹配，条码已丢弃）
        case verifyFail = 5    // 验证失败（商品验证：网络异常，条码已丢弃）
    }

    /// product：商品信息三项「商品代码|颜色|尺码」（商品验证完整匹配通过的记录携带，| 分隔）；
    /// 空串=无商品信息（未开验证/验证失败），旧记录默认空串，显示时跳过不报错
    struct Item {
        let msgId: String
        let content: String
        let time: String
        var status: Status
        var reason: String
        var product: String
    }

    private var items: [Item] = []   // 新的在前（index 0），不限条数全部保留
    private let lock = NSLock()
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {}

    func addPending(_ msgId: String, _ content: String, product: String = "") {
        add(Item(msgId: msgId, content: content, time: fmt.string(from: Date()),
                 status: .pending, reason: "", product: product))
    }

    /// 存储模式的历史行：直接记录"已存储"状态（无 ACK 流程）
    func addStored(_ content: String, product: String = "") {
        add(Item(msgId: "stored", content: content, time: fmt.string(from: Date()),
                 status: .stored, reason: "", product: product))
    }

    /// 商品验证不通过的历史行（未匹配/验证失败，条码已丢弃）
    func addVerifyFail(_ content: String, status: Status) {
        add(Item(msgId: "verify", content: content, time: fmt.string(from: Date()),
                 status: status, reason: "", product: ""))
    }

    private func add(_ item: Item) {
        lock.lock()
        items.insert(item, at: 0)
        lock.unlock()
    }

    /// 撤销最近一条"已存储"历史记录（主界面撤销按钮联动，删最新一条已存储）；返回被删记录
    @discardableResult
    func undoLastStored() -> Item? {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = items.firstIndex(where: { $0.status == .stored }) else { return nil }
        return items.remove(at: idx)
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
