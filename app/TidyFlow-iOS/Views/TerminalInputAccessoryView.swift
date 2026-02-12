import UIKit

/// 终端背景色
private let terminalBgColor = UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)

/// 键盘辅助栏：深色终端风格，支持横向滚动
final class TerminalInputAccessoryView: UIView {
    var onKey: ((String) -> Void)?

    /// 控制键（Esc/Tab/方向键）
    private let controlKeys: [(label: String, sequence: String)] = [
        ("Esc", "\u{1b}"),
        ("Tab", "\t"),
        ("↑", "\u{1b}[A"),
        ("↓", "\u{1b}[B"),
        ("→", "\u{1b}[C"),
        ("←", "\u{1b}[D"),
    ]

    /// 终端常用特殊符号（iOS 键盘不易输入）
    private let specialChars: [(label: String, sequence: String)] = [
        ("/", "/"),
        ("-", "-"),
        ("|", "|"),
        ("~", "~"),
        ("_", "_"),
        ("\\", "\\"),
        ("$", "$"),
        ("*", "*"),
        (">", ">"),
        ("'", "'"),
        ("\"", "\""),
        (":", ":"),
        ("#", "#"),
        ("&", "&"),
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

        // 控制键
        for (index, key) in controlKeys.enumerated() {
            stack.addArrangedSubview(
                makeKeyButton(label: key.label, tag: index)
            )
        }

        // 分隔线
        let separator = UIView()
        separator.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(separator)

        // 特殊符号
        for (index, key) in specialChars.enumerated() {
            stack.addArrangedSubview(
                makeKeyButton(
                    label: key.label,
                    tag: controlKeys.count + index
                )
            )
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

    private func makeKeyButton(label: String, tag: Int) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(label, for: .normal)
        btn.titleLabel?.font = .monospacedSystemFont(
            ofSize: 14, weight: .medium
        )
        btn.tintColor = .white
        btn.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        btn.layer.cornerRadius = 6
        btn.contentEdgeInsets = UIEdgeInsets(
            top: 6, left: 12, bottom: 6, right: 12
        )
        btn.tag = tag
        btn.addTarget(
            self, action: #selector(keyTapped(_:)),
            for: .touchUpInside
        )
        return btn
    }

    @objc private func keyTapped(_ sender: UIButton) {
        let index = sender.tag
        let allKeys = controlKeys + specialChars
        guard index < allKeys.count else { return }
        onKey?(allKeys[index].sequence)
    }

    @objc private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}
