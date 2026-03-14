import UIKit

/// 编辑器键盘辅助栏：提供保存、撤销、重做、查找导航和收起键盘按钮。
/// 风格与 TerminalInputAccessoryView 同类实现方式。
final class EditorInputAccessoryView: UIView {

    var onSave: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onToggleFind: (() -> Void)?
    var onFindPrevious: (() -> Void)?
    var onFindNext: (() -> Void)?
    var onDismissKeyboard: (() -> Void)?
    /// 点击补全按钮回调
    var onAutocomplete: (() -> Void)?
    /// 添加下一个匹配选区（多光标）
    var onAddNextMatchSelection: (() -> Void)?
    /// 清空附加选区（回到单光标）
    var onClearAdditionalSelections: (() -> Void)?

    /// 当前撤销/重做是否可用（由外部更新，驱动按钮禁用态）
    var canUndo: Bool = false { didSet { updateButtonStates() } }
    var canRedo: Bool = false { didSet { updateButtonStates() } }
    /// 当前是否有补全候选（控制补全按钮高亮）
    var hasAutocompleteCandidates: Bool = false { didSet { updateButtonStates() } }

    private var undoButton: UIButton!
    private var redoButton: UIButton!
    private var autocompleteButton: UIButton!

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: frame.width, height: 44))
        autoresizingMask = [.flexibleWidth]
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = UIColor.secondarySystemBackground

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        // 收起键盘按钮固定在右侧
        let dismissBtn = makeButton(systemImage: "keyboard.chevron.compact.down", action: #selector(dismissKeyboardTapped))
        dismissBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dismissBtn)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: dismissBtn.leadingAnchor, constant: -4),

            dismissBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissBtn.widthAnchor.constraint(equalToConstant: 36),
            dismissBtn.heightAnchor.constraint(equalToConstant: 36),
        ])

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let saveBtn = makeButton(systemImage: "square.and.arrow.down", action: #selector(saveTapped))
        undoButton = makeButton(systemImage: "arrow.uturn.backward", action: #selector(undoTapped))
        redoButton = makeButton(systemImage: "arrow.uturn.forward", action: #selector(redoTapped))
        autocompleteButton = makeButton(systemImage: "text.badge.star", action: #selector(autocompleteTapped))
        let findBtn = makeButton(systemImage: "magnifyingglass", action: #selector(findTapped))
        let prevBtn = makeButton(systemImage: "chevron.up", action: #selector(findPreviousTapped))
        let nextBtn = makeButton(systemImage: "chevron.down", action: #selector(findNextTapped))

        // 分隔符
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor.separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // 分隔符2（补全按钮与查找之间）
        let separator2 = UIView()
        separator2.translatesAutoresizingMaskIntoConstraints = false
        separator2.backgroundColor = UIColor.separator
        separator2.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator2.heightAnchor.constraint(equalToConstant: 24).isActive = true

        for btn in [saveBtn, undoButton!, redoButton!, separator, autocompleteButton!, separator2, findBtn, prevBtn, nextBtn] {
            stack.addArrangedSubview(btn)
        }

        updateButtonStates()
    }

    private func makeButton(systemImage: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        btn.setImage(UIImage(systemName: systemImage, withConfiguration: config), for: .normal)
        btn.tintColor = .label
        btn.addTarget(self, action: action, for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 40).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return btn
    }

    private func updateButtonStates() {
        undoButton?.isEnabled = canUndo
        undoButton?.alpha = canUndo ? 1.0 : 0.3
        redoButton?.isEnabled = canRedo
        redoButton?.alpha = canRedo ? 1.0 : 0.3
        autocompleteButton?.tintColor = hasAutocompleteCandidates ? .systemBlue : .label
    }

    @objc private func saveTapped() { onSave?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
    @objc private func autocompleteTapped() { onAutocomplete?() }
    @objc private func findTapped() { onToggleFind?() }
    @objc private func findPreviousTapped() { onFindPrevious?() }
    @objc private func findNextTapped() { onFindNext?() }
    @objc private func dismissKeyboardTapped() { onDismissKeyboard?() }
}
