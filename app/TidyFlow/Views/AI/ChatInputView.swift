import SwiftUI
#if os(macOS)
import AppKit

// MARK: - 支持 IME 的聊天输入框（NSTextView 包装）

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
            if tv.hasMarkedText() { return }
            if context.coordinator.parent.isEnterEnabled() {
                context.coordinator.parent.onEnter()
            }
        }
        textView.onArrowUp = { context.coordinator.parent.onArrowUp?() ?? false }
        textView.onArrowDown = { context.coordinator.parent.onArrowDown?() ?? false }
        textView.onEscape = { context.coordinator.parent.onEscape?() ?? false }
        textView.onTab = { context.coordinator.parent.onTab?() ?? false }

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // 初始高度
        DispatchQueue.main.async {
            context.coordinator.updateHeight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
            // 程序化设置文本后，光标移到末尾
            let endPos = (text as NSString).length
            textView.setSelectedRange(NSRange(location: endPos, length: 0))
            context.coordinator.updateHeight()
            context.coordinator.updateCursorRect()
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
            parent.text = textView.string
            updateHeight()
            updateCursorRect()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateCursorRect()
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
    }
}

/// 自定义 NSTextView，在 keyDown 层拦截 Enter 并兼容 IME
private class IMEAwareTextView: NSTextView {
    var onEnter: (() -> Void)?
    var onArrowUp: (() -> Bool)?
    var onArrowDown: (() -> Bool)?
    var onEscape: (() -> Bool)?
    var onTab: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        // IME 组合态，全部交给系统处理
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        let isShift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 36: // Return
            if !isShift {
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
        super.keyDown(with: event)
    }
}
#endif

struct ChatInputView: View {
    @Binding var text: String
    @Binding var imageAttachments: [ImageAttachment]
    var isStreaming: Bool
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
    /// 光标位置（外部读取用于定位弹出层）
    @Binding var cursorRectInInput: CGRect

    @FocusState private var isFocused: Bool
    @State private var textContentHeight: CGFloat = 28
    /// 光标在输入框内的位置（由 NSTextView 上报）
    @State private var cursorRect: CGRect = .zero

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // 图片缩略图预览行
            if !imageAttachments.isEmpty {
                imagePreviewRow
            }

            // 输入区域
            inputEditor

            // 工具栏
            toolbar
        }
        .padding(12)
        .onChange(of: cursorRect) { _, newRect in
            cursorRectInInput = newRect
        }
    }

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
                Text("输入消息...  @ 引用文件  / 斜杠命令")
                    .foregroundColor(.secondary.opacity(0.6))
                    .font(.system(size: 13))
                    .padding(.horizontal, 5)
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
                    // 弹出层可见时，Enter 选择当前项
                    if let ac = autocomplete, ac.isVisible, let item = ac.selectedItem {
                        onSelectAutocomplete?(item)
                        return
                    }
                    if canSend && !isStreaming {
                        onSend()
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
                }
            )
            .frame(height: min(max(textContentHeight, 28), 80))
            #else
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 36, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
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
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // MARK: - 模型选择按钮

    private var modelButton: some View {
        Group {
            if !providers.isEmpty {
                Menu {
                    ForEach(providers) { provider in
                        Section(provider.name) {
                            ForEach(provider.models) { model in
                                Button(action: {
                                    selectedModel = AIModelSelection(providerID: provider.id, modelID: model.id)
                                }) {
                                    Text(model.name)
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
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
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

    // MARK: - 图片上传按钮

    private var imageUploadButton: some View {
        Button(action: pickImage) {
            Image(systemName: "photo")
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .help("上传图片")
    }

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

    // MARK: - 发送/停止按钮

    private var sendOrStopButton: some View {
        Group {
            if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("停止生成")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(canSend ? .accentColor : .gray)
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
            cursorRectInInput: .constant(.zero)
        )
    }
    .padding()
    .frame(width: 500)
}
