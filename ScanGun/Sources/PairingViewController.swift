import UIKit

/// 配对页：UDP 自动扫描客户机（点击设备自动填入 IP/端口）+ 历史连接（点击直连/切换）
/// + 手动输入 + 商品验证端口设置 + 保存
/// 键盘收起三保险：键盘工具条「收起键盘」按钮（数字键盘无 return 键）+ 点空白收起
/// + return 键收起；键盘弹出时抬高滚动区底边（保存按钮可滚到键盘上方不被遮挡）
class PairingViewController: UIViewController, UITextFieldDelegate, UIGestureRecognizerDelegate {

    private let hostField = UITextField()
    private let portField = UITextField()
    private let tokenField = UITextField()
    private let nameField = UITextField()
    private let stack = UIStackView()
    private let verifyInnerField = UITextField()
    private let verifyOuterField = UITextField()
    private let scroll = UIScrollView()

    // 自动扫描区
    private let scanState = UILabel()
    private let deviceStack = UIStackView()
    private var devices: [DiscoveryClient.Device] = []
    private var scanToken = 0

    // 历史连接区（连接成功过的客户机，点击直接连接/切换）
    private let histEmpty = UILabel()
    private let histStack = UIStackView()
    private var histItems: [Prefs.PairHistItem] = []
    private let histFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.96, alpha: 1)

        // 整页可滚动（发现列表 + 输入区在小屏上可能超出一屏）
        let scroll = self.scroll
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // 点击输入框以外的空白区域收起键盘（点在输入框/按钮上不拦截，见手势代理）
        let tap = UITapGestureRecognizer(target: self, action: #selector(hideKeyboard))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
        // 键盘弹出/收起时调整滚动区底边（「保存并连接」可滚到键盘上方）
        NotificationCenter.default.addObserver(self, selector: #selector(kbWillShow(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(kbWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)

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

        // ---- 历史连接区（连接成功过的客户机，点击直接连接/切换当前连接） ----
        let histTitle = UILabel()
        histTitle.text = "历史连接"
        histTitle.font = .boldSystemFont(ofSize: 17)
        histTitle.textAlignment = .center
        stack.addArrangedSubview(histTitle)

        histEmpty.text = "暂无连接记录（连接成功后自动保存）"
        histEmpty.font = .systemFont(ofSize: 13)
        histEmpty.textColor = .gray
        histEmpty.textAlignment = .center
        stack.addArrangedSubview(histEmpty)

        histStack.axis = .vertical
        histStack.spacing = 8
        stack.addArrangedSubview(histStack)

        // ---- 手动输入区 ----
        let title = UILabel()
        title.text = "客户机信息（在客户机主界面查看）"
        title.font = .boldSystemFont(ofSize: 17)
        title.textAlignment = .center
        stack.addArrangedSubview(title)

        addField(hostField, placeholder: "客户机 IP（如 192.168.1.100）", keyboard: .numbersAndPunctuation)
        addField(portField, placeholder: "端口（默认 8899）", keyboard: .numberPad)
        addField(tokenField, placeholder: "6位配对码（客户机主界面显示）", keyboard: .numberPad)
        addField(nameField, placeholder: "设备名称（接收器「已连接设备」中显示，默认自动生成）", keyboard: .default)

        // 回填已保存的值（换客户机/重置配对码时方便修改）
        if !Prefs.shared.host.isEmpty { hostField.text = Prefs.shared.host }
        if !Prefs.shared.token.isEmpty { tokenField.text = Prefs.shared.token }
        portField.text = String(Prefs.shared.port)
        // 设备名称：预填当前名（首次访问自动生成 机型-随机后缀），可改成如「仓库1-张三的手机」
        nameField.text = Prefs.shared.deviceName

        // 商品验证端口：一行「商品验证端口：内部[输入] 外部[输入]」，验证时内外地址自动切换
        let portRow = UIStackView()
        portRow.axis = .horizontal
        portRow.spacing = 6
        portRow.alignment = .center
        stack.addArrangedSubview(portRow)
        let innerLbl = UILabel()
        innerLbl.text = "商品验证端口：内部"
        innerLbl.font = .systemFont(ofSize: 14)
        innerLbl.textColor = .darkGray
        innerLbl.setContentCompressionResistancePriority(.required, for: .horizontal)
        portRow.addArrangedSubview(innerLbl)
        portRow.addArrangedSubview(verifyInnerField)
        let outerLbl = UILabel()
        outerLbl.text = "外部"
        outerLbl.font = .systemFont(ofSize: 14)
        outerLbl.textColor = .darkGray
        outerLbl.setContentCompressionResistancePriority(.required, for: .horizontal)
        portRow.addArrangedSubview(outerLbl)
        portRow.addArrangedSubview(verifyOuterField)
        for (f, def) in [(verifyInnerField, 171), (verifyOuterField, 172)] {
            f.placeholder = String(def)
            f.borderStyle = .roundedRect
            f.keyboardType = .numberPad
            f.font = .systemFont(ofSize: 15)
            f.textAlignment = .center
            f.widthAnchor.constraint(equalToConstant: 76).isActive = true
            f.heightAnchor.constraint(equalToConstant: 44).isActive = true
            f.returnKeyType = .done
            f.delegate = self
            f.inputAccessoryView = makeKeyboardToolbar()
        }
        verifyInnerField.text = String(Prefs.shared.verifyInnerPort)
        verifyOuterField.text = String(Prefs.shared.verifyOuterPort)

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

        // 版本号小字（来自 project.yml 的 MARKETING_VERSION，发版只改配置）
        let verLabel = UILabel()
        verLabel.font = .systemFont(ofSize: 12)
        verLabel.textColor = .gray
        verLabel.textAlignment = .center
        verLabel.text = "APP 版本：" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
        stack.addArrangedSubview(verLabel)

        renderHistory()
        startScan()
    }

    // MARK: - 历史连接

    /// 渲染历史连接列表（当前连接的客户机行尾标「当前」）
    private func renderHistory() {
        histStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = Prefs.shared.pairHistory
        histItems = items
        histEmpty.isHidden = !items.isEmpty
        for (i, item) in items.enumerated() {
            let current = item.host == Prefs.shared.host
                && item.port == Prefs.shared.port && item.token == Prefs.shared.token
            let b = UIButton(type: .system)
            b.tag = i
            b.setTitle("\(item.name)\(current ? "（当前）" : "")\n\(item.host):\(item.port) · \(histFmt.string(from: item.lastTime))", for: .normal)
            b.setTitleColor(.black, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            b.titleLabel?.numberOfLines = 2
            b.titleLabel?.textAlignment = .center
            b.backgroundColor = .white
            b.layer.cornerRadius = 8
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
            b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            b.heightAnchor.constraint(equalToConstant: 58).isActive = true
            b.addTarget(self, action: #selector(histTapped(_:)), for: .touchUpInside)
            histStack.addArrangedSubview(b)
        }
    }

    /// 点击历史行：用该客户机的地址/配对码直接连接（已连其他机器则切换）
    @objc private func histTapped(_ sender: UIButton) {
        guard histItems.indices.contains(sender.tag) else { return }
        let it = histItems[sender.tag]
        Prefs.shared.host = it.host
        Prefs.shared.port = it.port
        Prefs.shared.token = it.token
        CenterToast.show("正在连接「\(it.name)」…")
        ConnectionManager.shared.reconnectWithNewPrefs()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.view.window?.rootViewController = ScanViewController()
        }
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

    // MARK: - 键盘收起（三保险：工具条按钮 / 点空白 / return 键）

    /// 键盘上方通用工具条：右侧「收起键盘」按钮。
    /// 数字键盘（端口/配对码/验证端口）没有 return 键，iOS 系统不提供收起按钮，统一靠此工具条
    private func makeKeyboardToolbar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
        bar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "收起键盘", style: .done, target: self, action: #selector(hideKeyboard))
        ]
        bar.sizeToFit()
        return bar
    }

    /// 收起键盘（工具条按钮 / 点空白 / return 键共用）
    @objc private func hideKeyboard() { view.endEditing(true) }

    /// return 键直接收起（IP/设备名称等带 return 键的键盘）
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    /// 点在输入框/按钮上时 tap 手势不处理（输入框正常切换焦点、按钮正常响应点击）
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UITextField) && !(touch.view is UIControl)
    }

    /// 键盘弹出：抬高滚动区底边，「保存并连接」可滚到键盘上方
    @objc private func kbWillShow(_ n: Notification) {
        guard let frame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let inset = frame.height - view.safeAreaInsets.bottom
        scroll.contentInset.bottom = inset
        scroll.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
    }

    /// 键盘收起：恢复滚动区底边
    @objc private func kbWillHide(_ n: Notification) {
        scroll.contentInset.bottom = 0
        scroll.scrollIndicatorInsets = .zero
    }

    // MARK: - 手动输入

    private func addField(_ f: UITextField, placeholder: String, keyboard: UIKeyboardType) {
        f.placeholder = placeholder
        f.borderStyle = .roundedRect
        f.keyboardType = keyboard
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.font = .systemFont(ofSize: 16)
        f.heightAnchor.constraint(equalToConstant: 46).isActive = true
        f.returnKeyType = .done
        f.delegate = self
        f.inputAccessoryView = makeKeyboardToolbar()
        stack.addArrangedSubview(f)
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
        // 设备名称：留空保持原名，限 20 字；重连即以新名字发 HELLO
        let devName = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
        if !devName.isEmpty { Prefs.shared.deviceName = String(devName.prefix(20)) }
        // 商品验证端口：留空/非法回退默认值（内部171/外部172）
        let innerPort = Int((verifyInnerField.text ?? "").trimmingCharacters(in: .whitespaces)) ?? 171
        let outerPort = Int((verifyOuterField.text ?? "").trimmingCharacters(in: .whitespaces)) ?? 172
        Prefs.shared.verifyInnerPort = (1...65535).contains(innerPort) ? innerPort : 171
        Prefs.shared.verifyOuterPort = (1...65535).contains(outerPort) ? outerPort : 172

        CenterToast.show("已保存，正在连接…")

        // 通知主界面切换为扫描页（与旧逻辑一致）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.view.window?.rootViewController = ScanViewController()
        }
    }
}
