import SwiftUI
import UIKit

/// 终端原生输入代理 —— 使用 UIKeyInput 直接捕获 iOS 键盘输入，
/// 绕过 WKWebView textarea 的兼容性问题
final class TerminalInputView: UIView, UIKeyInput {
    var onInput: ((String) -> Void)?

    // MARK: - UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" {
            onInput?("\r")
        } else {
            onInput?(text)
        }
    }

    func deleteBackward() {
        onInput?("\u{7f}")
    }

    // MARK: - First Responder

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Touch 处理

    /// 已聚焦时穿透触摸到下层 WKWebView（滚动、链接点击等）；
    /// 未聚焦时拦截触摸以重新获取焦点弹出键盘
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isFirstResponder { return nil }
        return super.hitTest(point, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    // MARK: - UITextInputTraits

    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default
}

/// SwiftUI 包装，覆盖在 WKWebView 上方捕获键盘输入
struct TerminalInputProxy: UIViewRepresentable {
    let onInput: (String) -> Void

    func makeUIView(context: Context) -> TerminalInputView {
        let view = TerminalInputView()
        view.backgroundColor = .clear
        view.onInput = onInput
        // 延迟弹出键盘，等待视图布局完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: TerminalInputView, context: Context) {}
}
