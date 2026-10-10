import UIKit

/// 配对页：输入客户机 IP / 端口 / 配对码
class PairingViewController: UIViewController {
    private let hostField = UITextField()
    private let portField = UITextField()
    private let tokenField = UITextField()
    private var stack: UIStackView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.96, alpha: 1)

        stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        let title = UILabel()
        title.text = "客户机信息（在客户机主界面查看）"
        title.font = .boldSystemFont(ofSize: 17)
        title.textAlignment = .center
        stack.addArrangedSubview(title)

        addField(hostField, placeholder: "客户机 IP（如 192.168.1.100）",
                 keyboard: .numbersAndPunctuation)
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
        tip.text = "说明：IP 和配对码在客户机程序主界面顶部；手机与客户机需在同一 WiFi。"
        stack.addArrangedSubview(tip)
    }

    private func addField(_ f: UITextField, placeholder: String, keyboard: UIKeyboardType) {
        f.placeholder = placeholder
        f.borderStyle = .roundedRect
        f.keyboardType = keyboard
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.font = .systemFont(ofSize: 16)
        f.heightAnchor.constraint(equalToConstant: 46).isActive = true
        stack.addArrangedSubview(f)
    }

    @objc private func saveTapped() {
        let host = hostField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        let token = tokenField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        var port = Int(portField.text?.trimmingCharacters(in: .whitespaces) ?? "") ?? 8899
        if port <= 0 || port > 65535 { port = 8899 }

        guard !host.isEmpty else { return alert("请输入客户机 IP") }
        guard !token.isEmpty else { return alert("请输入配对码") }

        Prefs.shared.host = host
        Prefs.shared.port = port
        Prefs.shared.token = token

        ConnectionManager.shared.reconnectWithNewPrefs()
        view.window?.rootViewController = ScanViewController()
    }

    private func alert(_ msg: String) {
        let a = UIAlertController(title: msg, message: nil, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }
}
