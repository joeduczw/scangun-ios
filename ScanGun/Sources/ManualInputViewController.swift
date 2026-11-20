import UIKit

/// 手动输入页（对齐安卓 v27）：
/// - 商品代码输入（默认）：代码联想搜索 → 颜色/尺码级联选择 → 数量 N=扫 N 次；
///   发送时服务端按 TM 条码方案构造真实条码（sp_barcode），存储/发送与真实扫码完全一致
/// - 条码输入（老版本逻辑）：输入完整条码直接按扫码同路径处理
/// - 联想防抖 150ms + 响应序号防过期；选项列表在输入框下方展开（当前已选项打勾）
class ManualInputViewController: UIViewController, UITextFieldDelegate,
                                 UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {

    /// 条码输入模式发送（老逻辑：直接按扫码处理）
    var onSendBarcode: ((String) -> Void)?
    /// 商品代码模式发送：构造出的真实条码 + 商品信息三项 + 8 段 SKU（数量为 N 时回调 N 次）
    var onSendSku: ((_ bc: String, _ product: String, _ sku: String) -> Void)?

    // MARK: - UI
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let codeModeBtn = UIButton(type: .system)
    private let bcModeBtn = UIButton(type: .system)
    private let codeField = UITextField()
    private let noMatchLabel = UILabel()
    private let prodLabel = UILabel()
    private let colorBtn = UIButton(type: .system)
    private let sizeBtn = UIButton(type: .system)
    private let qtyField = UITextField()
    private let bcField = UITextField()
    private let sendBtn = UIButton(type: .system)
    private let suggestTable = UITableView()
    private let colorTable = UITableView()
    private let sizeTable = UITableView()
    private var suggestTableH: NSLayoutConstraint?
    private var colorTableH: NSLayoutConstraint?
    private var sizeTableH: NSLayoutConstraint?
    /// 商品代码模式 / 条码输入模式的两组控件（切换显隐）
    private var codeViews: [UIView] = []
    private var bcViews: [UIView] = []
    private var bcMode = false

    // MARK: - 级联状态
    private var loadedSpdm: String?          // 已加载颜色/尺码的商品代码
    private var colors: [BillApi.Opt] = []
    private var sizes: [BillApi.Opt] = []
    private var selColor: BillApi.Opt?
    private var selSize: BillApi.Opt?
    /// 联想：防抖任务 + 响应序号（丢弃过期响应，防旧结果覆盖新输入）
    private var searchWork: DispatchWorkItem?
    private var searchSeq = 0
    /// 上次联想选中的代码：选中后程序赋值不触发搜索（editingChanged 不回调，此值仅供状态判断）
    private var lastPicked: String?

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.96, alpha: 1)

        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // 点击输入框/选项列表以外的空白区域收起键盘与展开的选项列表
        let tap = UITapGestureRecognizer(target: self, action: #selector(hideKeyboard))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
        // 键盘弹出/收起时调整滚动区底边（发送按钮可滚到键盘上方）
        NotificationCenter.default.addObserver(self, selector: #selector(kbWillShow(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(kbWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)

        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])

        buildTitleRow()
        buildCodeModeViews()
        buildBcModeViews()
        buildActionRow()
        applyMode()
    }

    // MARK: - 发送 / 取消
    private func buildActionRow() {
        sendBtn.setTitle("发 送", for: .normal)
        sendBtn.setTitleColor(.white, for: .normal)
        sendBtn.titleLabel?.font = .boldSystemFont(ofSize: 16)
        sendBtn.backgroundColor = UIColor(hex: 0x2E7D32)
        sendBtn.layer.cornerRadius = 8
        sendBtn.heightAnchor.constraint(equalToConstant: 48).isActive = true
        sendBtn.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        stack.addArrangedSubview(sendBtn)

        let cancelBtn = UIButton(type: .system)
        cancelBtn.setTitle("取 消", for: .normal)
        cancelBtn.setTitleColor(UIColor(hex: 0x888888), for: .normal)
        cancelBtn.titleLabel?.font = .systemFont(ofSize: 15)
        cancelBtn.heightAnchor.constraint(equalToConstant: 36).isActive = true
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        stack.addArrangedSubview(cancelBtn)
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    // MARK: - 标题行：手动输入 + 输入模式切换
    private func buildTitleRow() {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center

        let title = UILabel()
        title.text = "手动输入"
        title.font = .boldSystemFont(ofSize: 18)
        row.addArrangedSubview(title)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        func styleModeBtn(_ b: UIButton) {
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            b.layer.cornerRadius = 14
            b.layer.borderWidth = 1.5
            b.contentEdgeInsets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            row.addArrangedSubview(b)
        }
        codeModeBtn.setTitle("商品代码输入", for: .normal)
        codeModeBtn.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        styleModeBtn(codeModeBtn)
        bcModeBtn.setTitle("条码输入", for: .normal)
        bcModeBtn.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        styleModeBtn(bcModeBtn)
        stack.addArrangedSubview(row)
    }

    // MARK: - 商品代码模式控件
    private func buildCodeModeViews() {
        func addLabel(_ text: String) {
            let l = UILabel()
            l.text = text
            l.font = .systemFont(ofSize: 14, weight: .medium)
            l.textColor = UIColor(hex: 0x555555)
            stack.addArrangedSubview(l)
            codeViews.append(l)
        }

        addLabel("商品代码")
        codeField.placeholder = "输入商品代码（支持名称搜索）"
        codeField.borderStyle = .roundedRect
        codeField.autocorrectionType = .no
        codeField.autocapitalizationType = .none
        codeField.font = .systemFont(ofSize: 16)
        codeField.returnKeyType = .done
        codeField.delegate = self
        codeField.inputAccessoryView = makeKeyboardToolbar()
        codeField.addTarget(self, action: #selector(codeChanged), for: .editingChanged)
        stack.addArrangedSubview(codeField)
        codeViews.append(codeField)

        // 联想下拉：输入框下方展开（动态高度，超出内部滚动）
        suggestTable.dataSource = self
        suggestTable.delegate = self
        suggestTable.rowHeight = 40
        suggestTable.layer.cornerRadius = 6
        suggestTable.layer.borderWidth = 1
        suggestTable.layer.borderColor = UIColor(hex: 0x90CAF9).cgColor
        suggestTable.backgroundColor = UIColor(hex: 0xE3F2FD)
        suggestTable.isHidden = true
        suggestTable.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(suggestTable)
        codeViews.append(suggestTable)
        suggestTableH = suggestTable.heightAnchor.constraint(equalToConstant: 0)
        suggestTableH?.isActive = true

        noMatchLabel.text = "未匹配到商品代码"
        noMatchLabel.font = .systemFont(ofSize: 13)
        noMatchLabel.textColor = UIColor(hex: 0xE53935)
        noMatchLabel.isHidden = true
        stack.addArrangedSubview(noMatchLabel)
        codeViews.append(noMatchLabel)

        prodLabel.font = .systemFont(ofSize: 13)
        prodLabel.textColor = UIColor(hex: 0x666666)
        prodLabel.isHidden = true
        stack.addArrangedSubview(prodLabel)
        codeViews.append(prodLabel)

        addLabel("颜色")
        stylePickerBtn(colorBtn)
        colorBtn.addTarget(self, action: #selector(colorTapped), for: .touchUpInside)
        stack.addArrangedSubview(colorBtn)
        codeViews.append(colorBtn)
        codeViews.append(addOptTable(colorTable, heightC: &colorTableH))

        addLabel("尺码")
        stylePickerBtn(sizeBtn)
        sizeBtn.addTarget(self, action: #selector(sizeTapped), for: .touchUpInside)
        stack.addArrangedSubview(sizeBtn)
        codeViews.append(sizeBtn)
        codeViews.append(addOptTable(sizeTable, heightC: &sizeTableH))

        addLabel("数量（发送时按该数量重复扫描）")
        qtyField.placeholder = "数量"
        qtyField.borderStyle = .roundedRect
        qtyField.keyboardType = .numberPad
        qtyField.font = .systemFont(ofSize: 16)
        qtyField.text = "1"
        qtyField.inputAccessoryView = makeKeyboardToolbar()
        qtyField.addTarget(self, action: #selector(qtyChanged), for: .editingChanged)
        stack.addArrangedSubview(qtyField)
        codeViews.append(qtyField)
    }

    /// 颜色/尺码选项列表：选择框下方展开，当前已选项打勾
    private func addOptTable(_ tv: UITableView, heightC: inout NSLayoutConstraint?) -> UIView {
        tv.dataSource = self
        tv.delegate = self
        tv.rowHeight = 40
        tv.layer.cornerRadius = 6
        tv.layer.borderWidth = 1
        tv.layer.borderColor = UIColor(hex: 0x90CAF9).cgColor
        tv.backgroundColor = UIColor(hex: 0xE3F2FD)
        tv.isHidden = true
        tv.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(tv)
        heightC = tv.heightAnchor.constraint(equalToConstant: 0)
        heightC?.isActive = true
        return tv
    }

    /// 颜色/尺码选择框样式：方框 + 左对齐文字；已选绿色加粗、未选灰色提示
    private func stylePickerBtn(_ b: UIButton) {
        b.setTitle("-- 请选择 --", for: .normal)
        b.setTitleColor(UIColor(hex: 0x999999), for: .normal)
        b.contentHorizontalAlignment = .left
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        b.titleLabel?.font = .systemFont(ofSize: 16)
        b.layer.cornerRadius = 6
        b.layer.borderWidth = 1
        b.layer.borderColor = UIColor(hex: 0xBBBBBB).cgColor
        b.backgroundColor = .white
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    // MARK: - 条码输入模式控件（老版本逻辑）
    private func buildBcModeViews() {
        let l = UILabel()
        l.text = "条码"
        l.font = .systemFont(ofSize: 14, weight: .medium)
        l.textColor = UIColor(hex: 0x555555)
        stack.addArrangedSubview(l)
        bcViews.append(l)

        bcField.placeholder = "输入完整条码"
        bcField.borderStyle = .roundedRect
        bcField.autocorrectionType = .no
        bcField.autocapitalizationType = .none
        bcField.font = .systemFont(ofSize: 16)
        bcField.returnKeyType = .done
        bcField.delegate = self
        bcField.inputAccessoryView = makeKeyboardToolbar()
        stack.addArrangedSubview(bcField)
        bcViews.append(bcField)
    }

    // MARK: - 模式切换
    @objc private func modeTapped(_ sender: UIButton) {
        let wantBc = sender == bcModeBtn
        if wantBc == bcMode { return }   // 点的是当前模式：不切换
        bcMode = wantBc
        hideKeyboard()
        applyMode()
    }

    private func applyMode() {
        // 选中态：绿色加粗边框；未选中：灰边框
        func apply(_ b: UIButton, on: Bool) {
            b.layer.borderColor = on ? UIColor(hex: 0x2E7D32).cgColor : UIColor(hex: 0xBBBBBB).cgColor
            b.setTitleColor(on ? UIColor(hex: 0x2E7D32) : UIColor(hex: 0x888888), for: .normal)
            b.titleLabel?.font = on ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13, weight: .semibold)
        }
        apply(codeModeBtn, on: !bcMode)
        apply(bcModeBtn, on: bcMode)
        codeViews.forEach { $0.isHidden = bcMode }
        bcViews.forEach { $0.isHidden = !bcMode }
    }

    // MARK: - 商品代码联想（防抖 150ms + 响应序号防过期）
    @objc private func codeChanged() {
        let kw = (codeField.text ?? "").trimmingCharacters(in: .whitespaces)
        searchWork?.cancel()
        collapseAll()
        resetCascadeIfNeeded()   // 重新输入代码：复位颜色/尺码级联状态
        if kw.isEmpty || kw == lastPicked { return }
        let seq = searchSeq
        let work = DispatchWorkItem { [weak self] in self?.doSearch(kw, seq: seq) }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func doSearch(_ kw: String, seq: Int) {
        BillApi.spSearch(kw: kw) { [weak self] codes, err in
            guard let self = self, seq == self.searchSeq else { return }
            if let err = err { CenterToast.show(err); return }
            guard let codes = codes else { return }
            self.suggestCodes = codes
            self.noMatchLabel.isHidden = codes.isEmpty ? false : true
            self.setTableHeight(self.suggestTable, self.suggestTableH,
                                rows: codes.count, maxHeight: 280)
        }
    }

    private var suggestCodes: [String] = []

    /// 展开选项列表高度（行数 × 行高，超高内部滚动）；0 = 收起
    private func setTableHeight(_ tv: UITableView, _ c: NSLayoutConstraint?, rows: Int, maxHeight: CGFloat) {
        let h = rows <= 0 ? 0 : min(CGFloat(rows) * tv.rowHeight + 4, maxHeight)
        c?.constant = h
        tv.isHidden = h <= 0
        tv.reloadData()
        tv.layoutIfNeeded()
        tv.isScrollEnabled = CGFloat(rows) * tv.rowHeight + 4 > maxHeight
    }

    private func collapseAll() {
        searchSeq += 1   // 使在途联想响应过期
        [ (suggestTable, suggestTableH), (colorTable, colorTableH), (sizeTable, sizeTableH) ]
            .forEach { $0.0.isHidden = true; $0.1?.constant = 0 }
        noMatchLabel.isHidden = true
    }

    // MARK: - 颜色/尺码选项展开与收起（同时只展开一个）
    @objc private func colorTapped() {
        guard !colors.isEmpty else { CenterToast.show("请先选择商品代码"); return }
        let open = !((colorTableH?.constant ?? 0) > 0)
        collapseAll()
        if open { setTableHeight(colorTable, colorTableH, rows: colors.count, maxHeight: 300) }
    }

    @objc private func sizeTapped() {
        guard !sizes.isEmpty else { CenterToast.show("请先选择商品代码"); return }
        let open = !((sizeTableH?.constant ?? 0) > 0)
        collapseAll()
        if open { setTableHeight(sizeTable, sizeTableH, rows: sizes.count, maxHeight: 300) }
    }

    // MARK: - 商品规格加载（选完商品代码后级联）
    private func loadGg(_ spdm: String) {
        BillApi.spGg(spdm: spdm) { [weak self] gg, err in
            guard let self = self else { return }
            guard let gg = gg else { CenterToast.show(err ?? "查询失败"); return }
            self.loadedSpdm = spdm
            self.colors = gg.colors
            self.sizes = gg.sizes
            self.selColor = nil
            self.selSize = nil
            self.setPickVal(self.colorBtn, nil)
            self.setPickVal(self.sizeBtn, nil)
            self.collapseAll()
            self.prodLabel.text = [gg.spmc, gg.unit.isEmpty ? "" : "单位：\(gg.unit)"]
                .filter { !$0.isEmpty }.joined(separator: "　")
            self.prodLabel.isHidden = false
        }
    }

    private func setPickVal(_ b: UIButton, _ text: String?) {
        b.setTitle(text ?? "-- 请选择 --", for: .normal)
        b.setTitleColor(text != nil ? UIColor(hex: 0x2E7D32) : UIColor(hex: 0x999999), for: .normal)
        b.titleLabel?.font = text != nil ? .boldSystemFont(ofSize: 16) : .systemFont(ofSize: 16)
    }

    /// 输入新代码时复位规格级联状态（重新选商品后颜色/尺码重新加载），并恢复常规字色
    private func resetCascadeIfNeeded() {
        let cur = (codeField.text ?? "").trimmingCharacters(in: .whitespaces)
        if cur != loadedSpdm && cur != lastPicked {
            loadedSpdm = nil
            colors = []; sizes = []
            selColor = nil; selSize = nil
            setPickVal(colorBtn, nil); setPickVal(sizeBtn, nil)
            prodLabel.isHidden = true
            codeField.textColor = UIColor(hex: 0x333333)
            codeField.font = .systemFont(ofSize: 16)
        }
    }

    // MARK: - 数量输入：只允许 1-999 的整数
    @objc private func qtyChanged() {
        let t = qtyField.text ?? ""
        if t.count > 3 { qtyField.text = String(t.prefix(3)) }
    }

    // MARK: - 发送
    @objc private func sendTapped() {
        hideKeyboard()
        if bcMode {
            // 条码输入模式（老版本逻辑）：直接按扫码同路径处理
            let bc = (bcField.text ?? "").trimmingCharacters(in: .whitespaces)
            if bc.isEmpty { CenterToast.show("请输入条码"); return }
            onSendBarcode?(bc)
            dismiss(animated: true)
            return
        }
        let spdm = (codeField.text ?? "").trimmingCharacters(in: .whitespaces)
        if spdm.isEmpty { CenterToast.show("请输入商品代码"); return }
        if spdm != loadedSpdm {
            // 代码未加载过规格（直接输入未走联想）：先加载，让用户选颜色尺码后再发送
            loadGg(spdm)
            CenterToast.show("已加载该商品的规格，请选择颜色和尺码后再次点击发送")
            return
        }
        guard let c = selColor, let s = selSize else {
            CenterToast.show("请选择颜色和尺码"); return
        }
        let qty = Int((qtyField.text ?? "").trimmingCharacters(in: .whitespaces)) ?? 0
        if qty < 1 || qty > 999 { CenterToast.show("数量需为 1-999 的整数"); return }
        sendBtn.isEnabled = false
        BillApi.spBarcode(spdm: spdm, gg1dm: c.code, gg2dm: s.code) { [weak self] sku, err in
            guard let self = self else { return }
            self.sendBtn.isEnabled = true
            guard let sku = sku else { CenterToast.show(err ?? "查询失败"); return }
            // 8 段 SKU（与验证通过路径同格式）：商品代码|颜色代码|尺码代码|商品名|颜色名|尺码名|单位
            let skuStr = [sku.spdm, sku.gg1dm, sku.gg2dm, sku.spmc,
                          sku.gg1mc, sku.gg2mc, sku.unit].joined(separator: "|")
            let product = [sku.spdm, sku.gg1mc, sku.gg2mc]
                .filter { !$0.isEmpty }.joined(separator: "|")
            // 数量 N = 扫 N 次：存储模式写 N 行、发送模式发 N 条
            // （bc 为按 TM 条码方案构造出的真实条码，上传/解析与扫码完全一致）
            for _ in 0..<qty { self.onSendSku?(sku.bc, product, skuStr) }
            self.dismiss(animated: true)
        }
    }

    // MARK: - 键盘
    private func makeKeyboardToolbar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
        bar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "收起键盘", style: .done, target: self, action: #selector(hideKeyboard))
        ]
        bar.sizeToFit()
        return bar
    }

    @objc private func hideKeyboard() {
        view.endEditing(true)
        collapseAll()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        collapseAll()
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // 焦点进商品代码框时若已改代码则复位级联（对齐安卓：重新输入需复位重选）
        if textField == codeField { resetCascadeIfNeeded() }
    }

    /// 点在输入框/按钮/选项列表（含列表内子视图）上时 tap 手势不处理，正常响应各自交互
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v: UIView? = touch.view
        while let cur = v {
            if cur is UITextField || cur is UIControl || cur is UITableView { return false }
            v = cur.superview
        }
        return true
    }

    @objc private func kbWillShow(_ n: Notification) {
        guard let frame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let inset = frame.height - view.safeAreaInsets.bottom
        scroll.contentInset.bottom = inset
        scroll.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
    }

    @objc private func kbWillHide(_ n: Notification) {
        scroll.contentInset.bottom = 0
        scroll.scrollIndicatorInsets = .zero
    }

    // MARK: - 选项列表数据源（联想/颜色/尺码共用）
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView == suggestTable { return suggestCodes.count }
        if tableView == colorTable { return colors.count }
        if tableView == sizeTable { return sizes.count }
        return 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
        cell.backgroundColor = .clear
        cell.textLabel?.font = .systemFont(ofSize: 16)
        cell.textLabel?.textColor = UIColor(hex: 0x333333)
        if tableView == suggestTable {
            cell.accessoryType = .none
            cell.textLabel?.text = suggestCodes[indexPath.row]
        } else if tableView == colorTable {
            let o = colors[indexPath.row]
            cell.textLabel?.text = o.name
            cell.accessoryType = o.code == selColor?.code ? .checkmark : .none
        } else {
            let o = sizes[indexPath.row]
            cell.textLabel?.text = o.name
            cell.accessoryType = o.code == selSize?.code ? .checkmark : .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        if tableView == suggestTable {
            // 选中联想项：回填代码（绿色加粗）并加载颜色/尺码
            let code = suggestCodes[indexPath.row]
            lastPicked = code
            codeField.text = code
            codeField.textColor = UIColor(hex: 0x2E7D32)
            codeField.font = .boldSystemFont(ofSize: 16)
            collapseAll()
            loadGg(code)
        } else if tableView == colorTable {
            selColor = colors[indexPath.row]
            setPickVal(colorBtn, selColor?.name)
            collapseAll()
        } else {
            selSize = sizes[indexPath.row]
            setPickVal(sizeBtn, selSize?.name)
            collapseAll()
        }
    }
}
