import UIKit

/// 终端背景色
private let terminalBgColor = UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)

/// 键盘辅助栏：深色终端风格，支持横向滚动
final class TerminalInputAccessoryView: UIView {
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

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    private func setupUI() {
        backgroundColor = terminalBgColor
        autoresizingMask = .flexibleWidth

        // 顶部分隔线
        let topLine = UIView()
        topLine.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        topLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topLine)

        // 收起键盘按钮（固定在右侧）
        let dismissBtn = UIButton(type: .system)
        dismissBtn.setImage(
            UIImage(systemName: "keyboard.chevron.compact.down"),
            for: .normal
        )
        dismissBtn.tintColor = .white
        dismissBtn.translatesAutoresizingMaskIntoConstraints = false
        dismissBtn.addTarget(
            self, action: #selector(dismissKeyboard),
            for: .touchUpInside
        )
        addSubview(dismissBtn)

        // 横向滚动区域
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // 按钮容器
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        for (index, key) in keys.enumerated() {
            let btn = UIButton(type: .system)
            btn.setTitle(key.label, for: .normal)
            btn.titleLabel?.font = .monospacedSystemFont(
                ofSize: 14, weight: .medium
            )
            btn.tintColor = .white
            btn.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            btn.layer.cornerRadius = 6
            btn.contentEdgeInsets = UIEdgeInsets(
                top: 6, left: 12, bottom: 6, right: 12
            )
            btn.tag = index
            btn.addTarget(
                self, action: #selector(keyTapped(_:)),
                for: .touchUpInside
            )
            stack.addArrangedSubview(btn)
        }

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.heightAnchor.constraint(
                equalToConstant: 1.0 / UIScreen.main.scale
            ),

            dismissBtn.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -8
            ),
            dismissBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissBtn.widthAnchor.constraint(equalToConstant: 36),

            scrollView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 8
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: dismissBtn.leadingAnchor, constant: -4
            ),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor
            ),
            stack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor
            ),
            stack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    @objc private func keyTapped(_ sender: UIButton) {
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
