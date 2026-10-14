import UIKit
import AVFoundation

/// 主界面（复刻安卓版）：
/// - 状态横幅（未配对/连接中/已连接/断开，只读展示；重新配对走底部「重新配对」按钮）
/// - 存储控制行：存储/实时切换按钮（实时模式标红醒目）/ 撤销 / 结束存档 / 储存发送
/// - 相机预览区：中央取景框（多码同屏只认框内码，位置偏上）+ 变焦手势 + 闪光灯 + 扫描按钮（手动模式）
/// - 功能按钮行：模式 / 闪光灯 / 手动输入 / 重新配对
/// - 统计栏：本次统计 + 清零 + 扫描历史
class ScanViewController: UIViewController, ConnListener {

    // MARK: - UI
    private let banner = UILabel()
    private let storageBtn = UIButton(type: .system)
    private let undoBtn = UIButton(type: .system)
    private let finishBtn = UIButton(type: .system)
    private let sendFilesBtn = UIButton(type: .system)
    private let previewView = UIView()
    private let frameBox = UIView()
    private let frameTip = UILabel()
    private let scanBtn = UIButton(type: .system)
    private let flashView = UIView()
    private let flashLabel = UILabel()
    private let modeBtn = UIButton(type: .system)
    private let torchBtn = UIButton(type: .system)
    private let manualBtn = UIButton(type: .system)
    private let pairBtn = UIButton(type: .system)
    private let statsLabel = UILabel()
    private let clearBtn = UIButton(type: .system)
    private let historyBtn = UIButton(type: .system)

    // MARK: - 相机
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?
    private var cameraAuthorized = false
    private var pinchStartZoom: CGFloat = 1
    private var torchOn = false

    // MARK: - 扫描状态
    private var scanSession = false          // 手动模式：按钮按下后待识别
    private var sessionTimeout: DispatchWorkItem?
    private var lastCode = ""
    private var lastCodeAt = Date.distantPast
    private var lastSendAt = Date.distantPast
    private var lastScanSuccessAt = Date.distantPast   // 最近识别成功时刻（扫描按钮1秒防抖用）

    // MARK: - 本次统计（APP 启动后累计，可手动清零，重启自动归零）
    private var cntTotal = 0
    private var cntOk = 0
    private var cntFail = 0
    private var cntPending = 0
    private var statsState: [String: Int] = [:]   // msgId -> 0发送/1成功/2失败

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        // 每次打开 APP 默认存储扫描模式（不保留上次的选择）
        Prefs.shared.storageMode = true
        view.backgroundColor = UIColor(hex: 0x0E0E0E)
        buildUI()
        setupCamera()
        ConnectionManager.shared.addListener(self)
        ConnectionManager.shared.connect()
        updateBanner()
        renderStats()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshFilesBtn()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView.bounds
        // 取景框手动布局（宽66%、高26%、中心在预览区32%高度处，偏上且完整可见）
        let b = previewView.bounds
        if b.width > 10, b.height > 10 {
            let fw = b.width * 0.66
            let fh = b.height * 0.26
            frameBox.frame = CGRect(x: (b.width - fw) / 2, y: b.height * 0.19,
                                    width: fw, height: fh)
            frameTip.sizeToFit()
            frameTip.frame = CGRect(x: (b.width - frameTip.bounds.width) / 2,
                                    y: b.height * 0.19 + fh + 12,
                                    width: frameTip.bounds.width,
                                    height: frameTip.bounds.height)
        }
    }

    // MARK: - UI 构建
    private func buildUI() {
        let safe = view.safeAreaLayoutGuide

        // 状态横幅（只读展示，重新配对走底部「重新配对」按钮）
        banner.font = .systemFont(ofSize: 14, weight: .medium)
        banner.textColor = .white
        banner.textAlignment = .center
        banner.adjustsFontSizeToFitWidth = true
        banner.minimumScaleFactor = 0.8
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: safe.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: 44)
        ])

        // 存储控制行：存储/实时（点击切换，实时标红）/ 撤销 / 结束存档 / 储存发送（四按钮平分宽度）
        let storageRow = UIStackView()
        storageRow.axis = .horizontal
        storageRow.spacing = 8
        storageRow.distribution = .fillEqually
        storageRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(storageRow)
        NSLayoutConstraint.activate([
            storageRow.topAnchor.constraint(equalTo: banner.bottomAnchor),
            storageRow.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            storageRow.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            storageRow.heightAnchor.constraint(equalToConstant: 52)
        ])

        styleBtn(storageBtn, title: "")
        storageBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        storageBtn.addTarget(self, action: #selector(storageToggled), for: .touchUpInside)
        storageRow.addArrangedSubview(storageBtn)
        styleBtn(undoBtn, title: "撤销")
        undoBtn.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        storageRow.addArrangedSubview(undoBtn)
        styleBtn(finishBtn, title: "结束存档")
        finishBtn.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
        storageRow.addArrangedSubview(finishBtn)
        styleBtn(sendFilesBtn, title: "储存发送")
        sendFilesBtn.addTarget(self, action: #selector(sendFilesTapped), for: .touchUpInside)
        storageRow.addArrangedSubview(sendFilesBtn)

        // 相机预览区（占据剩余空间；底部约束在统计栏建立后激活——预览区在统计栏上方结束）
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .black
        previewView.clipsToBounds = true
        view.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: storageRow.bottomAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // 中央取景框 + 下沿提示：宽66%、高26%、中心在预览区32%高度处（偏上且完整可见）。
        // ⚠️ 手动布局（viewDidLayoutSubviews 设 frame，对齐安卓端做法）：
        // .top 对 .height 的比例约束在 iOS 26 上抛 NSInvalidArgumentException 直接闪退（本次崩溃原因）
        frameBox.layer.borderColor = UIColor(white: 1, alpha: 0.85).cgColor
        frameBox.layer.borderWidth = 2
        frameBox.layer.cornerRadius = 14
        previewView.addSubview(frameBox)
        frameTip.text = "将条码对准框内"
        frameTip.font = .systemFont(ofSize: 12)
        frameTip.textColor = UIColor(white: 1, alpha: 0.8)
        previewView.addSubview(frameTip)

        // 扫码结果闪烁反馈层（预览区居中）
        flashView.backgroundColor = UIColor(white: 0, alpha: 0.8)
        flashView.isHidden = true
        flashView.layer.cornerRadius = 10
        flashView.translatesAutoresizingMaskIntoConstraints = false
        previewView.addSubview(flashView)
        flashLabel.font = .systemFont(ofSize: 17, weight: .bold)
        flashLabel.textAlignment = .center
        flashLabel.numberOfLines = 0
        flashLabel.textColor = .white
        flashLabel.adjustsFontSizeToFitWidth = true
        flashLabel.minimumScaleFactor = 0.5
        flashLabel.translatesAutoresizingMaskIntoConstraints = false
        flashView.addSubview(flashLabel)
        NSLayoutConstraint.activate([
            flashView.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            flashView.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),
            flashView.leadingAnchor.constraint(greaterThanOrEqualTo: previewView.leadingAnchor, constant: 20),
            flashView.trailingAnchor.constraint(lessThanOrEqualTo: previewView.trailingAnchor, constant: -20),
            flashLabel.topAnchor.constraint(equalTo: flashView.topAnchor, constant: 16),
            flashLabel.bottomAnchor.constraint(equalTo: flashView.bottomAnchor, constant: -16),
            flashLabel.leadingAnchor.constraint(equalTo: flashView.leadingAnchor, constant: 18),
            flashLabel.trailingAnchor.constraint(equalTo: flashView.trailingAnchor, constant: -18)
        ])

        // 手动模式专用大扫描按钮（预览区底部）
        scanBtn.setTitle("扫 描", for: .normal)
        scanBtn.titleLabel?.font = .boldSystemFont(ofSize: 20)
        scanBtn.backgroundColor = UIColor(hex: 0x2E7D32)
        scanBtn.setTitleColor(.white, for: .normal)
        scanBtn.layer.cornerRadius = 12
        scanBtn.translatesAutoresizingMaskIntoConstraints = false
        scanBtn.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        previewView.addSubview(scanBtn)
        NSLayoutConstraint.activate([
            scanBtn.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            scanBtn.bottomAnchor.constraint(equalTo: previewView.bottomAnchor, constant: -20),
            scanBtn.widthAnchor.constraint(equalToConstant: 170),
            scanBtn.heightAnchor.constraint(equalToConstant: 58)
        ])

        // 功能按钮行：模式 / 闪光灯 / 手动输入 / 重新配对
        let funcRow = UIStackView()
        funcRow.axis = .horizontal
        funcRow.distribution = .fillEqually
        funcRow.spacing = 8
        funcRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(funcRow)
        NSLayoutConstraint.activate([
            funcRow.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            funcRow.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
            funcRow.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            funcRow.heightAnchor.constraint(equalToConstant: 52)
        ])
        for (b, sel) in [(modeBtn, #selector(modeTapped)), (torchBtn, #selector(torchTapped)),
                         (manualBtn, #selector(manualTapped)), (pairBtn, #selector(pairTapped))] {
            styleBtn(b, title: "")
            b.titleLabel?.font = .systemFont(ofSize: 13)
            b.addTarget(self, action: sel, for: .touchUpInside)
            funcRow.addArrangedSubview(b)
        }
        // 初始标题（模式按钮由 applyMode 设置；其余三个在此设置，避免空白按钮）
        torchBtn.setTitle("闪光灯 关", for: .normal)
        manualBtn.setTitle("手动输入", for: .normal)
        pairBtn.setTitle("重新配对", for: .normal)

        // 统计栏
        let statsRow = UIStackView()
        statsRow.axis = .horizontal
        statsRow.spacing = 8
        statsRow.alignment = .center
        statsRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsRow)
        NSLayoutConstraint.activate([
            statsRow.bottomAnchor.constraint(equalTo: funcRow.topAnchor, constant: -6),
            statsRow.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            statsRow.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            statsRow.heightAnchor.constraint(equalToConstant: 44)
        ])
        statsLabel.font = .systemFont(ofSize: 12)
        statsLabel.textColor = .white
        statsLabel.adjustsFontSizeToFitWidth = true
        statsLabel.minimumScaleFactor = 0.55
        statsRow.addArrangedSubview(statsLabel)
        styleBtn(clearBtn, title: "清零")
        clearBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        clearBtn.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        statsRow.addArrangedSubview(clearBtn)
        styleBtn(historyBtn, title: "扫描历史")
        historyBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        historyBtn.addTarget(self, action: #selector(historyTapped), for: .touchUpInside)
        statsRow.addArrangedSubview(historyBtn)

        // 预览区底部约束（此时统计栏已在层级中）：预览区在统计栏上方结束，不与按钮行重叠
        previewView.bottomAnchor.constraint(equalTo: statsRow.topAnchor).isActive = true

        // 变焦手势：双击 1x↔2.5x；双指捏合自由缩放（识别小/远二维码用）
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchZoom(_:)))
        previewView.addGestureRecognizer(pinch)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapZoom))
        doubleTap.numberOfTapsRequired = 2
        previewView.addGestureRecognizer(doubleTap)

        applyStorageBtn()
        applyMode()
    }

    private func styleBtn(_ b: UIButton, title: String) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        // 复刻安卓 Material3 默认按钮主色（紫），醒目
        b.backgroundColor = UIColor(hex: 0x6750A4)
        b.layer.cornerRadius = 8
        b.titleLabel?.font = .systemFont(ofSize: 14)
        b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - 存储/模式 UI
    /// 存储模式按钮状态：存储扫描=默认紫色；实时扫描=红色醒目（即扫即发防误发）
    private func applyStorageBtn() {
        let on = Prefs.shared.storageMode
        storageBtn.setTitle(on ? "存储扫描" : "实时扫描", for: .normal)
        storageBtn.backgroundColor = on ? UIColor(hex: 0x6750A4) : UIColor(hex: 0xC62828)
    }

    /// 点一次切换一次：存储扫描（只存不发）⇄ 实时扫描（即扫即发，按钮标红醒目）
    @objc private func storageToggled() {
        Prefs.shared.storageMode.toggle()
        applyStorageBtn()
        renderStats()
        CenterToast.show(Prefs.shared.storageMode ? "存储扫描已开启：扫码只存不发，在「储存发送」中统一发送"
                                                  : "存储扫描已关闭：扫码恢复即扫即发")
    }

    /// 撤销：删除当前活动文件的最后一条存储记录（仅存储模式可用）。
    /// 连点连撤；同时联动统计计数与扫描历史
    @objc private func undoTapped() {
        guard Prefs.shared.storageMode else {
            CenterToast.show("实时模式不支持撤销（码已发送到电脑）")
            return
        }
        guard let removed = ScanStorage.undoLast() else {
            CenterToast.show("没有可撤销的数据")
            return
        }
        HistoryStore.shared.undoLastStored()
        if cntTotal > 0 { cntTotal -= 1 }
        renderStats()
        Beep.fail()   // 撤销提示音（低沉音，与存储成功的上扬音区分）
        flash("已撤销\n\(removed)", style: .bad)
        CenterToast.show("已撤销：\(removed)")
    }

    // MARK: - 相机
    private func setupCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startSession() }
                    else { self?.alertNoCamera() }
                }
            }
        default: alertNoCamera()
        }
    }

    private func startSession() {
        cameraAuthorized = true
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let device = AVCaptureDevice.default(for: .video) else { return }
            guard let input = try? AVCaptureDeviceInput(device: device),
                  self.captureSession.canAddInput(input) else { return }
            let output = AVCaptureMetadataOutput()
            guard self.captureSession.canAddOutput(output) else { return }
            self.captureSession.addInput(input)
            self.captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            // ⚠️ 不能直接赋 availableMetadataObjectTypes（iOS17/18 真机会因含
            // session 此刻不支持的类型抛 NSInvalidArgumentException 闪退），
            // 改为显式列表 + 过滤出实际支持的
            let wanted: [AVMetadataObject.ObjectType] = [
                .qr, .ean13, .ean8, .code128, .code39, .code93,
                .upce, .interleaved2of5, .aztec, .pdf417, .dataMatrix
            ]
            output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
            self.captureDevice = device
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.previewView.bounds
                self.previewView.layer.insertSublayer(layer, at: 0)
                self.previewLayer = layer
            }
        }
    }

    private func alertNoCamera() {
        let a = UIAlertController(title: "无法使用相机",
                                  message: "请在 设置→隐私→相机 中允许「无线扫码枪」使用相机",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

    // MARK: - 变焦 / 闪光灯
    @objc private func pinchZoom(_ g: UIPinchGestureRecognizer) {
        guard let d = captureDevice else { return }
        if g.state == .began { pinchStartZoom = d.videoZoomFactor }
        let maxZ = min(d.activeFormat.videoMaxZoomFactor, 8)
        let f = max(1, min(maxZ, pinchStartZoom * g.scale))
        try? d.lockForConfiguration()
        d.videoZoomFactor = f
        d.unlockForConfiguration()
    }

    @objc private func doubleTapZoom() {
        guard let d = captureDevice else { return }
        let target: CGFloat = d.videoZoomFactor > 1.05 ? 1 : min(2.5, d.activeFormat.videoMaxZoomFactor)
        try? d.lockForConfiguration()
        d.videoZoomFactor = target
        d.unlockForConfiguration()
    }

    @objc private func torchTapped() {
        guard let d = captureDevice, d.hasTorch else {
            CenterToast.show("此设备不支持闪光灯")
            return
        }
        torchOn.toggle()
        try? d.lockForConfiguration()
        d.torchMode = torchOn ? .on : .off
        d.unlockForConfiguration()
        torchBtn.setTitle(torchOn ? "闪光灯 开" : "闪光灯 关", for: .normal)
    }

    // MARK: - 扫描动作（手动会话：按一下扫一次；5 秒未识别自动结束）
    @objc private func scanTapped() {
        // 防抖：识别成功后 1 秒内忽略点击（防止手快连点对同码开多余会话重复录入）
        if Date().timeIntervalSince(lastScanSuccessAt) < 1.0 { return }
        guard cameraAuthorized else { return setupCamera() }
        if scanSession {
            endSession()
            CenterToast.show("已取消本次扫描")
            return
        }
        scanSession = true
        scanBtn.setTitle("识别中…\n（点按取消）", for: .normal)
        scanBtn.backgroundColor = UIColor(hex: 0x555555)
        sessionTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if self?.scanSession == true {
                self?.endSession()
                CenterToast.show("未识别到条码")
            }
        }
        sessionTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func endSession() {
        scanSession = false
        sessionTimeout?.cancel()
        sessionTimeout = nil
        scanBtn.setTitle("扫 描", for: .normal)
        scanBtn.backgroundColor = UIColor(hex: 0x2E7D32)
    }

    // MARK: - 模式
    @objc private func modeTapped() {
        Prefs.shared.manualMode.toggle()
        applyMode()
        CenterToast.show(Prefs.shared.manualMode ? "已切换为手动扫描（按一下扫一次）" : "已切换为自动扫描")
    }

    private func applyMode() {
        let manual = Prefs.shared.manualMode
        modeBtn.setTitle(manual ? "模式：手动" : "模式：自动", for: .normal)
        scanBtn.isHidden = !manual
        endSession()
    }

    // MARK: - 手动输入 / 配对 / 历史跳转
    @objc private func manualTapped() {
        let a = UIAlertController(title: "手动输入", message: nil, preferredStyle: .alert)
        a.addTextField { $0.placeholder = "输入要发送的内容" }
        a.addAction(UIAlertAction(title: "发送", style: .default) { _ in
            let t = a.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !t.isEmpty { self.onScan(t, "手动输入") }
        })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(a, animated: true)
    }

    @objc private func pairTapped() { presentPairing() }

    private func presentPairing() {
        let nav = UINavigationController(rootViewController: PairingViewController())
        present(nav, animated: true)
    }

    @objc private func historyTapped() {
        present(HistoryViewController(), animated: true)
    }

    @objc private func sendFilesTapped() {
        present(FilesViewController(), animated: true)
    }

    // MARK: - 结束存档
    @objc private func finishTapped() {
        guard let info = ScanStorage.currentInfo() else {
            CenterToast.show("当前没有存储中的文件（先开启存储扫描并扫码）")
            return
        }
        let a = UIAlertController(title: "结束存档（可修改文件名）",
                                  message: "共 \(info.1) 条，保存后可在「储存发送」中发送",
                                  preferredStyle: .alert)
        a.addTextField { [weak self] in
            $0.text = info.0
            self?.setupRenameField($0)
        }
        a.addAction(UIAlertAction(title: "保存", style: .default) { _ in
            let name = a.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            self.saveFinishedFile(name)
        })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(a, animated: true)
    }

    private func setupRenameField(_ f: UITextField) {
        // 预填的自动名需要全选便于直接覆盖输入
        DispatchQueue.main.async {
            f.selectedTextRange = f.textRange(from: f.beginningOfDocument, to: f.endOfDocument)
        }
    }

    private func saveFinishedFile(_ name: String) {
        switch true {
        case name.isEmpty:
            CenterToast.show("文件名不能为空，未存档")
        case name.contains(where: { "\\/:*?\"<>|".contains($0) }):
            CenterToast.show("文件名不能包含 / \\ : * ? \" < > | 字符，未存档")
        // 重名校验须排除当前活动文件自身（活动文件已在磁盘上，不排除则预填的自动名永远"重名"）
        case name != ScanStorage.currentInfo()?.0 && ScanStorage.nameExists(name):
            CenterToast.show("已存在同名文件「\(name)」，请重新存档并换个名字")
        default:
            if let result = ScanStorage.finishCurrent(newName: name) {
                // 新批次开始：本次计数清零，已存储随活动文档封存自动归零（扫描历史保留）
                cntTotal = 0; cntOk = 0; cntFail = 0; cntPending = 0
                statsState.removeAll()
                renderStats()
                CenterToast.show("已保存「\(result.0)」（\(result.1)条），可在「储存发送」中发送；下次扫码将存入新文件", duration: 3)
            }
        }
        refreshFilesBtn()
    }

    // MARK: - 储存发送按钮角标（未发完文件数）
    private func refreshFilesBtn() {
        let n = ScanStorage.allFiles().filter { $0.sent < $0.total }.count
        sendFilesBtn.setTitle(n > 0 ? "储存发送(\(n))" : "储存发送", for: .normal)
    }

    // MARK: - 扫码入口（取景框筛选后）
    private func onScan(_ code: String, _ type: String) {
        lastScanSuccessAt = Date()   // 扫描按钮防抖基准：识别成功时刻
        guard Prefs.shared.isPaired else {
            CenterToast.show("请先完成配对（点底部「重新配对」）")
            Beep.fail()
            return
        }
        if Prefs.shared.storageMode {
            // 存储模式：只存不发，实时写入活动文件
            let n = ScanStorage.append(code)
            cntTotal += 1
            HistoryStore.shared.addStored(code)
            Beep.ok()
            flash("已存储（本文件 \(n) 条）\n\(code)", style: .good)
            renderStats()
            return
        }
        let msgId = ConnectionManager.shared.sendScan(code, type: type)
        HistoryStore.shared.addPending(msgId, code)
        statsSend(msgId)
        flash("已发送\n\(code)", style: .neutral)
    }

    // MARK: - ConnListener
    func connStateChanged(_ state: ConnectionManager.State) { updateBanner() }
    func connWelcome(machine: String) { updateBanner() }

    func connAck(msgId: String, code: String, ok: Bool, reason: String) {
        statsAck(msgId, ok: ok)
        HistoryStore.shared.update(msgId, status: ok ? .ok : .fail, reason: reason)
        if ok {
            Beep.ok()
            flash("√ 已录入\n\(code)", style: .good)
        } else {
            Beep.fail()
            flash("× 未录入\n\(reason.isEmpty ? "客户机未确认" : reason)", style: .bad)
        }
    }

    // MARK: - 状态横幅
    private func updateBanner() {
        let cm = ConnectionManager.shared
        switch true {
        case !Prefs.shared.isPaired:
            setBanner("未配对，点底部「重新配对」选择客户机", UIColor(hex: 0xC62828))
        case cm.currentState == .connected:
            setBanner("已连接：\(cm.pcName)（\(Prefs.shared.host)）", UIColor(hex: 0x2E7D32))
        case cm.currentState == .connecting:
            setBanner("连接中…", UIColor(hex: 0xF9A825))
        default:
            setBanner("连接断开，自动重连中…", UIColor(hex: 0xC62828))
        }
    }

    private func setBanner(_ text: String, _ color: UIColor) {
        banner.text = text
        banner.backgroundColor = color
    }

    // MARK: - 闪烁反馈层
    private enum FlashStyle { case good, bad, neutral }

    private func flash(_ text: String, style: FlashStyle) {
        flashLabel.text = text
        flashView.backgroundColor = {
            switch style {
            case .good: return UIColor(hex: 0x1B5E20, alpha: 0.8)
            case .bad: return UIColor(hex: 0xB71C1C, alpha: 0.8)
            case .neutral: return UIColor(white: 0, alpha: 0.8)
            }
        }()
        flashView.isHidden = false
        flashView.layer.removeAllAnimations()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideFlash), object: nil)
        perform(#selector(hideFlash), with: nil, afterDelay: 1.4)
    }

    @objc private func hideFlash() { flashView.isHidden = true }

    // MARK: - 统计
    private func statsSend(_ msgId: String) {
        statsState[msgId] = 0
        cntTotal += 1
        cntPending += 1
        // 上限 300 条状态记录，避免无限增长
        while statsState.count > 300 { statsState.removeValue(forKey: statsState.keys.first!) }
        renderStats()
    }

    private func statsAck(_ msgId: String, ok: Bool) {
        switch statsState[msgId] {
        case 0:
            cntPending -= 1
            if ok { cntOk += 1 } else { cntFail += 1 }
        case 2 where ok:
            // 超时判定失败后迟到的成功回执：改为成功
            cntFail -= 1
            cntOk += 1
        default:
            return
        }
        statsState[msgId] = ok ? 1 : 2
        renderStats()
    }

    /// 清零：只清"本次"计数与扫描历史；「已存储」跟随当前活动文档（结束存档才归零）
    @objc private func clearTapped() {
        cntTotal = 0; cntOk = 0; cntFail = 0; cntPending = 0
        statsState.removeAll()
        HistoryStore.shared.clear()
        renderStats()
        CenterToast.show("本次计数与历史已清零（已存储保持）")
    }

    /// 统计栏：本次数字绿色加粗、已存储数字红色加粗（只着色数字，标签保持白色）
    private func renderStats() {
        let ssb = NSMutableAttributedString()
        appendStat(ssb, label: "本次：", num: cntTotal, color: UIColor(hex: 0x66BB6A))
        if Prefs.shared.storageMode {
            ssb.append(plainStat(" ｜ "))
            appendStat(ssb, label: "已存储 ", num: storedCount(), color: UIColor(hex: 0xEF5350))
            ssb.append(plainStat("（存储模式：只存不发）"))
        } else {
            ssb.append(plainStat(" ｜ 成功 \(cntOk) ｜ 失败 \(cntFail) ｜ 待确认 \(cntPending)"))
        }
        statsLabel.attributedText = ssb
    }

    /// 追加"白色标签 + 彩色加粗数字"统计段
    private func appendStat(_ ssb: NSMutableAttributedString, label: String, num: Int, color: UIColor) {
        ssb.append(plainStat(label))
        ssb.append(NSAttributedString(string: String(num), attributes: [
            .font: UIFont.boldSystemFont(ofSize: 13),
            .foregroundColor: color
        ]))
    }

    private func plainStat(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: UIColor.white
        ])
    }

    /// 已存储 = 当前活动文档累计条数（存储/撤销自动增减，清零按钮不影响，
    ///  结束存档或重启 APP 开新文档后自动归零）
    private func storedCount() -> Int {
        ScanStorage.currentInfo()?.1 ?? 0
    }
}

// MARK: - 相机识别回调（中央取景框筛选）
extension ScanViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let layer = previewLayer else { return }
        // 取景框判定：只认码中心落在取景框（每边略放大）内的码；多个码取最居中的
        let fr = frameBox.frame
        guard fr.width > 10, fr.height > 10 else { return }
        let padX = fr.width * 0.05
        let padY = fr.height * 0.08
        var best: (value: String, type: String, dist: CGFloat)?
        for obj in metadataObjects {
            guard let m = obj as? AVMetadataMachineReadableCodeObject,
                  let v = m.stringValue, !v.isEmpty,
                  let t = layer.transformedMetadataObject(for: m) else { continue }
            let cx = t.bounds.midX, cy = t.bounds.midY
            if cx < fr.minX - padX || cx > fr.maxX + padX || cy < fr.minY - padY || cy > fr.maxY + padY { continue }
            let dx = cx - fr.midX, dy = cy - fr.midY
            let d = dx * dx + dy * dy
            if best == nil || d < best!.dist {
                best = (v, codeTypeName(m.type.rawValue), d)
            }
        }
        guard let hit = best else { return }

        if Prefs.shared.manualMode {
            // 手动模式：仅在扫描会话进行中识别，识别到立即结束会话
            guard scanSession else { return }
            endSession()
            onScan(hit.value, hit.type)
        } else {
            // 自动模式：连续识别，冷却去重防重复发送
            let now = Date()
            if now.timeIntervalSince(lastSendAt) < 0.7 { return }
            if hit.value == lastCode, now.timeIntervalSince(lastCodeAt) < 2.0 { return }
            lastCode = hit.value
            lastCodeAt = now
            lastSendAt = now
            onScan(hit.value, hit.type)
        }
    }

    private func codeTypeName(_ raw: String) -> String {
        switch raw {
        case "org.iso.QRCode": return "二维码"
        case "org.gs1.EAN-13": return "EAN-13"
        case "org.gs1.EAN-8": return "EAN-8"
        case "org.iso.Code128": return "CODE-128"
        case "org.iso.Code39": return "CODE-39"
        case "org.iso.Code93": return "CODE-93"
        case "org.gs1.UPC-A": return "UPC-A"
        case "org.gs1.UPC-E": return "UPC-E"
        case "org.iso.ITF": return "ITF"
        case "com.intermec.Codabar": return "CODABAR"
        case "org.iso.PDF417": return "PDF417"
        case "org.iso.Aztec": return "Aztec"
        case "org.iso.DataMatrix": return "DataMatrix"
        default: return "条码"
        }
    }
}

// MARK: - UIColor 便捷
extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: alpha)
    }
}
