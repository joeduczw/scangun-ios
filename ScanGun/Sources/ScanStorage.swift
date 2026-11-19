import Foundation

/// 扫描记录的本地文件存储（扫码只存不发模式的档案，一行一条）。
/// 行格式（对齐安卓 v25）：
/// - 新 8 段（验证通过写入，生成单据时本地聚合免解析）：条码|商品代码|颜色代码|尺码代码|商品名|颜色名|尺码名|单位
/// - 旧格式：条码  或  条码|商品代码|颜色名|尺码名
/// - 明细浏览显示口径统一为「商品代码 颜色名 尺码名」（内部代码不显示，新旧格式显示一致）
enum ScanStorage {

    struct StoredFile {
        let url: URL
        var name: String { url.lastPathComponent }
        var size: Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        /// mtime 文件修改时间（文件列表倒序用）
        var mtime: Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    }

    static func dir() -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 当前写入目标文件（按日期命名，如 扫描_2026-11-19.txt；当天没有则新建）
    static func currentFile() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return dir().appendingPathComponent("扫描_\(f.string(from: Date())).txt")
    }

    /// 追加一行扫描记录，返回当前文件总行数。product=验证通过的商品信息（代码|颜色|尺码），
    /// sku=完整 8 段 SKU 尾段（商品代码|颜色代码|尺码代码|商品名|颜色名|尺码名|单位）——
    /// 生成单据时可直接本地聚合，无需再发服务器解析
    @discardableResult
    static func append(_ code: String, product: String = "", sku: String = "") -> Int {
        let url = currentFile()
        var line = code
        if !sku.isEmpty { line += "|" + sku }
        else if !product.isEmpty { line += "|" + product }
        let text = ((try? String(contentsOf: url, encoding: .utf8)) ?? "") + line + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return text.components(separatedBy: "\n").count - 1
    }

    /// 列出全部存储文件（按修改时间倒序，最新在前）
    static func list() -> [StoredFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir().path) else { return [] }
        return names
            .filter { $0.hasSuffix(".txt") }
            .map { StoredFile(url: dir().appendingPathComponent($0)) }
            .sorted { $0.mtime > $1.mtime }
    }

    struct Entry { let code: String; let product: String }

    /// 读文件全部记录：code=条码，product=显示用商品信息（商品代码 颜色名 尺码名）
    static func readEntries(_ file: StoredFile) -> [Entry] {
        let text = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { l in
                let parts = l.components(separatedBy: "|")
                if parts.count >= 8 {
                    // 新 8 段格式：显示「商品代码 颜色名 尺码名」（与旧格式口径一致，内部代码不显示）
                    return Entry(code: parts[0],
                                 product: [parts[1], parts[5], parts[6]].filter { !$0.isEmpty }.joined(separator: " "))
                }
                return Entry(code: parts.first ?? l,
                             product: parts.dropFirst().filter { !$0.isEmpty }.joined(separator: " "))
            }
    }

    /// 删除文件
    static func delete(_ file: StoredFile) { try? FileManager.default.removeItem(at: file.url) }

    /// 文件全部发送成功后调用：删除文件
    static func clearSent(_ file: StoredFile) { try? FileManager.default.removeItem(at: file.url) }
}
