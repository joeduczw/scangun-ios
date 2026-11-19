import UIKit

/// 屏幕居中提示（对齐安卓 CenterToast）：系统 Toast 位置不可控且会挡住底部按钮，
/// 用自定义 View 的 Toast 挪到屏幕中央。同一条提示重复触发时重置持续时间不叠加
enum CenterToast {

    /// 普通提示：深色背景 + 白字 15 号，2 秒
    static func show(_ message: String, duration: TimeInterval = 2.0) {
        present(message, duration: duration, tag: 0xC7A57,
                bg: UIColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 0.92),
                font: UIFont.systemFont(ofSize: 15))
    }

    /// 红色警示提示（大字号 18）：重要拦截提示（如未勾选文件点生成单据、未配置部门）
    static func showWarn(_ message: String, duration: TimeInterval = 3.0) {
        present(message, duration: duration, tag: 0xC7A58,
                bg: UIColor(red: 0.776, green: 0.157, blue: 0.157, alpha: 0.95),   // #C62828
                font: UIFont.systemFont(ofSize: 18))
    }

    private static func present(_ message: String, duration: TimeInterval, tag: Int,
                                bg: UIColor, font: UIFont) {
        DispatchQueue.main.async {
            // 同款提示已在显示：移除旧的重新计时（防叠加、防闪烁）
            if let win = UIApplication.shared.windows.first,
               let old = win.subviews.first(where: { $0.tag == tag }) {
                old.removeFromSuperview()
            }
            let label = UILabel()
            label.text = message
            label.font = font
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 0
            label.backgroundColor = bg
            label.layer.cornerRadius = 10
            label.layer.masksToBounds = true

            let wrap = UIView()
            wrap.tag = tag
            wrap.backgroundColor = .clear
            wrap.isUserInteractionEnabled = false
            wrap.addSubview(label)
            UIApplication.shared.windows.first?.addSubview(wrap)

            let maxW = UIScreen.main.bounds.width - 60
            let size = label.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
            let w = size.width + 36
            let h = size.height + 26
            label.frame = CGRect(x: 0, y: 0, width: w, height: h)
            wrap.frame = CGRect(x: (UIScreen.main.bounds.width - w) / 2,
                                y: (UIScreen.main.bounds.height - h) / 2,
                                width: w, height: h)

            UIView.animate(withDuration: 0.18, animations: { wrap.alpha = 1 },
                           completion: { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    UIView.animate(withDuration: 0.25, animations: { wrap.alpha = 0 },
                                   completion: { _ in if wrap.tag == tag { wrap.removeFromSuperview() } })
                }
            })
        }
    }
}
