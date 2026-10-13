import UIKit

/// 居中显示的深色 Toast（对齐安卓 CenterToast：深色圆角背景白字，屏幕中央显示，不挡底部按钮）
enum CenterToast {
    private static var hideTask: DispatchWorkItem?

    static func show(_ message: String, duration: TimeInterval = 1.8) {
        let window = UIApplication.shared.windows.first { $0.isKeyWindow }
        guard let w = window else { return }

        // 复用同一个视图，避免连续提示闪烁
        let label: UILabel
        if let existing = w.viewWithTag(0xC7A57) as? UILabel {
            label = existing
        } else {
            label = UILabel()
            label.tag = 0xC7A57
            label.textAlignment = .center
            label.numberOfLines = 0
            label.textColor = .white
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.backgroundColor = UIColor(white: 0.165, alpha: 0.94)   // #2A2A2A
            label.layer.cornerRadius = 10
            label.clipsToBounds = true
            w.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: w.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: w.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: w.leadingAnchor, constant: 30),
                label.trailingAnchor.constraint(lessThanOrEqualTo: w.trailingAnchor, constant: -30)
            ])
        }
        label.text = message
        label.alpha = 1
        w.bringSubviewToFront(label)

        hideTask?.cancel()
        let task = DispatchWorkItem {
            UIView.animate(withDuration: 0.25, animations: { label.alpha = 0 })
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
}
