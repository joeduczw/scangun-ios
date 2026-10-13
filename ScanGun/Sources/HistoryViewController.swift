import UIKit

/// 扫描历史页（复刻安卓版）：全屏显示扫码记录（时间 + 状态 + 内容）
/// - 打开期间每 500ms 自动刷新（后台扫码/ACK 回调也能实时看到）
/// - 「清空」只清历史记录，不影响主界面统计计数（主界面「清零」= 计数+历史一起清）
class HistoryViewController: UIViewController {

    private let tableView = UITableView()
    private var refreshTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0x121212)
        buildUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startRefresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func buildUI() {
        let safe = view.safeAreaLayoutGuide

        // 标题行：扫描历史 | 清空 | 关闭
        let titleRow = UIStackView()
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .center
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleRow)
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            titleRow.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            titleRow.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            titleRow.heightAnchor.constraint(equalToConstant: 40)
        ])
        let title = UILabel()
        title.text = "扫描历史"
        title.font = .boldSystemFont(ofSize: 17)
        title.textColor = .white
        titleRow.addArrangedSubview(title)
        let spacer = UIView()
        titleRow.addArrangedSubview(spacer)

        let clearBtn = UIButton(type: .system)
        clearBtn.setTitle("清空", for: .normal)
        clearBtn.setTitleColor(.white, for: .normal)
        clearBtn.backgroundColor = UIColor(hex: 0x2A2A2A)
        clearBtn.layer.cornerRadius = 8
        clearBtn.titleLabel?.font = .systemFont(ofSize: 13)
        clearBtn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        clearBtn.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        titleRow.addArrangedSubview(clearBtn)

        let closeBtn = UIButton(type: .system)
        closeBtn.setTitle("关闭", for: .normal)
        closeBtn.setTitleColor(.white, for: .normal)
        closeBtn.backgroundColor = UIColor(hex: 0x2A2A2A)
        closeBtn.layer.cornerRadius = 8
        closeBtn.titleLabel?.font = .systemFont(ofSize: 13)
        closeBtn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        titleRow.addArrangedSubview(closeBtn)

        // 记录列表
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 0.25, alpha: 1)
        tableView.rowHeight = 46
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func startRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tableView.reloadData()
        }
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func clearTapped() {
        if HistoryStore.shared.snapshot().isEmpty {
            CenterToast.show("历史为空")
            return
        }
        let a = UIAlertController(title: "清空扫描历史",
                                  message: "确定清空全部历史记录？（不影响统计计数）",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "清空", style: .destructive) { _ in
            HistoryStore.shared.clear()
            self.tableView.reloadData()
            CenterToast.show("历史已清空")
        })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(a, animated: true)
    }
}

extension HistoryViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        HistoryStore.shared.snapshot().count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "histCell")
            ?? UITableViewCell(style: .default, reuseIdentifier: "histCell")
        let items = HistoryStore.shared.snapshot()
        guard indexPath.row < items.count else { return cell }
        let it = items[indexPath.row]
        let text: String, color: UIColor
        switch it.status {
        case .ok:
            text = "\(it.time)  √  \(it.content)"
            color = UIColor(hex: 0xA5D6A7)
        case .fail:
            text = "\(it.time)  ×  \(it.content)\(it.reason.isEmpty ? "" : "（\(it.reason)）")"
            color = UIColor(hex: 0xFF8A80)
        case .stored:
            text = "\(it.time)  已存  \(it.content)"
            color = UIColor(hex: 0xA5D6A7)
        default:
            text = "\(it.time)  …  \(it.content)"
            color = UIColor(hex: 0xB0BEC5)
        }
        cell.textLabel?.text = text
        cell.textLabel?.textColor = color
        cell.textLabel?.font = .systemFont(ofSize: 13)
        cell.textLabel?.adjustsFontSizeToFitWidth = true
        cell.textLabel?.minimumScaleFactor = 0.55
        cell.backgroundColor = UIColor(hex: 0x2A2A2A)
        cell.selectionStyle = .none
        return cell
    }
}
