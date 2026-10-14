import UIKit

/// 储存发送页（复刻安卓版）：
/// - 列表显示所有存储文件（含已发送），未发完的排前面；支持勾选多个
/// - 「手动发送」：每点一次发送一条（电脑程序反应慢时逐条控制节奏）
/// - 「自动发送」：进入发送面板，按顺序逐条发送（每条等 ACK 确认后间隔一段时间再发下一条，
///   间隔可调防丢码），面板内可随时「暂停/恢复」；断线自动暂停并保存进度
/// - 手动任务进行中点「自动发送」= 从当前断点接管切换为自动
/// - 勾选已发送的文件=整文件从头重发（进度清零）；文件发送后保留，可重发或手动删除
/// - 「重新发送」：随时停止任务，文件恢复到进入任务前的状态
class FilesViewController: UIViewController, ConnListener {

    private enum Mode { case none, manual, auto }

    // MARK: - UI
    private let titleLabel = UILabel()
    private let resetBtn = UIButton(type: .system)
    private let closeBtn = UIButton(type: .system)
    private let sendingBar = UILabel()
    private let intervalLabel = UILabel()
    private let intervalBtn = UIButton(type: .system)
    private let tableView = UITableView()
    private let selectAllBtn = UIButton(type: .system)
    private let deleteBtn = UIButton(type: .system)
    private let tipLabel = UILabel()
    private let manualSendBtn = UIButton(type: .system)
    private let autoSendBtn = UIButton(type: .system)
    // 自动发送面板
    private let sendPanel = UIView()
    private let panelState = UILabel()
    private let panelFile = UILabel()
    private let panelProgress = UILabel()
    private let panelTotal = UILabel()
    private let pauseResumeBtn = UIButton(type: .system)

    // MARK: - 列表数据
    private var files: [ScanStorage.StoredFile] = []
    private var checked: Set<String> = []   // 按文件名勾选

    // MARK: - 发送状态机（对齐安卓 FilesActivity）
    private var mode: Mode = .none
    private var sending = false
    private var sendQueue: [ScanStorage.StoredFile] = []
    private var curIdx = 0
    private var curLines: [String] = []
    private var curLineIdx = 0
    private var pendingMsgId: String?
    private var intervalMs = 500
    private var originalProgress: [Int] = []    // 任务开始时进度快照（重新发送恢复用）
    private var paused = false
    private var pauseReason: String?

    private let intervalValues = [300, 500, 800, 1200, 2000, 3000]
    private let intervalLabels = ["0.3秒（快）", "0.5秒（标准）", "0.8秒（慢）", "1.2秒（很慢）", "2秒（特慢）", "3秒（超慢）"]

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0x121212)
        buildUI()
        ConnectionManager.shared.addListener(self)
        reload()
    }

    // MARK: - UI 构建
    private func buildUI() {
        let safe = view.safeAreaLayoutGuide

        // 标题行：储存发送 | 重新发送 | 关闭（两按钮加大、拉开间距防误触）
        let titleRow = UIStackView()
        titleRow.axis = .horizontal
        titleRow.spacing = 14
        titleRow.alignment = .center
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleRow)
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            titleRow.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            titleRow.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            titleRow.heightAnchor.constraint(equalToConstant: 48)
        ])
        titleLabel.text = "储存发送"
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textColor = .white
        titleRow.addArrangedSubview(titleLabel)
        let spacer = UIView()
        titleRow.addArrangedSubview(spacer)
        styleBtn(resetBtn, title: "重新发送")
        resetBtn.titleLabel?.font = .boldSystemFont(ofSize: 14)
        resetBtn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        resetBtn.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
        titleRow.addArrangedSubview(resetBtn)
        styleBtn(closeBtn, title: "关闭")
        closeBtn.titleLabel?.font = .boldSystemFont(ofSize: 14)
        closeBtn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        titleRow.addArrangedSubview(closeBtn)

        // 内容区竖直容器：状态条 + 全选/删除行 + 间隔行（对齐安卓布局顺序：操作行紧跟标题栏下）
        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 4),
            contentStack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12)
        ])

        // 任务状态黄条（手动发送进度提示；stack 内 hidden 自动收起不占位）
        sendingBar.font = .systemFont(ofSize: 12)
        sendingBar.textColor = UIColor(hex: 0x121212)
        sendingBar.backgroundColor = UIColor(hex: 0xF9A825)
        sendingBar.numberOfLines = 2
        sendingBar.textAlignment = .center
        sendingBar.layer.cornerRadius = 6
        sendingBar.clipsToBounds = true
        sendingBar.isHidden = true
        contentStack.addArrangedSubview(sendingBar)
        sendingBar.heightAnchor.constraint(equalToConstant: 40).isActive = true

        // 操作行：全选 / 删除所选（紧跟标题栏/状态条下，对齐安卓）
        let opRow = UIStackView()
        opRow.axis = .horizontal
        opRow.spacing = 8
        opRow.distribution = .fillEqually
        contentStack.addArrangedSubview(opRow)
        opRow.heightAnchor.constraint(equalToConstant: 38).isActive = true
        styleBtn(selectAllBtn, title: "全选")
        selectAllBtn.addTarget(self, action: #selector(selectAllTapped), for: .touchUpInside)
        opRow.addArrangedSubview(selectAllBtn)
        styleBtn(deleteBtn, title: "删除所选")
        deleteBtn.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        opRow.addArrangedSubview(deleteBtn)

        // 发送间隔行
        let intervalRow = UIStackView()
        intervalRow.axis = .horizontal
        intervalRow.spacing = 8
        intervalRow.alignment = .center
        contentStack.addArrangedSubview(intervalRow)
        intervalRow.heightAnchor.constraint(equalToConstant: 34).isActive = true
        intervalLabel.text = "发送间隔："
        intervalLabel.font = .systemFont(ofSize: 13)
        intervalLabel.textColor = .white
        intervalRow.addArrangedSubview(intervalLabel)
        styleBtn(intervalBtn, title: intervalLabel(forMs: Prefs.shared.sendIntervalMs))
        intervalBtn.setTitleColor(UIColor(hex: 0xF9A825), for: .normal)
        intervalBtn.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        intervalBtn.addTarget(self, action: #selector(intervalTapped), for: .touchUpInside)
        intervalRow.addArrangedSubview(intervalBtn)
        let tip1 = UILabel()
        tip1.text = "电脑反应慢时调大"
        tip1.font = .systemFont(ofSize: 12)
        tip1.textColor = UIColor(white: 0.72, alpha: 1)
        intervalRow.addArrangedSubview(tip1)

        // 文件列表
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 0.25, alpha: 1)
        tableView.rowHeight = 64
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ])

        // 底部提示
        tipLabel.text = "勾选已发送的文件=整文件重发；文件发送后保留，可重发或删除"
        tipLabel.font = .systemFont(ofSize: 11)
        tipLabel.textColor = UIColor(white: 0.55, alpha: 1)
        tipLabel.numberOfLines = 0
        tipLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tipLabel)
        NSLayoutConstraint.activate([
            tipLabel.topAnchor.constraint(equalTo: tableView.bottomAnchor, constant: 8),
            tipLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            tipLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12)
        ])

        // 底部双按钮：手动发送 / 自动发送
        let bottomRow = UIStackView()
        bottomRow.axis = .horizontal
        bottomRow.spacing = 10
        bottomRow.distribution = .fillEqually
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomRow)
        NSLayoutConstraint.activate([
            bottomRow.topAnchor.constraint(equalTo: tipLabel.bottomAnchor, constant: 10),
            bottomRow.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            bottomRow.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            bottomRow.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            bottomRow.heightAnchor.constraint(equalToConstant: 66)
        ])
        styleBtn(manualSendBtn, title: "手动发送")
        manualSendBtn.titleLabel?.font = .boldSystemFont(ofSize: 15)
        manualSendBtn.backgroundColor = UIColor(hex: 0x37474F)
        manualSendBtn.addTarget(self, action: #selector(manualSendTapped), for: .touchUpInside)
        bottomRow.addArrangedSubview(manualSendBtn)
        styleBtn(autoSendBtn, title: "自动发送")
        autoSendBtn.titleLabel?.font = .boldSystemFont(ofSize: 15)
        autoSendBtn.backgroundColor = UIColor(hex: 0x2E7D32)
        autoSendBtn.addTarget(self, action: #selector(autoSendTapped), for: .touchUpInside)
        bottomRow.addArrangedSubview(autoSendBtn)

        // 自动发送面板（覆盖列表区显示）
        sendPanel.backgroundColor = UIColor(hex: 0x1B1B1B)
        sendPanel.layer.cornerRadius = 12
        sendPanel.isHidden = true
        sendPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sendPanel)
        NSLayoutConstraint.activate([
            sendPanel.topAnchor.constraint(equalTo: contentStack.topAnchor),
            sendPanel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            sendPanel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            sendPanel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12)
        ])
        panelState.font = .boldSystemFont(ofSize: 17)
        panelState.textAlignment = .center
        panelState.textColor = UIColor(hex: 0xF9A825)
        panelFile.font = .systemFont(ofSize: 13)
        panelFile.textAlignment = .center
        panelFile.textColor = .white
        panelFile.numberOfLines = 2
        panelProgress.font = .boldSystemFont(ofSize: 28)
        panelProgress.textAlignment = .center
        panelProgress.textColor = .white
        panelTotal.font = .systemFont(ofSize: 12)
        panelTotal.textAlignment = .center
        panelTotal.textColor = UIColor(white: 0.65, alpha: 1)
        let panelStack = UIStackView(arrangedSubviews: [panelState, panelFile, panelProgress, panelTotal])
        panelStack.axis = .vertical
        panelStack.spacing = 14
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        sendPanel.addSubview(panelStack)
        NSLayoutConstraint.activate([
            panelStack.topAnchor.constraint(equalTo: sendPanel.topAnchor, constant: 24),
            panelStack.leadingAnchor.constraint(equalTo: sendPanel.leadingAnchor, constant: 16),
            panelStack.trailingAnchor.constraint(equalTo: sendPanel.trailingAnchor, constant: -16)
        ])
        pauseResumeBtn.setTitle("暂停发送", for: .normal)
        pauseResumeBtn.setTitleColor(.white, for: .normal)
        pauseResumeBtn.titleLabel?.font = .boldSystemFont(ofSize: 16)
        pauseResumeBtn.backgroundColor = UIColor(hex: 0x37474F)
        pauseResumeBtn.layer.cornerRadius = 10
        pauseResumeBtn.translatesAutoresizingMaskIntoConstraints = false
        pauseResumeBtn.addTarget(self, action: #selector(pauseResumeTapped), for: .touchUpInside)
        sendPanel.addSubview(pauseResumeBtn)
        NSLayoutConstraint.activate([
            pauseResumeBtn.centerXAnchor.constraint(equalTo: sendPanel.centerXAnchor),
            pauseResumeBtn.topAnchor.constraint(equalTo: panelStack.bottomAnchor, constant: 24),
            pauseResumeBtn.widthAnchor.constraint(equalTo: sendPanel.widthAnchor, multiplier: 0.7),
            pauseResumeBtn.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    private func styleBtn(_ b: UIButton, title: String) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        // 复刻安卓 Material3 默认按钮主色（紫），醒目
        b.backgroundColor = UIColor(hex: 0x6750A4)
        b.layer.cornerRadius = 8
        b.titleLabel?.font = .systemFont(ofSize: 13)
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    private func intervalLabel(forMs ms: Int) -> String {
        intervalLabels[intervalValues.firstIndex(of: ms) ?? 1]
    }

    // MARK: - 间隔选择
    @objc private func intervalTapped() {
        let a = UIAlertController(title: "发送间隔", message: "电脑反应慢时调大，防止连续敲入丢码", preferredStyle: .actionSheet)
        for (i, label) in intervalLabels.enumerated() {
            let ms = intervalValues[i]
            a.addAction(UIAlertAction(title: (ms == Prefs.shared.sendIntervalMs ? "✓ " : "") + label,
                                      style: .default) { _ in
                Prefs.shared.sendIntervalMs = ms
                self.intervalBtn.setTitle(self.intervalLabel(forMs: ms), for: .normal)
            })
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        // iPad 上 actionSheet 必须指定锚点
        if let p = a.popoverPresentationController {
            p.sourceView = intervalBtn
            p.sourceRect = intervalBtn.bounds
        }
        present(a, animated: true)
    }

    // MARK: - 关闭（拦截：发送中防误退）
    @objc private func closeTapped() {
        if sending {
            CenterToast.show("正在发送中，请稍候")
            return
        }
        if mode == .auto && !paused {
            let a = UIAlertController(title: "退出自动发送",
                                      message: "自动发送进行中，退出将中止本次任务（进度已保存，可稍后续发）。确定退出？",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "退出", style: .destructive) { _ in
                self.mode = .none
                self.paused = false
                self.pauseReason = nil
                self.dismiss(animated: true)
            })
            a.addAction(UIAlertAction(title: "继续发送", style: .cancel))
            present(a, animated: true)
            return
        }
        if mode != .none {
            CenterToast.show("任务已中止（进度已保存，可稍后续发）")
        }
        dismiss(animated: true)
    }

    // MARK: - 列表
    private func reload() {
        // 全部文件；未发完的排前面，已发送的排后面
        files = ScanStorage.allFiles().sorted { ($0.sent >= $0.total ? 1 : 0) < ($1.sent >= $1.total ? 1 : 0) }
        checked = checked.filter { name in files.contains { $0.name == name } }
        updateSelectAllBtn()
        tableView.reloadData()
        if files.isEmpty {
            tipLabel.text = "暂无存储文件（存储扫描开启时扫码自动存储；点主界面「结束存档」后文件出现在此处）"
        } else {
            tipLabel.text = "勾选已发送的文件=整文件重发；文件发送后保留，可重发或删除"
        }
    }

    private var selectedFiles: [ScanStorage.StoredFile] {
        files.filter { checked.contains($0.name) }
    }

    @objc private func selectAllTapped() {
        let allChecked = !files.isEmpty && files.allSatisfy { checked.contains($0.name) }
        if allChecked { checked.removeAll() } else { files.forEach { checked.insert($0.name) } }
        updateSelectAllBtn()
        tableView.reloadData()
    }

    private func updateSelectAllBtn() {
        let allChecked = !files.isEmpty && files.allSatisfy { checked.contains($0.name) }
        selectAllBtn.setTitle(allChecked ? "取消全选" : "全选", for: .normal)
    }

    // MARK: - 删除
    @objc private func deleteTapped() {
        if sending || mode != .none {
            CenterToast.show("发送任务进行中/暂停中，暂不能删除（先完成或退出任务）")
            return
        }
        let sel = selectedFiles
        if sel.isEmpty {
            CenterToast.show("请先勾选要删除的文件")
            return
        }
        let a = UIAlertController(title: "删除所选文件",
                                  message: "将删除 \(sel.count) 个文件（含未发送的内容），确定？",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            sel.forEach { ScanStorage.delete($0.url) }
            sel.forEach { self.checked.remove($0.name) }
            self.reload()
        })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(a, animated: true)
    }

    // MARK: - 发送：自动（面板）/ 手动（逐条）
    @objc private func autoSendTapped() {
        if sending { return }
        if mode == .manual {
            // 手动 → 自动：接管当前队列，从断点继续自动发
            mode = .auto
            paused = false
            pauseReason = nil
            intervalMs = Prefs.shared.sendIntervalMs
            enterSendPanel()
            updatePanel()
            scheduleNextLine()
            return
        }
        startTask(auto: true)
    }

    @objc private func manualSendTapped() {
        if sending { return }   // 当条确认中，防连点
        if mode == .none {
            startTask(auto: false)
            return
        }
        // 继续发下一条（断线暂停后也从这里续）
        sending = true
        updateSendingBar()
        sendCurrentLine()
    }

    /// 从勾选文件构建发送任务（已发送完的文件=清零进度从头整发）
    private func startTask(auto: Bool) {
        let sel = selectedFiles
        if sel.isEmpty {
            CenterToast.show("请先勾选要发送的文件")
            return
        }
        if ConnectionManager.shared.currentState != .connected {
            CenterToast.show("未连接客户机，无法发送（请回主界面确认连接状态）")
            return
        }
        originalProgress = sel.map { $0.sent }
        sendQueue = sel.map { f in
            if f.sent >= f.total {
                ScanStorage.saveProgress(f.url, sent: 0)
                return ScanStorage.StoredFile(name: f.name, url: f.url, total: f.total, sent: 0)
            }
            return f
        }
        mode = auto ? .auto : .manual
        paused = false
        pauseReason = nil
        intervalMs = Prefs.shared.sendIntervalMs   // 发送期间锁定间隔
        curIdx = 0
        guard positionCurrentFile() else { finishAll(); return }
        if auto {
            enterSendPanel()
            updatePanel()
        } else {
            sendingBar.isHidden = false
            setListEnabled(false)
            sendingBar.text = "手动模式：每点一次「发下一条」发送一条"
        }
        sending = true
        sendCurrentLine()
    }

    /** 定位 sendQueue[curIdx] 的待发内容；false=队列全部发完 */
    private func positionCurrentFile() -> Bool {
        while curIdx < sendQueue.count {
            let f = sendQueue[curIdx]
            curLines = ScanStorage.linesFrom(f.url, from: 0)
            curLineIdx = f.sent
            if curLineIdx >= curLines.count {
                // 边界兜底：无待发内容则跳过该文件
                curIdx += 1
                continue
            }
            return true
        }
        return false
    }

    private func sendCurrentLine() {
        sending = true   // 每条发出即进入"等待确认"状态
        let code = curLines[curLineIdx]
        let msgId = ConnectionManager.shared.sendScanDirect(code, type: "文件发送")
        guard let msgId = msgId else {
            pauseSending(reason: "连接已断开")
            return
        }
        pendingMsgId = msgId
        if mode == .auto { updatePanel() }
        // 超时兜底：3 秒未确认由 ConnectionManager 回调 connAck(ok=false)
    }

    /// 间隔一段时间后发下一条（ACK 已确认，但电脑程序处理需要时间）
    private func scheduleNextLine() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(sendNextByTimer), object: nil)
        perform(#selector(sendNextByTimer), with: nil, afterDelay: TimeInterval(intervalMs) / 1000.0)
    }

    @objc private func sendNextByTimer() {
        guard mode == .auto, !paused, !sending else { return }
        sendCurrentLine()
    }

    private func cancelTimers() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(sendNextByTimer), object: nil)
    }

    // MARK: - ConnListener（ACK 回调驱动状态机）
    func connStateChanged(_ state: ConnectionManager.State) {}

    func connAck(msgId: String, code: String, ok: Bool, reason: String) {
        guard sending, msgId == pendingMsgId else { return }
        let f = sendQueue[curIdx]
        if ok {
            curLineIdx += 1
            ScanStorage.saveProgress(f.url, sent: curLineIdx)
            if curLineIdx >= curLines.count {
                // 当前文件全部发送成功：保留文件（可重发/手动删除）
                let doneName = f.name
                let doneTotal = curLines.count
                curIdx += 1
                let hasNext = positionCurrentFile()
                sending = false
                if mode == .manual {
                    if hasNext {
                        sendingBar.text = "「\(doneName)」已完成（\(doneTotal) 条）→「\(sendQueue[curIdx].name)」（点「发下一条」继续）"
                        updateManualBtn()
                    } else {
                        finishAll()
                    }
                } else {
                    CenterToast.show("「\(doneName)」已发送完成（\(doneTotal) 条）")
                    if hasNext {
                        if paused { updatePanel() } else { scheduleNextLine() }
                    } else {
                        finishAll()
                    }
                }
            } else {
                sending = false
                if mode == .manual {
                    updateSendingBar()
                    updateManualBtn()
                } else {
                    updatePanel()
                    if !paused { scheduleNextLine() }
                }
            }
        } else {
            pauseSending(reason: reason)
        }
    }

    /// 全部发送完成：退出面板恢复列表；取消全部勾选（防止再点发送按钮误重发）
    private func finishAll() {
        sending = false
        mode = .none
        paused = false
        pauseReason = nil
        originalProgress = []
        pendingMsgId = nil
        cancelTimers()
        exitSendPanel()
        setListEnabled(true)
        sendingBar.isHidden = true
        updateManualBtn()
        CenterToast.show("全部发送完成（文件保留，可重发或手动删除）", duration: 2.6)
        checked.removeAll()
        updateSelectAllBtn()
        reload()
    }

    /// 暂停发送（断线/确认失败自动触发）：进度已保存；手动模式保留任务状态
    private func pauseSending(reason: String) {
        sending = false
        pendingMsgId = nil
        cancelTimers()
        if mode == .auto {
            paused = true
            pauseReason = reason
            updatePanel()
        } else {
            // 手动模式：保持列表视图，按钮恢复，等待用户点「发下一条」续发
            setListEnabled(true)
            sendingBar.isHidden = true
            updateManualBtn()
            let f = sendQueue.count > curIdx ? sendQueue[curIdx] : nil
            let tip = (f != nil && !curLines.isEmpty)
                ? "（\(f!.name) 已发 \(curLineIdx)/\(curLines.count) 条，下次从断点继续）" : ""
            CenterToast.show("发送已暂停：\(reason) \(tip)", duration: 2.6)
            reload()
        }
    }

    // MARK: - 重新发送：随时停止任务，文件恢复到进入任务前的状态
    @objc private func resetTapped() {
        if mode == .none && !sending {
            CenterToast.show("当前无发送任务")
            return
        }
        sending = false
        mode = .none
        paused = false
        pauseReason = nil
        pendingMsgId = nil
        cancelTimers()
        // 各文件恢复到任务开始前的进度（在途确认按丢弃处理）
        for i in 0..<sendQueue.count where i < originalProgress.count {
            ScanStorage.saveProgress(sendQueue[i].url, sent: originalProgress[i])
        }
        originalProgress = []
        exitSendPanel()
        setListEnabled(true)
        sendingBar.isHidden = true
        updateManualBtn()
        reload()
        CenterToast.show("任务已停止，文件已恢复到发送前状态，可重新选择发送", duration: 2.6)
    }

    // MARK: - 暂停/恢复
    @objc private func pauseResumeTapped() {
        guard mode == .auto else { return }
        if sending {
            CenterToast.show("当前条等待确认中，稍候")
            return
        }
        if paused {
            if ConnectionManager.shared.currentState != .connected {
                CenterToast.show("未连接客户机，请先恢复连接再继续")
                return
            }
            paused = false
            pauseReason = nil
            updatePanel()
            sendCurrentLine()
        } else {
            paused = true
            pauseReason = nil
            cancelTimers()
            updatePanel()
        }
    }

    // MARK: - 面板与按钮状态
    private func enterSendPanel() {
        sendPanel.isHidden = false
        tableView.isHidden = true
        selectAllBtn.isHidden = true
        deleteBtn.isHidden = true
        intervalLabel.isHidden = true
        intervalBtn.isHidden = true
        tipLabel.isHidden = true
        manualSendBtn.isHidden = true
        autoSendBtn.isHidden = true
    }

    private func exitSendPanel() {
        sendPanel.isHidden = true
        tableView.isHidden = false
        selectAllBtn.isHidden = false
        deleteBtn.isHidden = false
        intervalLabel.isHidden = false
        intervalBtn.isHidden = false
        tipLabel.isHidden = false
        manualSendBtn.isHidden = false
        autoSendBtn.isHidden = false
    }

    private func updatePanel() {
        guard sendQueue.count > curIdx else { return }
        let f = sendQueue[curIdx]
        panelState.text = paused ? (pauseReason != nil ? "已暂停：\(pauseReason!)" : "已暂停") : "自动发送中"
        panelState.textColor = paused ? UIColor(hex: 0x90CAF9) : UIColor(hex: 0xF9A825)
        panelFile.text = "当前文件：\(f.name)"
        panelProgress.text = "\(curLineIdx) / \(curLines.count)"
        panelTotal.text = "第 \(curIdx + 1)/\(sendQueue.count) 个文件 ｜ 每条间隔 \(intervalMs)ms"
        pauseResumeBtn.setTitle(paused ? "恢复发送" : "暂停发送", for: .normal)
    }

    private func updateSendingBar() {
        guard sendQueue.count > curIdx else { return }
        let f = sendQueue[curIdx]
        sendingBar.isHidden = false
        let suffix = (mode == .manual && !sending) ? "（手动：点「发下一条」继续）" : ""
        sendingBar.text = "正在发送「\(f.name)」：\(curLineIdx + 1)/\(curLines.count) 条…（第 \(curIdx + 1)/\(sendQueue.count) 个文件）\(suffix)"
    }

    /** 手动发送按钮文字：任务中显示进度，等待点击 */
    private func updateManualBtn() {
        let inTask = mode == .manual && curIdx < sendQueue.count && curLineIdx < curLines.count
        manualSendBtn.setTitle(inTask ? "发下一条（\(curLineIdx)/\(curLines.count)）" : "手动发送", for: .normal)
    }

    /** 手动任务中：核心按钮保持可用，其余禁用 */
    private func setListEnabled(_ en: Bool) {
        let manualMode = mode == .manual
        autoSendBtn.isEnabled = manualMode ? true : en
        deleteBtn.isEnabled = en
        selectAllBtn.isEnabled = en
        tableView.allowsSelection = en
    }
}

// MARK: - 文件列表
extension FilesViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "fileCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "fileCell")
        let f = files[indexPath.row]
        cell.backgroundColor = UIColor(hex: 0x2A2A2A)
        cell.selectionStyle = .none
        // 状态：已发送(绿) / 已发X/N待续发(黄) / 未发送(白)
        let status: String, color: UIColor
        if f.sent >= f.total {
            status = "已发送 \(f.total) 条"; color = UIColor(hex: 0xA5D6A7)
        } else if f.sent > 0 {
            status = "已发 \(f.sent)/\(f.total)（待续发）"; color = UIColor(hex: 0xF9A825)
        } else {
            status = "共 \(f.total) 条"; color = UIColor(hex: 0xE0E0E0)
        }
        cell.textLabel?.text = f.name
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        cell.detailTextLabel?.text = status
        cell.detailTextLabel?.textColor = color
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)
        // 勾选开关
        let sw = UISwitch()
        sw.tag = indexPath.row
        sw.onTintColor = UIColor(hex: 0x2E7D32)
        sw.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        sw.isOn = checked.contains(f.name)
        sw.addTarget(self, action: #selector(rowSwitchChanged(_:)), for: .valueChanged)
        cell.accessoryView = sw
        return cell
    }

    @objc private func rowSwitchChanged(_ sw: UISwitch) {
        let f = files[sw.tag]
        if sw.isOn { checked.insert(f.name) } else { checked.remove(f.name) }
        updateSelectAllBtn()
    }
}
