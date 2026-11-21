import UIKit

/// 生成单据表头选择页（对齐安卓 onGenerateBill 表头对话框）：
/// - 标题：生成单据（勾选 N 个文件，合并为一张单据）+ 红色「商品数量共 N 件」（数字加粗且大一号）
/// - 日期（默认今天）/ 单据类型 / 发出仓/店 / 入货仓/店（盘点单时隐藏，发出标签变「盘点仓库」）
/// - 选项框选好后绿色加粗；未选灰色「-- 请选择 --」；未选类型时仓店置灰不可点
/// - 每次打开清空重选；单一选项（如普通部门锁定的本店）直接锁定显示
/// - 点「生成」先弹「请核对数量共 N 件」确认框（数字红色加粗大字号，其余正常色），确定才真正生成
class BillHeaderViewController: UIViewController {

    /// 确定（确认核对后）回调：(业务日期, 单据类型, 发出仓/店代码, 入货仓/店代码, 单据备注)
    var onConfirm: ((String, String, String, String, String) -> Void)?

    private let files: [ScanStorage.StoredFile]
    private let whs: [BillApi.Opt]
    private let shops: [BillApi.Opt]
    private let role: String
    private let totalCount: Int

    // 当前选择状态（每次打开均清空重选；日期默认今天）
    private var selType: String?
    private var selWh: BillApi.Opt?
    private var selShop: BillApi.Opt?
    private var bizDate = Date()

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // UI（viewDidLoad 中 makeBox 重建后使用）
    private var typeBox = UIButton(type: .system)
    private var whLabel = UILabel()
    private var whBox = UIButton(type: .system)
    private let shopField = UIStackView()
    private var shopBox = UIButton(type: .system)
    private var remarkField = UITextField()
    private var dateBox = UIButton(type: .system)
    private let datePicker = UIDatePicker()
    private let scrollView = UIScrollView()

    init(files: [ScanStorage.StoredFile], whs: [BillApi.Opt], shops: [BillApi.Opt]) {
        self.files = files
        self.whs = whs
        self.shops = shops
        self.role = Prefs.shared.deptRole
        // 统计勾选文件总件数（每行一件=扫码次数，条码段非空才算；与生成流程同口径）
        var count = 0
        for f in files {
            let lines = ((try? String(contentsOf: f.url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            for line in lines {
                let bc = line.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespaces) ?? ""
                if !bc.isEmpty { count += 1 }
            }
        }
        self.totalCount = count
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

        // ---- 标题：原文 + 红色「商品数量共 N 件」（仅数字加粗且大一号，其余文字只红不加粗） ----
        let title = UILabel()
        title.numberOfLines = 0
        title.textAlignment = .center
        let t = NSMutableAttributedString(string: "生成单据（勾选 \(files.count) 个文件，合并为一张单据）",
                                          attributes: [.font: UIFont.boldSystemFont(ofSize: 17),
                                                       .foregroundColor: UIColor.white])
        let red = UIColor(red: 0.776, green: 0.157, blue: 0.157, alpha: 1)   // #C62828
        t.append(NSMutableAttributedString(string: "\n商品数量共 ", attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: red]))
        t.append(NSMutableAttributedString(string: String(totalCount), attributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: red]))
        t.append(NSMutableAttributedString(string: " 件", attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: red]))
        title.attributedText = t

        // ---- 表单区 ----
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 8

        func addLabel(_ text: String) -> UILabel {
            let l = UILabel()
            l.text = text
            l.font = .systemFont(ofSize: 13)
            l.textColor = UIColor(white: 0.66, alpha: 1)
            box.addArrangedSubview(l)
            return l
        }
        /// 选项框（与安卓 picker_border 同款方框）：未选灰字「-- 请选择 --」，选好绿字加粗
        func makeBox() -> UIButton {
            let b = UIButton(type: .system)
            b.contentHorizontalAlignment = .left
            b.contentEdgeInsets = UIEdgeInsets(top: 13, left: 12, bottom: 13, right: 12)
            b.titleLabel?.font = .systemFont(ofSize: 15)
            b.backgroundColor = UIColor(white: 0.17, alpha: 1)
            b.layer.cornerRadius = 6
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor(white: 0.4, alpha: 1).cgColor
            b.heightAnchor.constraint(equalToConstant: 46).isActive = true
            setBoxValue(b, nil)
            return b
        }

        // 日期：默认今天（已带值，与选好的选项一致绿色加粗），点击展开日历选择
        addLabel("日期")
        dateBox = makeBox()
        setBoxValue(dateBox, dateFmt.string(from: bizDate), green: true)
        dateBox.addTarget(self, action: #selector(dateTapped), for: .touchUpInside)
        box.addArrangedSubview(dateBox)
        datePicker.datePickerMode = .date
        datePicker.date = bizDate
        if #available(iOS 13.4, *) { datePicker.preferredDatePickerStyle = .wheels }
        datePicker.backgroundColor = UIColor(white: 0.15, alpha: 1)
        datePicker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
        datePicker.isHidden = true
        datePicker.heightAnchor.constraint(equalToConstant: 120).isActive = true
        box.addArrangedSubview(datePicker)

        addLabel("单据类型")
        typeBox = makeBox()
        typeBox.addTarget(self, action: #selector(typeTapped), for: .touchUpInside)
        box.addArrangedSubview(typeBox)

        whLabel = addLabel("发出仓/店")
        whBox = makeBox()
        whBox.addTarget(self, action: #selector(whTapped), for: .touchUpInside)
        box.addArrangedSubview(whBox)

        // 入货区（盘点单隐藏）
        let shopLabel = UILabel()
        shopLabel.text = "入货仓/店"
        shopLabel.font = .systemFont(ofSize: 13)
        shopLabel.textColor = UIColor(white: 0.66, alpha: 1)
        shopField.axis = .vertical
        shopField.spacing = 8
        shopField.addArrangedSubview(shopLabel)
        shopBox = makeBox()
        shopBox.addTarget(self, action: #selector(shopTapped), for: .touchUpInside)
        shopField.addArrangedSubview(shopBox)
        box.addArrangedSubview(shopField)

        // 单据备注（对齐安卓 v29）：入货仓/店下方，可留空，50 字内；生成后括号显示在单据号后
        let remarkLabel = UILabel()
        remarkLabel.text = "单据备注"
        remarkLabel.font = .systemFont(ofSize: 13)
        remarkLabel.textColor = UIColor(white: 0.66, alpha: 1)
        box.addArrangedSubview(remarkLabel)
        remarkField.placeholder = "可留空；生成后显示在单据号后"
        remarkField.font = .systemFont(ofSize: 15)
        remarkField.textColor = .white
        remarkField.backgroundColor = UIColor(white: 0.17, alpha: 1)
        remarkField.layer.cornerRadius = 6
        remarkField.layer.borderWidth = 1
        remarkField.layer.borderColor = UIColor(white: 0.4, alpha: 1).cgColor
        remarkField.heightAnchor.constraint(equalToConstant: 46).isActive = true
        let pad = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 46))
        remarkField.leftView = pad
        remarkField.leftViewMode = .always
        remarkField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 46))
        remarkField.rightViewMode = .always
        remarkField.autocorrectionType = .no
        remarkField.autocapitalizationType = .none
        remarkField.delegate = self
        box.addArrangedSubview(remarkField)

        // ---- 整体布局：标题 + 可滚动表单 + 底部按钮 ----
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            root.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 20),
            root.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -20),
            root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        root.addArrangedSubview(title)

        scrollView.alwaysBounceVertical = true
        box.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            box.leftAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leftAnchor),
            box.rightAnchor.constraint(equalTo: scrollView.contentLayoutGuide.rightAnchor),
            box.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            box.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
        root.addArrangedSubview(scrollView)

        let btnRow = UIStackView()
        btnRow.axis = .horizontal
        btnRow.spacing = 12
        btnRow.distribution = .fillEqually
        btnRow.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let cancelBtn = UIButton(type: .system)
        cancelBtn.setTitle("取消", for: .normal)
        cancelBtn.titleLabel?.font = .boldSystemFont(ofSize: 17)
        cancelBtn.backgroundColor = UIColor(white: 0.25, alpha: 1)
        cancelBtn.setTitleColor(.white, for: .normal)
        cancelBtn.layer.cornerRadius = 10
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        btnRow.addArrangedSubview(cancelBtn)
        let okBtn = UIButton(type: .system)
        okBtn.setTitle("生成", for: .normal)
        okBtn.titleLabel?.font = .boldSystemFont(ofSize: 17)
        okBtn.backgroundColor = UIColor(red: 0.13, green: 0.45, blue: 0.18, alpha: 1)
        okBtn.setTitleColor(.white, for: .normal)
        okBtn.layer.cornerRadius = 10
        okBtn.addTarget(self, action: #selector(okTapped), for: .touchUpInside)
        btnRow.addArrangedSubview(okBtn)
        root.addArrangedSubview(btnRow)

        refreshHead()
    }

    // MARK: - 选项逻辑（网页 whShopOpts 同款）

    /// 单据类型按角色：普通=配货+移仓+盘点；办公室=退货+盘点；管理员=全部
    private var types: [String] {
        switch role {
        case "normal": return ["商店配货单", "移仓单", "库存盘点单"]
        case "office": return ["商店退货单", "库存盘点单"]
        default: return ["商店配货单", "商店退货单", "移仓单", "库存盘点单"]
        }
    }

    /// 按类型+角色返回 (发出选项, 入货选项)
    private func pair(_ type: String) -> ([BillApi.Opt], [BillApi.Opt]) {
        let all = whs + shops
        let mine = shops.first { $0.code == Prefs.shared.deptBianhao }
            ?? BillApi.Opt(code: Prefs.shared.deptBianhao, name: Prefs.shared.deptName)
        if type == "库存盘点单" {
            // 盘点单：仅日期+盘点仓库；普通部门锁定本部门仓库，其余任选
            return (role == "normal" ? [mine] : all, [])
        }
        if role == "normal" {
            if type == "商店配货单" { return (whs, [mine]) }   // 发出=总部仓库，入货=本店
            return (shops.filter { $0.code != Prefs.shared.deptBianhao }, [mine])   // 移仓：发出=其他商店
        }
        if role == "office" { return (shops, whs) }            // 退货单：发出=商店，入货=总部仓
        switch type {
        case "商店配货单": return (whs, shops)
        case "商店退货单": return (shops, whs)
        default: return (whs, whs)                             // 移仓
        }
    }

    /// 选项框赋值：有值绿色加粗，无值灰色「-- 请选择 --」
    private func setBoxValue(_ b: UIButton, _ text: String?, green: Bool = false) {
        b.setTitle(text ?? "-- 请选择 --", for: .normal)
        if text != nil {
            b.setTitleColor(UIColor(red: 0.18, green: 0.49, blue: 0.20, alpha: 1), for: .normal)
            b.titleLabel?.font = .boldSystemFont(ofSize: 15)
        } else {
            b.setTitleColor(UIColor(white: 0.6, alpha: 1), for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15)
        }
    }

    /// 类型切换后重填仓店：多选项清空待选；唯一选项（普通部门锁定本店）直接锁定显示
    private func applyList(_ box: UIButton, _ list: [BillApi.Opt], setter: (BillApi.Opt?) -> Void) {
        if list.count == 1 {
            setter(list[0])
            setBoxValue(box, list[0].name)
            box.isEnabled = false
            box.alpha = 1
        } else {
            setter(nil)
            setBoxValue(box, nil)
            box.isEnabled = true
            box.alpha = 1
        }
    }

    private func refreshHead() {
        guard let type = selType else {
            // 未选类型：仓店不可用（置灰），先选类型
            whLabel.text = "发出仓/店"
            shopField.isHidden = false
            for b in [whBox, shopBox] { b.isEnabled = false; b.alpha = 0.45; setBoxValue(b, nil) }
            return
        }
        let p = pair(type)
        if type == "库存盘点单" {
            whLabel.text = "盘点仓库"
            shopField.isHidden = true
        } else {
            whLabel.text = "发出仓/店"
            shopField.isHidden = false
        }
        applyList(whBox, p.0) { selWh = $0 }
        applyList(shopBox, p.1) { selShop = $0 }
    }

    // MARK: - 交互

    @objc private func dateTapped() { datePicker.isHidden.toggle() }

    @objc private func dateChanged() {
        bizDate = datePicker.date
        setBoxValue(dateBox, dateFmt.string(from: bizDate), green: true)
    }

    /// 单选列表（带 ✓ 当前项）；iPad 需锚点
    private func pickOpt(title: String, list: [BillApi.Opt], cur: BillApi.Opt?, from source: UIButton, onPick: @escaping (BillApi.Opt) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for opt in list {
            let mark = opt.code == cur?.code ? " ✓" : ""
            alert.addAction(UIAlertAction(title: opt.name + mark, style: .default) { _ in onPick(opt) })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.sourceView = source
        alert.popoverPresentationController?.sourceRect = source.bounds
        present(alert, animated: true)
    }

    @objc private func typeTapped() {
        let alert = UIAlertController(title: "选择单据类型", message: nil, preferredStyle: .actionSheet)
        for t in types {
            alert.addAction(UIAlertAction(title: t + (t == selType ? " ✓" : ""), style: .default) { _ in
                self.selType = t
                self.setBoxValue(self.typeBox, t)
                self.selWh = nil
                self.selShop = nil
                self.refreshHead()
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.sourceView = typeBox
        alert.popoverPresentationController?.sourceRect = typeBox.bounds
        present(alert, animated: true)
    }

    @objc private func whTapped() {
        guard let type = selType else { return }
        pickOpt(title: "选择\(whLabel.text ?? "")", list: pair(type).0, cur: selWh, from: whBox) {
            self.selWh = $0
            self.setBoxValue(self.whBox, $0.name)
        }
    }

    @objc private func shopTapped() {
        guard let type = selType else { return }
        pickOpt(title: "选择入货仓/店", list: pair(type).1, cur: selShop, from: shopBox) {
            self.selShop = $0
            self.setBoxValue(self.shopBox, $0.name)
        }
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func okTapped() {
        // 校验不过不关页（已选项保留），红色警示提示
        guard let type = selType else { CenterToast.showWarn("请选择单据类型"); return }
        guard let wh = selWh else { CenterToast.showWarn("请选择\(whLabel.text ?? "仓库")"); return }
        if type != "库存盘点单" && selShop == nil { CenterToast.showWarn("请选择入货仓/店"); return }

        // 确认框：请核对数量共 N 件（数字红色加粗大字号，其余正常色）
        let red = UIColor(red: 0.776, green: 0.157, blue: 0.157, alpha: 1)
        let msg = NSMutableAttributedString(string: "请核对数量共 ",
                                            attributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
        msg.append(NSMutableAttributedString(string: String(totalCount),
                                             attributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: red]))
        msg.append(NSMutableAttributedString(string: " 件",
                                             attributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black]))
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .alert)
        alert.setValue(NSAttributedString(string: "请核对数量", attributes: [.font: UIFont.boldSystemFont(ofSize: 17)]), forKey: "attributedTitle")
        alert.setValue(msg, forKey: "attributedMessage")
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            let shopCode = type == "库存盘点单" ? "" : (self.selShop?.code ?? "")
            let remark = (self.remarkField.text ?? "").trimmingCharacters(in: .whitespaces)
            self.dismiss(animated: true) {
                self.onConfirm?(self.dateFmt.string(from: self.bizDate), type, wh.code, shopCode, remark)
            }
        })
        present(alert, animated: true)
    }
}

// MARK: - 备注输入限长 50 字（对齐安卓 LengthFilter(50)，中文字符按 1 计）
extension BillHeaderViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        let cur = textField.text ?? ""
        guard let range = Range(range, in: cur) else { return true }
        let next = cur.replacingCharacters(in: range, with: string)
        return next.count <= 50
    }
}
