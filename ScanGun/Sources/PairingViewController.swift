import UIKit

/// 配对页：UDP 自动扫描客户机（点击设备自动填入 IP/端口）+ 手动输入 + 保存
class PairingViewController: UIViewController {

    private let hostField = UITextField()
    private let portField = UITextField()
    private let tokenField = UITextField()
    private let stack = UIStackView()

    // 自动扫描区
    private let scanState = UILabel()
    private let deviceStack = UIStackView()
    private var devices: [DiscoveryClient.Device] = []
    private var scanToken = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.96, alpha: 1)

        // 整页可滚动（发现列表 + 输入区在小屏上可能超出一屏）
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let stack = self.stack
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])

        // ---- 自动扫描区 ----
        let scanTitle = UILabel()
        scanTitle.text = "自动扫描客户机"
        scanTitle.font = .boldSystemFont(ofSize: 17)
        scanTitle.textAlignment = .center
        stack.addArrangedSubview(scanTitle)

        scanState.text = "正在扫描局域网…"
        scanState.font = .systemFont(ofSize: 13)
        scanState.textColor = .gray
        scanState.textAlignment = .center
        scanState.numberOfLines = 0
        stack.addArrangedSubview(scanState)

        deviceStack.axis = .vertical
        deviceStack.spacing = 8
        stack.addArrangedSubview(deviceStack)

        let rescanBtn = UIButton(type: .system)
        rescanBtn.setTitle("重新扫描", for: .normal)
        rescanBtn.setTitleColor(UIColor(red: 0.18, green: 0.44, blue: 0.82, alpha: 1), for: .normal)
        rescanBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        rescanBtn.addTarget(self, action: #selector(rescanTapped), for: .touchUpInside)
        stack.addArrangedSubview(rescanBtn)

        // ---- 手动输入区 ----
        let title = UILabel()
        title.text = "客户机信息（在客户机主界面查看）"
        title.font = .boldSystemFont(ofSize: 17)
        title.textAlignment = .center
        stack.addArrangedSubview(title)

        addField(hostField, placeholder: "客户机 IP（如 192.168.1.100）", keyboard: .numbersAndPunctuation)
        addField(portField, placeholder: "端口（默认 8899）", keyboard: .numberPad)
        addField(tokenField, placeholder: "6位配对码（客户机主界面显示）", keyboard: .numberPad)

        // 回填已保存的值（换客户机/重置配对码时方便修改）
        if !Prefs.shared.host.isEmpty { hostField.text = Prefs.shared.host }
        if !Prefs.shared.token.isEmpty { tokenField.text = Prefs.shared.token }
        portField.text = String(Prefs.shared.port)

        let saveBtn = UIButton(type: .system)
        saveBtn.setTitle("保存并连接", for: .normal)
        saveBtn.titleLabel?.font = .boldSystemFont(ofSize: 17)
        saveBtn.backgroundColor = UIColor(red: 0.18, green: 0.44, blue: 0.82, alpha: 1)
        saveBtn.setTitleColor(.white, for: .normal)
        saveBtn.layer.cornerRadius = 10
        saveBtn.heightAnchor.constraint(equalToConstant: 50).isActive = true
        saveBtn.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        stack.addArrangedSubview(saveBtn)

        let tip = UILabel()
        tip.numberOfLines = 0
        tip.font = .systemFont(ofSize: 13)
        tip.textColor = .darkGray
        tip.textAlignment = .center
        tip.text = "说明：手机与客户机需在同一 WiFi；\n客户机显示名称可在其「修改名称」中设置。"
        stack.addArrangedSubview(tip)

        startScan()
    }

    // MARK: - UDP 自动发现

    private func startScan() {
        scanToken += 1
        let token = scanToken
        scanState.text = "正在扫描局域网…"
        scanState.textColor = .gray
        deviceStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        DiscoveryClient.discover { [weak self] list in
            guard let self = self, token == self.scanToken else { return }
            self.renderDevices(list)
        }
    }

    private func renderDevices(_ list: [DiscoveryClient.Device]) {
        devices = list
        deviceStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if list.isEmpty {
            scanState.text = "未扫描到接收端，请手动输入下方信息\n（确认电脑端扫码接收器已运行）"
            scanState.textColor = .darkGray
            return
        }
        scanState.text = "点击设备自动填入 IP 和端口："
        scanState.textColor = UIColor(red: 0.13, green: 0.45, blue: 0.18, alpha: 1)
        for (i, dev) in list.enumerated() {
            let b = UIButton(type: .system)
            b.tag = i
            b.setTitle("\(dev.name)（\(dev.ip):\(dev.port)）", for: .normal)
            b.setTitleColor(.black, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            b.contentHorizontalAlignment = .left
            b.backgroundColor = .white
            b.layer.cornerRadius = 8
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
            b.contentEdgeInsets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
            b.heightAnchor.constraint(equalToConstant: 48).isActive = true
            b.addTarget(self, action: #selector(deviceTapped(_:)), for: .touchUpInside)
            deviceStack.addArrangedSubview(b)
        }
    }

    @objc private func deviceTapped(_ sender: UIButton) {
        guard devices.indices.contains(sender.tag) else { return }
        let dev = devices[sender.tag]
        hostField.text = dev.ip
        portField.text = String(dev.port)
        CenterToast.show("已填入「\(dev.name)」，请输入配对码")
        tokenField.becomeFirstResponder()
    }

    @objc private func rescanTapped() { startScan() }

    // MARK: - 手动输入

    private func addField(_ f: UITextField, placeholder: String, keyboard: UIKeyboardType) {
        f.placeholder = placeholder
        f.borderStyle = .roundedRect
        f.keyboardType = keyboard
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.font = .systemFont(ofSize: 16)
        f.heightAnchor.constraint(equalToConstant: 46).isActive = true
        stack?.addArrangedSubview(f)
    }

    @objc private func saveTapped() {
        let host = (hostField.text ?? "").trimmingCharacters(in: .whitespaces)
        let token = (tokenField.text ?? "").trimmingCharacters(in: .whitespaces)
        let portText = (portField.text ?? "").trimmingCharacters(in: .whitespaces)
        let port = Int(portText) ?? 8899

        if host.isEmpty { CenterToast.show("请输入客户机 IP"); return }
        if token.count != 6 { CenterToast.show("配对码为 6 位数字"); return }

        Prefs.shared.host = host
        Prefs.shared.port = port
        Prefs.shared.token = token

        CenterToast.show("已保存，正在连接…")

        // 通知主界面切换为扫描页（与旧逻辑一致）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.view.window?.rootViewController = ScanViewController()
        }
    }
}
