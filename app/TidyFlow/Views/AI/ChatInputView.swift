import SwiftUI
#if os(iOS)
import UIKit
#if canImport(PhotosUI)
import PhotosUI
#endif
#endif
#if os(macOS)
import AppKit

// MARK: - 支持 IME 的聊天输入框（NSTextView 包装）

@inline(__always)
private func imeDebugLog(_ message: String) {
    #if DEBUG
    TFLog.log(TFLog.app, category: "ime", level: "DEBUG", "[ChatInputView] \(message)")
    #endif
}

struct ChatTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    /// 光标相对于 ScrollView 的位置（用于定位弹出层）
    @Binding var cursorRect: CGRect
    var font: NSFont = .systemFont(ofSize: 13)
    var onEnter: () -> Void
    var isEnterEnabled: () -> Bool
    /// 自动补全键盘拦截（返回 true 表示已消费）
    var onArrowUp: (() -> Bool)?
    var onArrowDown: (() -> Bool)?
    var onEscape: (() -> Bool)?
    var onTab: (() -> Bool)?
    /// 粘贴处理（返回 true 表示已消费）
    var onPaste: (() -> Bool)?
    /// 输入上下文变化（光标 UTF16 位置, 是否处于 IME 组合态）
    var onInputContextChange: ((Int, Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = IMEAwareTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 5
        textView.onEnter = { [weak textView] in
            guard let tv = textView else { return }
            // IME 组合态中，不拦截 Enter
            let composing = tv.hasMarkedText() || tv.isIMEComposing
            imeDebugLog("onEnter callback -> hasMarkedText=\(tv.hasMarkedText()) isIMEComposing=\(tv.isIMEComposing)")
            if composing {
                imeDebugLog("onEnter ignored because composing=true")
                return
            }
            if context.coordinator.parent.isEnterEnabled() {
                imeDebugLog("onEnter forwarded to ChatInputView")
                context.coordinator.parent.onEnter()
            } else {
                imeDebugLog("onEnter blocked by isEnterEnabled=false")
            }
        }
        textView.onArrowUp = { context.coordinator.parent.onArrowUp?() ?? false }
        textView.onArrowDown = { context.coordinator.parent.onArrowDown?() ?? false }
        textView.onEscape = { context.coordinator.parent.onEscape?() ?? false }
        textView.onTab = { context.coordinator.parent.onTab?() ?? false }
        textView.onPaste = { context.coordinator.parent.onPaste?() ?? false }
        textView.onCompositionStateChange = { [weak textView] in
            context.coordinator.handleCompositionStateChange(textView)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // 初始高度
        DispatchQueue.main.async {
            context.coordinator.updateHeight()
            context.coordinator.reportInputContext()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            let composing = textView.hasMarkedText()
            // IME 组合期间避免程序化回写文本，防止打断候选状态
            if composing { return }
            textView.string = text
            // 程序化设置文本后，光标移到末尾
            let endPos = (text as NSString).length
            textView.setSelectedRange(NSRange(location: endPos, length: 0))
            context.coordinator.updateHeight()
            context.coordinator.updateCursorRect()
            context.coordinator.reportInputContext()
        }
        textView.font = font
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextView
        weak var textView: NSTextView?

        init(_ parent: ChatTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportInputContext(textView)
            let composing = textView.hasMarkedText()
            // 组合期间不向外同步文本，避免 SwiftUI 回写影响 IME
            if !composing {
                parent.text = textView.string
            }
            updateHeight()
            updateCursorRect()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateCursorRect()
            guard let textView = notification.object as? NSTextView else { return }
            reportInputContext(textView)
        }

        func updateHeight() {
            guard let textView = textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let inset = textView.textContainerInset
            let newHeight = usedRect.height + inset.height * 2
            DispatchQueue.main.async {
                self.parent.contentHeight = newHeight
            }
        }

        func updateCursorRect() {
            guard let textView = textView,
                  !textView.string.isEmpty,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let insertionPoint = textView.selectedRange().location
            guard insertionPoint != NSNotFound else { return }
            let charIndex = min(insertionPoint, textView.string.count - 1)
            let numberOfGlyphs = layoutManager.numberOfGlyphs
            guard numberOfGlyphs > 0 else { return }
            let glyphIndex = min(layoutManager.glyphIndexForCharacter(at: charIndex), numberOfGlyphs - 1)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: glyphIndex)
            let inset = textView.textContainerInset
            let padding = textView.textContainer?.lineFragmentPadding ?? 0
            // 光标在 textView 坐标系中的位置
            let cursorX = lineRect.origin.x + location.x + inset.width + padding
            let cursorY = lineRect.origin.y + inset.height
            // 转换到 scrollView 坐标系
            if let scrollView = textView.enclosingScrollView {
                let pointInScroll = textView.convert(CGPoint(x: cursorX, y: cursorY), to: scrollView)
                DispatchQueue.main.async {
                    self.parent.cursorRect = CGRect(x: pointInScroll.x, y: pointInScroll.y, width: 1, height: lineRect.height)
                }
            }
        }

        func reportInputContext(_ target: NSTextView? = nil) {
            guard let textView = target ?? textView else { return }
            let totalLength = (textView.string as NSString).length
            let selected = textView.selectedRange().location
            let location = selected == NSNotFound ? totalLength : min(max(selected, 0), totalLength)
            // 对外只上报系统 marked text 状态，避免输入法未回调 unmarkText 时长期卡在 composing=true
            let isComposing = textView.hasMarkedText()
            parent.onInputContextChange?(location, isComposing)
        }

        func handleCompositionStateChange(_ target: NSTextView? = nil) {
            guard let textView = target ?? textView else { return }
            reportInputContext(textView)
            let composing = textView.hasMarkedText()
            if !composing, parent.text != textView.string {
                parent.text = textView.string
            }
        }
    }
}

/// 自定义 NSTextView，在 keyDown 层拦截 Enter 并兼容 IME
private class IMEAwareTextView: NSTextView {
    var onEnter: (() -> Void)?
    var onArrowUp: (() -> Bool)?
    var onArrowDown: (() -> Bool)?
    var onEscape: (() -> Bool)?
    var onTab: (() -> Bool)?
    var onPaste: (() -> Bool)?
    var onCompositionStateChange: (() -> Void)?
    private(set) var isIMEComposing: Bool = false
    /// 防止同一次 Return 事件被 keyDown/doCommand 重复处理
    private var didHandleReturnInKeyDown: Bool = false

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let markedText: String
        if let plain = string as? String {
            markedText = plain
        } else if let attr = string as? NSAttributedString {
            markedText = attr.string
        } else {
            markedText = String(describing: string)
        }
        isIMEComposing = true
        imeDebugLog("setMarkedText text=\(markedText.debugDescription) selectedRange=\(selectedRange) replacementRange=\(replacementRange)")
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionStateChange?()
    }

    override func unmarkText() {
        imeDebugLog("unmarkText before super hasMarkedText=\(hasMarkedText()) isIMEComposing=\(isIMEComposing)")
        super.unmarkText()
        isIMEComposing = false
        imeDebugLog("unmarkText after super hasMarkedText=\(hasMarkedText()) isIMEComposing=\(isIMEComposing)")
        onCompositionStateChange?()
    }

    override func paste(_ sender: Any?) {
        if onPaste?() == true {
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        // Cmd+V：优先走图片粘贴处理，未消费再回落默认文本粘贴。
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            if onPaste?() == true {
                return
            }
        }

        // 每次按键先清理，避免旧 Return 状态污染后续事件。
        didHandleReturnInKeyDown = false
        if event.keyCode == 36 || hasMarkedText() || isIMEComposing {
            imeDebugLog("keyDown keyCode=\(event.keyCode) chars=\((event.characters ?? "").debugDescription) charsIgnoringModifiers=\((event.charactersIgnoringModifiers ?? "").debugDescription) hasMarkedText=\(hasMarkedText()) isIMEComposing=\(isIMEComposing)")
        }
        // IME 组合态，全部交给系统处理
        if hasMarkedText() || isIMEComposing {
            imeDebugLog("keyDown forwarded to super due to composing")
            super.keyDown(with: event)
            return
        }

        let isShift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 36: // Return
            if !isShift {
                didHandleReturnInKeyDown = true
                imeDebugLog("keyDown return -> trigger onEnter")
                onEnter?()
                return
            }
        case 126: // Arrow Up
            if onArrowUp?() == true { return }
        case 125: // Arrow Down
            if onArrowDown?() == true { return }
        case 53: // Escape
            if onEscape?() == true { return }
        case 48: // Tab
            if onTab?() == true { return }
        default:
            break
        }
        if event.keyCode == 36 {
            imeDebugLog("keyDown return fell through to super")
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:))
            || selector == #selector(insertTab(_:))
            || selector == #selector(moveUp(_:))
            || selector == #selector(moveDown(_:))
            || selector == #selector(cancelOperation(_:)) {
            imeDebugLog("doCommand selector=\(NSStringFromSelector(selector)) hasMarkedText=\(hasMarkedText()) isIMEComposing=\(isIMEComposing)")
        }

        // 某些输入法路径不会走 keyDown，兜底在 doCommand 里处理 Enter。
        if selector == #selector(insertNewline(_:)) {
            // keyDown 已处理本次 Return，直接消费避免重复。
            if didHandleReturnInKeyDown {
                didHandleReturnInKeyDown = false
                imeDebugLog("doCommand ignored insertNewline because keyDown already handled")
                return
            }
            if hasMarkedText() {
                imeDebugLog("doCommand blocked insertNewline due to hasMarkedText=true")
                return
            }
            // 某些输入法不会稳定回调 unmarkText，这里在无 marked text 的回车点兜底清理组合态
            if isIMEComposing {
                imeDebugLog("doCommand insertNewline clears stale isIMEComposing flag")
                isIMEComposing = false
                onCompositionStateChange?()
            }

            // 仅处理普通 Enter；Shift+Enter 继续走默认换行行为。
            let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if !isShift {
                imeDebugLog("doCommand insertNewline fallback -> trigger onEnter")
                onEnter?()
                return
            }
        }

        if hasMarkedText() || isIMEComposing {
            super.doCommand(by: selector)
            return
        }

        if selector == #selector(moveUp(_:)) {
            if onArrowUp?() == true { return }
        } else if selector == #selector(moveDown(_:)) {
            if onArrowDown?() == true { return }
        } else if selector == #selector(cancelOperation(_:)) {
            if onEscape?() == true { return }
        } else if selector == #selector(insertTab(_:)) {
            if onTab?() == true { return }
        }

        super.doCommand(by: selector)
    }
}
#endif

#if os(iOS)
/// Sheet 内自动聚焦搜索框——绕过 @FocusState 与 UITextView 的 firstResponder 竞争
private struct IOSAutoFocusTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.font = .systemFont(ofSize: 16)
        tf.clearButtonMode = .whileEditing
        tf.returnKeyType = .search
        tf.addTarget(context.coordinator,
                     action: #selector(Coordinator.textChanged(_:)),
                     for: .editingChanged)
        // 多次重试覆盖 sheet 弹出动画周期
        for delay in [0.35, 0.6, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if tf.window != nil && !tf.isFirstResponder {
                    tf.becomeFirstResponder()
                }
            }
        }
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text { uiView.text = text }
    }

    final class Coordinator: NSObject {
        var parent: IOSAutoFocusTextField
        init(_ parent: IOSAutoFocusTextField) { self.parent = parent }
        @objc func textChanged(_ tf: UITextField) {
            parent.text = tf.text ?? ""
        }
    }
}

#endif

struct ChatInputView: View {
    @Binding var text: String
    @Binding var imageAttachments: [ImageAttachment]
    var isStreaming: Bool
    /// iOS: 视图出现后自动聚焦输入框。
    var autoFocusOnAppear: Bool = false
    /// 仅当已有 sessionId 时允许点击停止，避免会话创建竞态下误触。
    var canStopStreaming: Bool = true
    var onSend: () -> Void
    var onStop: () -> Void

    // 模型 / Agent 状态
    var providers: [AIProviderInfo]
    @Binding var selectedModel: AIModelSelection?
    var agents: [AIAgentInfo]
    @Binding var selectedAgent: String?

    // 自动补全
    var autocomplete: AutocompleteState?
    var onSelectAutocomplete: ((AutocompleteItem) -> Void)?
    /// iOS 输入辅助：命令列表
    var slashCommands: [AISlashCommandInfo] = []
    /// iOS 输入辅助：引用列表（文件路径）
    var fileReferenceItems: [String] = []
    /// iOS 输入辅助：打开引用列表前按需拉取索引
    var onRequestFileReferences: (() -> Void)?
    /// iOS 输入辅助：引用搜索词变化时触发实时查询
    var onSearchFileReferences: ((String) -> Void)?
    /// 输入上下文变化（光标 UTF16 位置, 是否处于 IME 组合态）
    var onInputContextChange: ((Int, Bool) -> Void)?
    /// 光标位置（外部读取用于定位弹出层）
    @Binding var cursorRectInInput: CGRect

    @State private var textContentHeight: CGFloat = 28
    /// 光标在输入框内的位置（由 NSTextView 上报）
    @State private var cursorRect: CGRect = .zero
    #if os(iOS)
    private enum IOSInputPanelSheet: String, Identifiable {
        case commands
        case references
        var id: String { rawValue }
    }

    @FocusState private var isIOSInputFocused: Bool
    @State private var showIOSInputPanel: Bool = false
    @State private var iOSInputPanelSheet: IOSInputPanelSheet?
    @State private var commandSearchText: String = ""
    @State private var referenceSearchText: String = ""
    #endif
    #if os(iOS) && canImport(PhotosUI)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
    }
    #if os(macOS)
    private let maxImageAttachmentCount = 9
    #endif

    private var inputEditorBackgroundColor: Color {
        #if os(iOS)
        return Color(UIColor.secondarySystemBackground)
        #else
        return Color.secondary.opacity(0.08)
        #endif
    }

    private var inputEditorBorderColor: Color {
        #if os(iOS)
        return Color.white.opacity(0.15)
        #else
        return Color.secondary.opacity(0.2)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            // 图片缩略图预览行
            if !imageAttachments.isEmpty {
                imagePreviewRow
            }

            #if os(iOS)
            iOSInputSection
            #else
            // 输入区域
            inputEditor

            // 工具栏
            toolbar
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        #if os(iOS)
        .padding(.bottom, 0)
        #else
        .padding(.bottom, 12)
        #endif
        .onChange(of: cursorRect) { _, newRect in
            cursorRectInInput = newRect
        }
    }

    #if os(iOS)
    private var iOSInputSection: some View {
        VStack(spacing: 8) {
            iOSSelectorRow

            HStack(alignment: .center, spacing: 10) {
                iOSInputModeToggleButton

                inputEditor
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 36)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(inputEditorBackgroundColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(inputEditorBorderColor, lineWidth: 0.5)
                    )

                sendOrStopButton
            }

            if showIOSInputPanel {
                iOSInputPanelGrid
            }
        }
        .padding(.bottom, 8)
        .onAppear {
            guard autoFocusOnAppear else { return }
            requestIOSInputFocus()
        }
        .onChange(of: isIOSInputFocused) { _, focused in
            if focused {
                showIOSInputPanel = false
            }
        }
        .sheet(item: $iOSInputPanelSheet) { item in
            switch item {
            case .commands:
                iOSCommandPickerSheet
            case .references:
                iOSReferencePickerSheet
            }
        }
    }

    @ViewBuilder
    private var iOSSelectorRow: some View {
        if !agents.isEmpty || !providers.isEmpty {
            HStack(spacing: 8) {
                agentButton
                modelButton
                Spacer(minLength: 0)
            }
        }
    }

    private var iOSInputModeToggleButton: some View {
        Button(action: toggleIOSInputPanel) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(showIOSInputPanel ? Color.accentColor : Color.white.opacity(0.18))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var iOSInputPanelGrid: some View {
        let columns: [GridItem] = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
        return LazyVGrid(columns: columns, spacing: 8) {
            iOSImagePanelButton

            Button(action: {
                commandSearchText = ""
                openIOSInputSheet(.commands)
            }) {
                iOSInputPanelTile(
                    title: "命令",
                    systemImage: "command",
                    tint: .orange
                )
            }
            .buttonStyle(.plain)

            Button(action: {
                referenceSearchText = ""
                onRequestFileReferences?()
                openIOSInputSheet(.references)
            }) {
                iOSInputPanelTile(
                    title: "引用",
                    systemImage: "at",
                    tint: .green
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var iOSImagePanelButton: some View {
        #if canImport(PhotosUI)
        PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: 6,
            matching: .images
        ) {
            iOSInputPanelTile(
                title: "图片",
                systemImage: "photo",
                tint: .blue
            )
        }
        .onChange(of: selectedPhotoItems) { _, items in
            handleSelectedPhotoItems(items)
        }
        #else
        Button(action: pickImage) {
            iOSInputPanelTile(
                title: "图片",
                systemImage: "photo",
                tint: .blue
            )
        }
        .buttonStyle(.plain)
        #endif
    }

    private func iOSInputPanelTile(
        title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var filteredSlashCommandsForIOS: [AISlashCommandInfo] {
        let query = commandSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return slashCommands }
        return slashCommands.filter { command in
            command.name.localizedCaseInsensitiveContains(query)
                || command.description.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredFileReferencesForIOS: [String] {
        let query = referenceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return fileReferenceItems }
        return fileReferenceItems.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var iOSCommandPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    IOSAutoFocusTextField(text: $commandSearchText, placeholder: "搜索命令")
                        .frame(height: 22)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)

                List(filteredSlashCommandsForIOS, id: \.id) { command in
                    Button(action: {
                        insertSlashCommandAtInputStart(command.name)
                        iOSInputPanelSheet = nil
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: slashCommandIcon(command.name))
                                .frame(width: 18)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("/\(command.name)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.primary)
                                if !command.description.isEmpty {
                                    Text(command.description)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        iOSInputPanelSheet = nil
                    }) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
    }

    private var iOSReferencePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    IOSAutoFocusTextField(text: $referenceSearchText, placeholder: "搜索引用")
                        .frame(height: 22)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)

                List(filteredFileReferencesForIOS, id: \.self) { path in
                    Button(action: {
                        appendFileReferenceToInput(path)
                        iOSInputPanelSheet = nil
                    }) {
                        Text(path)
                            .font(.system(size: 13))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("引用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        iOSInputPanelSheet = nil
                    }) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭")
                }
            }
            .onAppear {
                onSearchFileReferences?(referenceSearchText)
            }
            .onChange(of: referenceSearchText) { _, query in
                onSearchFileReferences?(query)
            }
        }
    }

    private func openIOSInputSheet(_ sheet: IOSInputPanelSheet) {
        // 先让主输入框失焦，sheet 内的 IOSAutoFocusTextField 会通过 UIKit
        // becomeFirstResponder() 自动接管键盘，无需 dismissIOSKeyboard()。
        isIOSInputFocused = false
        showIOSInputPanel = false
        iOSInputPanelSheet = sheet
    }

    private func toggleIOSInputPanel() {
        if showIOSInputPanel {
            showIOSInputPanel = false
            isIOSInputFocused = true
        } else {
            showIOSInputPanel = true
            isIOSInputFocused = false
        }
    }

    private func requestIOSInputFocus() {
        showIOSInputPanel = false
        // 进入页面时多次尝试，覆盖导航动画和键盘系统时序。
        for delay in [0.0, 0.12, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard iOSInputPanelSheet == nil else { return }
                isIOSInputFocused = true
            }
        }
    }

    private func insertSlashCommandAtInputStart(_ commandName: String) {
        let prefix = "/\(commandName)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            text = "\(prefix) "
            return
        }
        text = "\(prefix) \(text)"
    }

    private func appendFileReferenceToInput(_ path: String) {
        let token = "@\(path)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            text = "\(token) "
            return
        }
        if text.hasSuffix(" ") || text.hasSuffix("\n") {
            text += "\(token) "
        } else {
            text += " \(token) "
        }
    }
    #endif

    // MARK: - 图片预览行

    private var imagePreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(imageAttachments) { attachment in
                    imagePreviewItem(attachment)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func imagePreviewItem(_ attachment: ImageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            #if os(macOS)
            Image(nsImage: attachment.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 60)
                .cornerRadius(8)
                .clipped()
            #else
            if let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    )
            }
            #endif

            Button(action: {
                imageAttachments.removeAll { $0.id == attachment.id }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)).frame(width: 18, height: 18))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    // MARK: - 输入编辑器

    private var inputEditor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Group {
                    #if os(iOS)
                    Text("输入消息...")
                    #else
                    Text("输入消息...  @ 引用文件  / 斜杠命令")
                    #endif
                }
                    .foregroundColor(.secondary.opacity(0.6))
                    .font(.system(size: 13))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            #if os(macOS)
            ChatTextView(
                text: $text,
                contentHeight: $textContentHeight,
                cursorRect: $cursorRect,
                font: .systemFont(ofSize: 13),
                onEnter: {
                    imeDebugLog("ChatInputView.onEnter start text=\(text.debugDescription) canSend=\(canSend) isStreaming=\(isStreaming) autocompleteVisible=\(autocomplete?.isVisible == true)")
                    // 弹出层可见时，Enter 选择当前项
                    if let ac = autocomplete, ac.isVisible, let item = ac.selectedItem {
                        imeDebugLog("ChatInputView.onEnter select autocomplete item=\(item.value)")
                        onSelectAutocomplete?(item)
                        return
                    }
                    if canSend && !isStreaming {
                        imeDebugLog("ChatInputView.onEnter call onSend")
                        onSend()
                    } else {
                        imeDebugLog("ChatInputView.onEnter ignored canSend=\(canSend) isStreaming=\(isStreaming)")
                    }
                },
                isEnterEnabled: { [canSend, isStreaming] in
                    if let ac = autocomplete, ac.isVisible { return true }
                    return canSend && !isStreaming
                },
                onArrowUp: { autocomplete?.isVisible == true ? { autocomplete?.moveUp(); return true }() : false },
                onArrowDown: { autocomplete?.isVisible == true ? { autocomplete?.moveDown(); return true }() : false },
                onEscape: { autocomplete?.isVisible == true ? { autocomplete?.reset(); return true }() : false },
                onTab: {
                    guard let ac = autocomplete, ac.isVisible, let item = ac.selectedItem else { return false }
                    onSelectAutocomplete?(item)
                    return true
                },
                onPaste: {
                    handleMacOSPasteImages()
                },
                onInputContextChange: onInputContextChange
            )
            .frame(height: min(max(textContentHeight, 28), 80))
            #else
            TextField("", text: $text, axis: .vertical)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($isIOSInputFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .onTapGesture {
                    if !isIOSInputFocused {
                        isIOSInputFocused = true
                    }
                }
            #endif
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            // 左侧：Agent 切换 + 模型选择
            agentButton
            modelButton

            Spacer()

            // 右侧：图片上传 + 发送/停止
            imageUploadButton
            sendOrStopButton
        }
        .padding(.top, 8)
    }

    // MARK: - Agent 切换按钮

    private var agentButton: some View {
        Group {
            if !agents.isEmpty {
                Menu {
                    ForEach(agents) { agent in
                        Button(action: {
                            selectedAgent = agent.name
                            // 自动切换到 agent 默认模型
                            if let pid = agent.defaultProviderID,
                               let mid = agent.defaultModelID,
                               !pid.isEmpty, !mid.isEmpty {
                                selectedModel = AIModelSelection(providerID: pid, modelID: mid)
                            }
                        }) {
                            HStack {
                                Text(agent.name)
                                if let desc = agent.description, !desc.isEmpty {
                                    Text("— \(desc)")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                        Text(selectedAgent ?? agents.first?.name ?? "Agent")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: selectorLabelMaxWidth, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                    .foregroundStyle(dropdownPrimaryTextColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - 模型选择按钮

    private var modelButton: some View {
        Group {
            if !providers.isEmpty {
                Menu {
                    if availableModelProviders.count <= 1 {
                        if let onlyProvider = availableModelProviders.first {
                            ForEach(onlyProvider.models) { model in
                                Button(action: {
                                    selectedModel = AIModelSelection(providerID: onlyProvider.id, modelID: model.id)
                                }) {
                                    Text(model.name)
                                }
                            }
                        } else {
                            Text("暂无可用模型")
                        }
                    } else {
                        ForEach(availableModelProviders) { provider in
                            Menu(provider.name) {
                                ForEach(provider.models) { model in
                                    Button(action: {
                                        selectedModel = AIModelSelection(providerID: provider.id, modelID: model.id)
                                    }) {
                                        Text(model.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11))
                        Text(selectedModelDisplayName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .frame(maxWidth: selectorLabelMaxWidth, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                    .foregroundStyle(dropdownPrimaryTextColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// 仅保留有模型的提供商，避免展示空菜单。
    private var availableModelProviders: [AIProviderInfo] {
        providers.filter { !$0.models.isEmpty }
    }

    private var selectedModelDisplayName: String {
        guard let sel = selectedModel else { return "模型" }
        for p in providers {
            if let m = p.models.first(where: { $0.id == sel.modelID && p.id == sel.providerID }) {
                return m.name
            }
        }
        return sel.modelID
    }

    private func slashCommandIcon(_ name: String) -> String {
        switch name {
        case "new":
            return "square.and.pencil"
        default:
            return "command"
        }
    }

    // MARK: - 图片上传按钮

    @ViewBuilder
    private var imageUploadButton: some View {
        #if os(iOS) && canImport(PhotosUI)
        PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: 6,
            matching: .images
        ) {
            Image(systemName: "photo")
                .font(.system(size: actionIconFontSize, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                .background(Color.white.opacity(0.18))
                .clipShape(Circle())
        }
        .onChange(of: selectedPhotoItems) { _, items in
            handleSelectedPhotoItems(items)
        }
        #else
        Button(action: pickImage) {
            Image(systemName: "photo")
                .font(.system(size: actionIconFontSize, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("上传图片")
        #endif
    }

    #if os(iOS) && canImport(PhotosUI)
    private func handleSelectedPhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let fileInfo = detectImageFileInfo(data: data)
                let suffix = UUID().uuidString.prefix(8)
                let filename = "image_\(suffix).\(fileInfo.ext)"
                let attachment = ImageAttachment(filename: filename, data: data, mime: fileInfo.mime)
                await MainActor.run {
                    imageAttachments.append(attachment)
                }
            }
            await MainActor.run {
                selectedPhotoItems = []
            }
        }
    }
    #endif

    private func pickImage() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.lowercased()
                let mime: String
                switch ext {
                case "png": mime = "image/png"
                case "jpg", "jpeg": mime = "image/jpeg"
                case "gif": mime = "image/gif"
                case "webp": mime = "image/webp"
                default: mime = "image/png"
                }
                let attachment = ImageAttachment(
                    filename: url.lastPathComponent,
                    data: data,
                    mime: mime
                )
                DispatchQueue.main.async {
                    imageAttachments.append(attachment)
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private func handleMacOSPasteImages() -> Bool {
        let pasteboard = NSPasteboard.general
        let imageDataList = collectClipboardImageData(from: pasteboard, maxCount: maxImageAttachmentCount)
        guard !imageDataList.isEmpty else {
            return false
        }

        let remaining = max(0, maxImageAttachmentCount - imageAttachments.count)
        guard remaining > 0 else {
            return true
        }

        var appendedCount = 0
        for sourceData in imageDataList.prefix(remaining) {
            guard let jpegData = encodeClipboardImageAsJPEG(sourceData) else { continue }
            let suffix = UUID().uuidString.prefix(8)
            let filename = "clipboard_\(suffix).jpg"
            imageAttachments.append(
                ImageAttachment(
                    filename: filename,
                    data: jpegData,
                    mime: "image/jpeg"
                )
            )
            appendedCount += 1
        }

        return appendedCount > 0
    }

    private func collectClipboardImageData(from pasteboard: NSPasteboard, maxCount: Int) -> [Data] {
        var result: [Data] = []

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            for url in urls {
                guard isSupportedClipboardImageURL(url) else { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                result.append(data)
                if result.count >= maxCount {
                    return result
                }
            }
        }

        if let items = pasteboard.pasteboardItems, !items.isEmpty {
            let preferredTypes: [NSPasteboard.PasteboardType] = [
                .png,
                .tiff,
                NSPasteboard.PasteboardType("public.jpeg"),
                NSPasteboard.PasteboardType("public.heic"),
                NSPasteboard.PasteboardType("public.heif"),
                NSPasteboard.PasteboardType("com.compuserve.gif"),
                NSPasteboard.PasteboardType("org.webmproject.webp")
            ]

            for item in items {
                var appended = false
                for type in preferredTypes {
                    if let data = item.data(forType: type), !data.isEmpty {
                        result.append(data)
                        appended = true
                        break
                    }
                }
                if !appended,
                   let fileURLString = item.string(forType: .fileURL),
                   let url = URL(string: fileURLString),
                   isSupportedClipboardImageURL(url),
                   let data = try? Data(contentsOf: url) {
                    result.append(data)
                }
                if result.count >= maxCount {
                    return result
                }
            }
        }

        if result.isEmpty,
           let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in images {
                guard let tiffData = image.tiffRepresentation else { continue }
                result.append(tiffData)
                if result.count >= maxCount {
                    return result
                }
            }
        }

        return result
    }

    private func isSupportedClipboardImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let supported: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"
        ]
        return supported.contains(ext)
    }

    private func encodeClipboardImageAsJPEG(_ sourceData: Data) -> Data? {
        if let bitmap = NSBitmapImageRep(data: sourceData),
           let encoded = bitmap.representation(
               using: .jpeg,
               properties: [.compressionFactor: 0.85]
           ) {
            return encoded
        }

        guard let image = NSImage(data: sourceData),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let encoded = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.85]
              ) else {
            return nil
        }
        return encoded
    }
    #endif

    /// 根据文件头推断图片 MIME 与扩展名
    private func detectImageFileInfo(data: Data) -> (mime: String, ext: String) {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return ("image/png", "png")
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return ("image/jpeg", "jpg")
        }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return ("image/gif", "gif")
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return ("image/webp", "webp")
        }
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii)?.lowercased() ?? ""
            if brand.hasPrefix("hei") || brand.hasPrefix("hev") {
                return ("image/heic", "heic")
            }
            if brand == "mif1" || brand == "msf1" {
                return ("image/heif", "heif")
            }
        }
        return ("application/octet-stream", "bin")
    }

    private var dropdownPrimaryTextColor: Color {
        #if os(iOS)
        return .white
        #else
        return .primary
        #endif
    }

    private var dropdownSecondaryTextColor: Color {
        #if os(iOS)
        return .white.opacity(0.72)
        #else
        return .secondary
        #endif
    }

    private var selectorLabelMaxWidth: CGFloat {
        #if os(iOS)
        return 140
        #else
        return 180
        #endif
    }

    private var actionButtonDiameter: CGFloat {
        #if os(iOS)
        return 36
        #else
        return 28
        #endif
    }

    private var actionIconFontSize: CGFloat {
        #if os(iOS)
        return 16
        #else
        return 13
        #endif
    }

    // MARK: - 发送/停止按钮

    private var sendOrStopButton: some View {
        Group {
            if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: actionIconFontSize, weight: .bold))
                        .foregroundColor(canStopStreaming ? .white : .white.opacity(0.72))
                        .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                        .background(canStopStreaming ? Color.red : Color.gray.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canStopStreaming)
                .help(canStopStreaming ? "停止生成" : "会话创建中，暂不可停止")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: actionIconFontSize, weight: .bold))
                        .foregroundColor(canSend ? .white : .white.opacity(0.72))
                        .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                        .background(canSend ? Color.accentColor : Color.gray.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("发送")
            }
        }
    }
}

#Preview {
    VStack {
        ChatInputView(
            text: .constant("Hello"),
            imageAttachments: .constant([]),
            isStreaming: false,
            onSend: {},
            onStop: {},
            providers: [],
            selectedModel: .constant(nil),
            agents: [],
            selectedAgent: .constant(nil),
            autocomplete: nil,
            onSelectAutocomplete: nil,
            onInputContextChange: nil,
            cursorRectInInput: .constant(.zero)
        )

        ChatInputView(
            text: .constant(""),
            imageAttachments: .constant([]),
            isStreaming: true,
            onSend: {},
            onStop: {},
            providers: [],
            selectedModel: .constant(nil),
            agents: [],
            selectedAgent: .constant(nil),
            autocomplete: nil,
            onSelectAutocomplete: nil,
            onInputContextChange: nil,
            cursorRectInInput: .constant(.zero)
        )
    }
    .padding()
    .frame(width: 500)
}
