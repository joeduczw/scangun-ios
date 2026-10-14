import Foundation

/// 存储扫描管理（对齐安卓版 ScanStorage）：
/// - 活动文件：存储开关开启时，扫码内容实时追加写入（一行一条码），
///   文件名 = 扫描_yyyyMMdd_HHmmss.txt 自动命名
/// - 「结束存档」封存活动文件（变为待发送，可改名），下次扫码自动开新文件
/// - APP 每次启动自动封存上次活动文件（重新打开 APP 即开新文件）
/// - 断点续发：同名 .prog 文件记录已发送条数，中断后下次从断点继续
/// - 文件发送后保留（可重发/手动删除），重发已发送文件=清零进度从头整发
enum ScanStorage {
    struct StoredFile {
        let name: String        // 显示名（不含 .txt）
        let url: URL
        let total: Int          // 总条数
        let sent: Int           // 已发送条数
        var savedAt: Date = .distantPast   // 保存时间（文件最后修改时间=最后扫码时刻，改名不影响）
    }

    private static let keyCurrent = "current_scan_file"
    private static let fm = FileManager.default

    private static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanFiles", isDirectory: true)
        if !fm.fileExists(atPath: d.path) {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// APP 启动调用：封存上次的活动文件（本次扫码将自动开新文件）
    static func sealStaleFile() {
        UserDefaults.standard.removeObject(forKey: keyCurrent)
    }

    /// 当前活动文件信息（显示名, 累计条数）；无活动文件返回 nil
    static func currentInfo() -> (String, Int)? {
        guard let name = UserDefaults.standard.string(forKey: keyCurrent) else { return nil }
        let url = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return (displayName(name), countLines(url))
    }

    /// 追加一条条码到活动文件（无活动文件则自动创建新文件）。返回活动文件累计条数
    static func append(_ code: String) -> Int {
        var name = UserDefaults.standard.string(forKey: keyCurrent)
        if name == nil || !fm.fileExists(atPath: dir.appendingPathComponent(name!).path) {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd_HHmmss"
            name = "扫描_" + f.string(from: Date()) + ".txt"
            UserDefaults.standard.set(name, forKey: keyCurrent)
        }
        let url = dir.appendingPathComponent(name!)
        let data = (code + "\n").data(using: .utf8)!
        if fm.fileExists(atPath: url.path) {
            if let h = FileHandle(forWritingAtPath: url.path) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
        } else {
            try? data.write(to: url)
        }
        return countLines(url)
    }

    /// 撤销当前活动文件的最后一条（存储模式扫错码时用）。
    /// 返回被撤销的内容；无活动文件或文件已空返回 nil
    static func undoLast() -> String? {
        guard let name = UserDefaults.standard.string(forKey: keyCurrent) else { return nil }
        let url = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let removed = lines.popLast() else { return nil }
        let newText = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? newText.write(to: url, atomically: true, encoding: .utf8)
        return removed
    }

    /// 结束并封存当前活动文件（可在封存时改名）。返回（显示名, 条数）；无活动文件返回 nil。
    /// 改名目标重名时不改名、按原名封存（调用方已做重名校验，此处兜底）
    static func finishCurrent(newName: String?) -> (String, Int)? {
        guard let oldName = UserDefaults.standard.string(forKey: keyCurrent) else { return nil }
        let src = dir.appendingPathComponent(oldName)
        guard fm.fileExists(atPath: src.path) else {
            UserDefaults.standard.removeObject(forKey: keyCurrent)
            return nil
        }
        let count = countLines(src)
        var finalName = oldName
        if let nn = newName, !nn.trimmingCharacters(in: .whitespaces).isEmpty,
           nn != displayName(oldName) {
            let target = dir.appendingPathComponent(nn + ".txt")
            if !fm.fileExists(atPath: target.path) {
                do {
                    try fm.moveItem(at: src, to: target)
                    finalName = nn + ".txt"
                    // 进度记录跟随改名（活动文件一般无进度，保险起见一并处理）
                    let oldProg = dir.appendingPathComponent(oldName + ".prog")
                    if fm.fileExists(atPath: oldProg.path) {
                        try? fm.moveItem(at: oldProg, to: dir.appendingPathComponent(finalName + ".prog"))
                    }
                } catch { /* 改名失败按原名封存 */ }
            }
        }
        UserDefaults.standard.removeObject(forKey: keyCurrent)
        return (displayName(finalName), count)
    }

    /// 指定显示名的存储文件是否已存在（改名时重名校验用）
    static func nameExists(_ displayName: String) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(displayName + ".txt").path)
    }

    /// 全部存储文件列表（含已发送/发送中的，按文件名正序=时间正序），自动排除当前活动文件
    static func allFiles() -> [StoredFile] {
        let cur = UserDefaults.standard.string(forKey: keyCurrent)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasSuffix(".txt") && $0 != cur }
            .sorted { $0 < $1 }
            .map { n in
                let url = dir.appendingPathComponent(n)
                let savedAt = ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
                return StoredFile(name: displayName(n), url: url,
                                  total: countLines(url), sent: readProgress(n), savedAt: savedAt)
            }
    }

    /// 从第 from 行（0 起）读取条码内容
    static func linesFrom(_ url: URL, from: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .dropFirst(from)
            .map { String($0) }
    }

    /// 保存发送进度（已发送条数）
    static func saveProgress(_ url: URL, sent: Int) {
        let prog = dir.appendingPathComponent(url.lastPathComponent + ".prog")
        if sent <= 0 {
            try? fm.removeItem(at: prog)
        } else {
            try? String(sent).write(to: prog, atomically: true, encoding: .utf8)
        }
    }

    /// 删除文件及其进度记录
    static func delete(_ url: URL) {
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: dir.appendingPathComponent(url.lastPathComponent + ".prog"))
    }

    private static func readProgress(_ fileName: String) -> Int {
        let prog = dir.appendingPathComponent(fileName + ".prog")
        guard let s = try? String(contentsOf: prog, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        else { return 0 }
        return Int(s) ?? 0
    }

    private static func countLines(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    private static func displayName(_ name: String) -> String {
        name.hasSuffix(".txt") ? String(name.dropLast(4)) : name
    }
}
