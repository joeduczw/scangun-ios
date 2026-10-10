import UIKit
import AVFoundation

private struct ScanRecord {
    let msgId: String
    let code: String
    let type: String
    var ok: Bool?          // nil=待确认
    var lateFixed = false  // 超时后迟到成功回执已修正
    let time: Date
}

class ScanViewController: UIViewController {
    // MARK: - UI
    private let statusLabel = UILabel()
    private let modeBtn = UIButton(type: .system)
    private let pairBtn = UIButton(type: .system)
    private let previewView = UIView()
    private let frameBox = UIView()
    private let scanBtn = UIButton(type: .system)
    private let statsLabel = UILabel()
    private let clearBtn = UIButton(type: .system)
    private let historyTitle = UILabel()
    private let resendSwitch = UISwitch()
    private let tableView = UITableView()
    private let manualField = UITextField()
    private let manualBtn = UIButton(type: .system)
    private let flashView = UIView()
    private let flashLabel = UILabel()

    // MARK: - 相机
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var cameraAuthorized = false

    // MARK: - 扫描状态
    private var armed = false                 // 手动模式：按钮按下后待识别
    private var manualTimeout: DispatchWorkItem?
    private var lastCode = ""
    private var lastCodeAt = Date.distantPast

    // MARK: - 记录
    private var records: [ScanRecord] = []
    private var recordIndex: [String: Int] = [:]

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.1, alpha: 1)
        buildUI()
        setupCamera()
        bindConnection()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView.bounds
    }

    // MARK: - UI 构建
    private func buildUI() {
        let safe = view.safeAreaLayoutGuide

        // 状态横幅
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor(white: 0.25, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            statusLabel.heightAnchor.constraint(equalToConstant: 32)
        ])

        // 模式按钮（左上）
        styleNavBtn(modeBtn, title: "模式:手动")
        modeBtn.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            modeBtn.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            modeBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            modeBtn.widthAnchor.constraint(equalToConstant: 86),
            modeBtn.heightAnchor.constraint(equalToConstant: 32)
        ])

        // 配对按钮（右上）
        styleNavBtn(pairBtn, title: "配对")
        pairBtn.addTarget(self, action: #selector(pairTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            pairBtn.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            pairBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            pairBtn.widthAnchor.constraint(equalToConstant: 64),
            pairBtn.heightAnchor.constraint(equalToConstant: 32)
        ])

        // 相机预览
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .black
        view.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.heightAnchor.constraint(equalTo: previewView.widthAnchor, multiplier: 1.2)
        ])

        // 取景框
        frameBox.layer.borderColor = UIColor(white: 1, alpha: 0.9).cgColor
        frameBox.layer.borderWidth = 2
        frameBox.layer.cornerRadius = 12
        frameBox.translatesAutoresizingMaskIntoConstraints = false
        previewView.addSubview(frameBox)
        NSLayoutConstraint.activate([
            frameBox.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            frameBox.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),
            frameBox.widthAnchor.constraint(equalTo: previewView.widthAnchor, multiplier: 0.8),
            frameBox.heightAnchor.constraint(equalToConstant: 170)
        ])

        // 扫描按钮（手动模式）
        scanBtn.setTitle("扫 描", for: .normal)
        scanBtn.titleLabel?.font = .boldSystemFont(ofSize: 20)
        scanBtn.backgroundColor = UIColor(red: 0.18, green: 0.64, blue: 0.33, alpha: 1)
        scanBtn.setTitleColor(.white, for: .normal)
        scanBtn.layer.cornerRadius = 12
        scanBtn.translatesAutoresizingMaskIntoConstraints = false
        scanBtn.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        view.addSubview(scanBtn)
        NSLayoutConstraint.activate([
            scanBtn.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 12),
            scanBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scanBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scanBtn.heightAnchor.constraint(equalToConstant: 54)
        ])

        // 统计栏
        statsLabel.font = .systemFont(ofSize: 13)
        statsLabel.textColor = .white
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsLabel)
        clearBtn.setTitle("清零", for: .normal)
        clearBtn.titleLabel?.font = .systemFont(ofSize: 13)
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        view.addSubview(clearBtn)
        NSLayoutConstraint.activate([
            statsLabel.topAnchor.constraint(equalTo: scanBtn.bottomAnchor, constant: 12),
            statsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            clearBtn.centerYAnchor.constraint(equalTo: statsLabel.centerYAnchor),
            clearBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            clearBtn.leadingAnchor.constraint(greaterThanOrEqualTo: statsLabel.trailingAnchor, constant: 8)
        ])

        // 历史标题 + 重发开关
        historyTitle.text = "扫码历史"
        historyTitle.font = .boldSystemFont(ofSize: 14)
        historyTitle.textColor = UIColor(white: 0.85, alpha: 1)
        historyTitle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(historyTitle)
        let rsLabel = UILabel()
        rsLabel.text = "点击重发"
        rsLabel.font = .systemFont(ofSize: 12)
        rsLabel.textColor = .lightGray
        let rsWrap = UIStackView(arrangedSubviews: [rsLabel, resendSwitch])
        rsWrap.spacing = 6
        rsWrap.translatesAutoresizingMaskIntoConstraints = false
        resendSwitch.isOn = Prefs.shared.resendEnabled
        resendSwitch.addTarget(self, action: #selector(resendChanged), for: .valueChanged)
        view.addSubview(rsWrap)
        NSLayoutConstraint.activate([
            historyTitle.topAnchor.constraint(equalTo: statsLabel.bottomAnchor, constant: 12),
            historyTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            rsWrap.centerYAnchor.constraint(equalTo: historyTitle.centerYAnchor),
            rsWrap.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])

        // 历史列表
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 0.3, alpha: 1)
        tableView.rowHeight = 48
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: historyTitle.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: manualField.topAnchor, constant: -8)
        ])

        // 手动输入
        manualField.placeholder = "手动输入条码（备用）"
        manualField.borderStyle = .roundedRect
        manualField.autocorrectionType = .no
        manualField.keyboardType = .numbersAndPunctuation
        manualField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(manualField)
        manualBtn.setTitle("发送", for: .normal)
        manualBtn.translatesAutoresizingMaskIntoConstraints = false
        manualBtn.addTarget(self, action: #selector(manualTapped), for: .touchUpInside)
        view.addSubview(manualBtn)
        NSLayoutConstraint.activate([
            manualField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            manualField.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            manualField.heightAnchor.constraint(equalToConstant: 40),
            manualBtn.leadingAnchor.constraint(equalTo: manualField.trailingAnchor, constant: 8),
            manualBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            manualBtn.centerYAnchor.constraint(equalTo: manualField.centerYAnchor),
            manualBtn.widthAnchor.constraint(equalToConstant: 64),
            manualBtn.heightAnchor.constraint(equalToConstant: 40)
        ])

        // 全屏闪烁反馈层
        flashView.backgroundColor = UIColor(white: 0, alpha: 0.75)
        flashView.isHidden = true
        flashView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(flashView)
        flashLabel.font = .systemFont(ofSize: 40, weight: .bold)
        flashLabel.textAlignment = .center
        flashLabel.translatesAutoresizingMaskIntoConstraints = false
        flashView.addSubview(flashLabel)
        NSLayoutConstraint.activate([
            flashView.topAnchor.constraint(equalTo: view.topAnchor),
            flashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            flashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            flashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            flashLabel.centerXAnchor.constraint(equalTo: flashView.centerXAnchor),
            flashLabel.centerYAnchor.constraint(equalTo: flashView.centerYAnchor)
        ])

        applyModeUI()
        refreshStats()
    }

    private func styleNavBtn(_ b: UIButton, title: String) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor(white: 0.25, alpha: 1)
        b.layer.cornerRadius = 8
        b.titleLabel?.font = .systemFont(ofSize: 13)
        b.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(b)
    }

    // MARK: - 连接回调
    private func bindConnection() {
        ConnectionManager.shared.onStateChanged = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .connected: return  // 等 WELCOME 显示机器名
            case .connecting:
                self.setStatus("连接中…", color: .systemYellow, bg: UIColor(white: 0.2, alpha: 1))
            case .disconnected:
                self.setStatus("已断开，自动重连中…", color: .systemRed, bg: UIColor(white: 0.2, alpha: 1))
            }
        }
        ConnectionManager.shared.onWelcome = { [weak self] machine in
            self?.setStatus("已连接：\(machine)", color: .systemGreen, bg: UIColor(white: 0.2, alpha: 1))
        }
        ConnectionManager.shared.onAck = { [weak self] msgId, code, ok, reason in
            self?.handleAck(msgId: msgId, code: code, ok: ok, reason: reason)
        }
        ConnectionManager.shared.connect()
    }

    private func setStatus(_ text: String, color: UIColor, bg: UIColor) {
        statusLabel.text = text
        statusLabel.textColor = color
        statusLabel.backgroundColor = bg
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
            output.metadataObjectTypes = output.availableMetadataObjectTypes  // 全码制
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.previewView.bounds
                self.previewView.insertSublayer(layer, at: 0)
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

    // MARK: - 扫码动作
    @objc private func scanTapped() {
        guard cameraAuthorized else { return setupCamera() }
        if armed {
            // 识别中再点=取消
            disarm(timeout: false)
            return
        }
        armed = true
        scanBtn.setTitle("识别中…（点击取消）", for: .normal)
        scanBtn.backgroundColor = UIColor(white: 0.35, alpha: 1)
        let work = DispatchWorkItem { [weak self] in
            self?.disarm(timeout: true)
        }
        manualTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func disarm(timeout: Bool) {
        armed = false
        manualTimeout?.cancel()
        manualTimeout = nil
        applyModeUI()
        if timeout { flash(text: "未识别", symbol: false) }
    }

    @objc private func modeTapped() {
        Prefs.shared.autoMode.toggle()
        applyModeUI()
    }

    private func applyModeUI() {
        let auto = Prefs.shared.autoMode
        modeBtn.setTitle(auto ? "模式:自动" : "模式:手动", for: .normal)
        scanBtn.isHidden = auto
        if !auto {
            scanBtn.setTitle("扫 描", for: .normal)
            scanBtn.backgroundColor = UIColor(red: 0.18, green: 0.64, blue: 0.33, alpha: 1)
        }
        armed = false
    }

    @objc private func pairTapped() {
        let nav = UINavigationController(rootViewController: PairingViewController())
        present(nav, animated: true)
    }

    // MARK: - 发送与 ACK
    private func sendCode(_ code: String, type: String) {
        let msgId = ConnectionManager.shared.sendScan(code, type: type)
        records.insert(ScanRecord(msgId: msgId, code: code, type: type, ok: nil,
                                  time: Date()), at: 0)
        reindex()
        tableView.reloadData()
        refreshStats()
    }

    private func handleAck(msgId: String, code: String, ok: Bool, reason: String) {
        // 找对应记录（按 msgId；超时后迟到的成功回执会把失败覆盖修正为成功）
        if let idx = recordIndex[msgId] {
            records[idx].ok = ok
            tableView.reloadRows(at: [IndexPath(row: idx, section: 0)], with: .none)
        }
        if ok {
            Beep.ok()
            flash(text: "✓", symbol: true)
        } else {
            Beep.fail()
            flash(text: "✗ \(reason)", symbol: false)
        }
        refreshStats()
    }

    // MARK: - 统计与历史
    private func refreshStats() {
        let total = records.count
        let ok = records.filter { $0.ok == true }.count
        let fail = records.filter { $0.ok == false }.count
        let pending = records.filter { $0.ok == nil }.count
        statsLabel.text = "本次：\(total) ｜ 成功 \(ok) ｜ 失败 \(fail) ｜ 待确认 \(pending)"
        historyTitle.text = records.isEmpty ? "扫码历史" :
            (Prefs.shared.resendEnabled ? "扫码历史（点击重发）" : "扫码历史")
    }

    private func reindex() {
        recordIndex.removeAll()
        for (i, r) in records.enumerated() { recordIndex[r.msgId] = i }
    }

    @objc private func clearTapped() {
        records.removeAll()
        recordIndex.removeAll()
        tableView.reloadData()
        refreshStats()
    }

    @objc private func resendChanged() {
        Prefs.shared.resendEnabled = resendSwitch.isOn
        refreshStats()
    }

    @objc private func manualTapped() {
        guard let v = manualField.text, !v.isEmpty else { return }
        manualField.text = nil
        manualField.resignFirstResponder()
        sendCode(v, type: "手动输入")
    }

    // MARK: - 反馈闪烁
    private func flash(text: String, symbol: Bool) {
        flashLabel.text = text
        flashLabel.textColor = symbol ? .systemGreen : .systemRed
        flashView.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.flashView.isHidden = true
        }
    }
}

// MARK: - 相机识别回调
extension ScanViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue else { return }

        let auto = Prefs.shared.autoMode
        if !auto && !armed { return }          // 手动模式：仅按钮按下后识别

        // 自动模式同码冷却 2 秒
        if auto {
            if value == lastCode, Date().timeIntervalSince(lastCodeAt) < 2.0 { return }
            lastCode = value
            lastCodeAt = Date()
        } else {
            disarm(timeout: false)             // 手动模式识别到即结束本次
        }

        let type = codeTypeName(obj.type.rawValue)
        sendCode(value, type: type)
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
        case "com.intermec.Codabar": return "Codabar"
        case "org.iso.PDF417": return "PDF417"
        case "org.iso.Aztec": return "Aztec"
        case "org.iso.DataMatrix": return "DataMatrix"
        default: return "条码"
        }
    }
}

// MARK: - 历史列表
extension ScanViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // subtitle 样式（显示 码内容 + 状态两行）
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        let r = records[indexPath.row]
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let status = r.ok == nil ? "…待确认" : (r.ok! ? "✓成功" : "✗失败")
        cell.textLabel?.text = "\(df.string(from: r.time))  \(r.code)"
        cell.textLabel?.font = .systemFont(ofSize: 13)
        cell.textLabel?.textColor = r.ok == false ? .systemRed : .white
        cell.detailTextLabel?.text = "\(r.type) · \(status)"
        cell.detailTextLabel?.font = .systemFont(ofSize: 11)
        cell.detailTextLabel?.textColor = .lightGray
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard Prefs.shared.resendEnabled else { return }
        let r = records[indexPath.row]
        sendCode(r.code, type: r.type)
    }
}
