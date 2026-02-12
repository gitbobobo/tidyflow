import UIKit

/// 键盘辅助栏：使用系统 UIToolbar 风格，嵌入终端快捷键
final class TerminalInputAccessoryView: UIToolbar {
    var onKey: ((String) -> Void)?

    private let keys: [(label: String, sequence: String)] = [
        ("Esc", "\u{1b}"),
        ("Tab", "\t"),
        ("↑", "\u{1b}[A"),
        ("↓", "\u{1b}[B"),
        ("→", "\u{1b}[C"),
        ("←", "\u{1b}[D"),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        sizeToFit()

        var items: [UIBarButtonItem] = []

        for (index, key) in keys.enumerated() {
            let btn = UIBarButtonItem(
                title: key.label,
                style: .plain,
                target: self,
                action: #selector(keyTapped(_:))
            )
            btn.tag = index
            items.append(btn)

            // 按钮间小间距
            let spacer = UIBarButtonItem.fixedSpace(2)
            items.append(spacer)
        }

        // 弹性间距，把收起键盘按钮推到右侧
        items.append(UIBarButtonItem.flexibleSpace())

        // 收起键盘按钮
        let dismissBtn = UIBarButtonItem(
            image: UIImage(systemName: "keyboard.chevron.compact.down"),
            style: .plain,
            target: self,
            action: #selector(dismissKeyboard)
        )
        items.append(dismissBtn)

        setItems(items, animated: false)
    }

    @objc private func keyTapped(_ sender: UIBarButtonItem) {
        let index = sender.tag
        guard index < keys.count else { return }
        onKey?(keys[index].sequence)
    }

    @objc private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}
