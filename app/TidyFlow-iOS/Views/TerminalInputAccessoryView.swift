import UIKit

/// 终端背景色
private let terminalBgColor = UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)

/// 键盘辅助栏：深色终端风格，支持横向滚动
final class TerminalInputAccessoryView: UIView {
    var onKey: ((String) -> Void)?
    var onCtrlArmedChanged: ((Bool) -> Void)?
    var onPaste: (() -> Void)?

    private enum KeyKind {
        case ctrl
        case esc
        case tab
        case shiftTab
        case ctrlC
        case ctrlX
        case up
        case down
        case left
        case right
        case slash
        case at
        case hash
        case optionEnter
        case paste
    }

    private struct ToolbarKey {
        let label: String
        let kind: KeyKind
    }

    /// 仅保留移动端终端高频键位
    private let keys: [ToolbarKey] = [
        ToolbarKey(label: "Ctrl", kind: .ctrl),
        ToolbarKey(label: "Esc", kind: .esc),
        ToolbarKey(label: "Tab", kind: .tab),
        ToolbarKey(label: "↑", kind: .up),
        ToolbarKey(label: "↓", kind: .down),
        ToolbarKey(label: "←", kind: .left),
        ToolbarKey(label: "→", kind: .right),
        ToolbarKey(label: "/", kind: .slash),
        ToolbarKey(label: "@", kind: .at),
        ToolbarKey(label: "#", kind: .hash),
        ToolbarKey(label: "Shift+Tab", kind: .shiftTab),
        ToolbarKey(label: "Ctrl+C", kind: .ctrlC),
        ToolbarKey(label: "Ctrl+X", kind: .ctrlX),
        ToolbarKey(label: "⏎", kind: .optionEnter),
        ToolbarKey(label: "Paste", kind: .paste),
    ]

    /// Ctrl 一次性锁定：点击 Ctrl 后，下一个非 Ctrl 键按组合发送
    private var ctrlArmed = false {
        didSet {
            updateCtrlButtonAppearance()
            onCtrlArmedChanged?(ctrlArmed)
        }
    }
    private weak var ctrlButton: UIButton?
    private var ctrlStateObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    deinit {
        if let observer = ctrlStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
            stack.addArrangedSubview(
                makeKeyButton(label: key.label, tag: index)
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

        setupCtrlStateObserver()
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
        if keys[tag].kind == .ctrl {
            ctrlButton = btn
        }
        return btn
    }

    @objc private func keyTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index < keys.count else { return }

        let key = keys[index]
        if key.kind == .ctrl {
            ctrlArmed.toggle()
            return
        }
        if key.kind == .paste {
            onPaste?()
            return
        }

        let sequence = sequenceForKey(key.kind, ctrl: ctrlArmed)
        ctrlArmed = false
        onKey?(sequence)
    }

    private func updateCtrlButtonAppearance() {
        guard let ctrlButton else { return }
        ctrlButton.backgroundColor = ctrlArmed
            ? UIColor.systemBlue.withAlphaComponent(0.85)
            : UIColor.white.withAlphaComponent(0.12)
    }

    private func sequenceForKey(_ key: KeyKind, ctrl: Bool) -> String {
        if ctrl {
            switch key {
            case .shiftTab:
                return "\u{1b}[Z"
            case .ctrlC:
                return "\u{03}"
            case .ctrlX:
                return "\u{18}"
            case .up:
                return "\u{1b}[1;5A"
            case .down:
                return "\u{1b}[1;5B"
            case .right:
                return "\u{1b}[1;5C"
            case .left:
                return "\u{1b}[1;5D"
            case .slash:
                return "\u{1f}"   // Ctrl+/
            case .at:
                return "\u{00}"   // Ctrl+@
            case .hash:
                return "\u{1b}"   // 兼容 Ctrl+# ≈ Ctrl+3
            case .esc:
                return "\u{1b}"
            case .tab:
                return "\t"
            case .ctrl:
                return ""
            case .optionEnter:
                return "\u{1b}\r"
            case .paste:
                return ""
            }
        }

        switch key {
        case .esc:
            return "\u{1b}"
        case .tab:
            return "\t"
        case .shiftTab:
            return "\u{1b}[Z"
        case .ctrlC:
            return "\u{03}"
        case .ctrlX:
            return "\u{18}"
        case .up:
            return "\u{1b}[A"
        case .down:
            return "\u{1b}[B"
        case .right:
            return "\u{1b}[C"
        case .left:
            return "\u{1b}[D"
        case .slash:
            return "/"
        case .at:
            return "@"
        case .hash:
            return "#"
        case .ctrl:
            return ""
        case .optionEnter:
            return "\u{1b}\r"
        case .paste:
            return ""
        }
    }

    @objc private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func setupCtrlStateObserver() {
        ctrlStateObserver = NotificationCenter.default.addObserver(
            forName: .mobileTerminalCtrlStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let armed = notification.userInfo?["armed"] as? Bool else { return }
            if self.ctrlArmed != armed {
                self.ctrlArmed = armed
            }
        }
    }
}

extension Notification.Name {
    static let mobileTerminalCtrlStateDidChange = Notification.Name("mobileTerminalCtrlStateDidChange")
}
