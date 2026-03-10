import SwiftUI

#if os(iOS)
import UIKit
#if canImport(PhotosUI)
import PhotosUI
#endif
#endif
#if os(macOS)
import AppKit
#endif

@inline(__always)
func imeDebugLog(_ message: String) {
    #if DEBUG
    TFLog.log(TFLog.app, category: "ime", level: "DEBUG", "[ChatInputView] \(message)")
    #endif
}

#if os(macOS)

// MARK: - 支持 IME 的聊天输入框（NSTextView 包装）

struct ChatTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    /// 光标相对于 ScrollView 的位置（用于定位弹出层）
    @Binding var cursorRect: CGRect
    var focusRequestToken: Int = 0
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
            let composing = textView.hasMarkedText() || ((textView as? IMEAwareTextView)?.isIMEComposing == true)
            // 输入被外部清空时，优先复位底层 NSTextView，避免残留旧内容“挂”在顶部。
            if composing && !text.isEmpty { return }
            if composing && text.isEmpty {
                textView.unmarkText()
            }
            textView.string = text
            // 程序化设置文本后，光标移到末尾
            let endPos = (text as NSString).length
            textView.setSelectedRange(NSRange(location: endPos, length: 0))
            if text.isEmpty {
                context.coordinator.resetScrollPosition(in: scrollView)
            }
            context.coordinator.updateHeight()
            context.coordinator.updateCursorRect()
            context.coordinator.reportInputContext()
        }
        textView.font = font
        if context.coordinator.lastFocusRequestToken != focusRequestToken {
            context.coordinator.lastFocusRequestToken = focusRequestToken
            DispatchQueue.main.async {
                guard textView.window != nil else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextView
        weak var textView: NSTextView?
        var lastFocusRequestToken: Int

        init(_ parent: ChatTextView) {
            self.parent = parent
            self.lastFocusRequestToken = parent.focusRequestToken
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
            guard let textView = textView else { return }
            guard !textView.string.isEmpty,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                DispatchQueue.main.async {
                    self.parent.cursorRect = .zero
                }
                return
            }
            layoutManager.ensureLayout(for: textContainer)
            let insertionPoint = textView.selectedRange().location
            guard insertionPoint != NSNotFound else { return }
            let charIndex = min(insertionPoint, textView.string.count - 1)
            let numberOfGlyphs = layoutManager.numberOfGlyphs
            guard numberOfGlyphs > 0 else {
                DispatchQueue.main.async {
                    self.parent.cursorRect = .zero
                }
                return
            }
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
                    self.parent.cursorRect = CGRect(
                        x: pointInScroll.x,
                        y: pointInScroll.y,
                        width: 1,
                        height: lineRect.height
                    )
                }
            }
        }

        func resetScrollPosition(in scrollView: NSScrollView) {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
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

// MARK: - 自定义 NSTextView，在 keyDown 层拦截 Enter 并兼容 IME
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
struct IOSAutoFocusTextField: UIViewRepresentable {
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
