import SwiftUI
import WebKit
import ObjectiveC

/// WKWebView 包装，加载 mobile-terminal.html
struct MobileTerminalWebView: UIViewRepresentable {
    let bridge: MobileBridge
    let onKey: (String) -> Void
    let onCtrlArmedChanged: (Bool) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // 注入桥接脚本
        let bridgeScript = WKUserScript(
            source: MobileBridge.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(bridgeScript)
        config.userContentController.add(bridge, name: "tidyflowMobile")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false

        bridge.setWebView(webView)

        // 替换 WKContentView 的 inputAccessoryView
        replaceInputAccessoryView(
            in: webView,
            onKey: onKey,
            onCtrlArmedChanged: onCtrlArmedChanged
        )

        // 加载 mobile-terminal.html
        if let htmlURL = Bundle.main.url(forResource: "mobile-terminal", withExtension: "html", subdirectory: "Web") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        // 监听键盘事件
        context.coordinator.setupKeyboardObservers(webView: webView, bridge: bridge)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.removeKeyboardObservers()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "tidyflowMobile")
    }

    // MARK: - 替换 inputAccessoryView

    /// 查找 WKContentView 并通过 ObjC runtime 替换其 inputAccessoryView
    private func replaceInputAccessoryView(
        in webView: WKWebView,
        onKey: @escaping (String) -> Void,
        onCtrlArmedChanged: @escaping (Bool) -> Void
    ) {
        guard let contentView = findWKContentView(in: webView) else { return }

        let accessory = TerminalInputAccessoryView(
            frame: CGRect(x: 0, y: 0, width: webView.bounds.width, height: 44)
        )
        accessory.onKey = onKey
        accessory.onCtrlArmedChanged = onCtrlArmedChanged

        // 用关联对象持有 accessory，防止被释放
        objc_setAssociatedObject(
            contentView, &AssociatedKeys.accessoryView, accessory, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        // 替换 inputAccessoryView getter
        let selector = #selector(getter: UIResponder.inputAccessoryView)
        guard let originalMethod = class_getInstanceMethod(type(of: contentView), selector) else { return }

        let block: @convention(block) (AnyObject) -> UIView? = { _ in accessory }
        let imp = imp_implementationWithBlock(block)
        method_setImplementation(originalMethod, imp)
    }

    private func findWKContentView(in webView: WKWebView) -> UIView? {
        for subview in webView.scrollView.subviews {
            if String(describing: type(of: subview)).hasPrefix("WKContentView") {
                return subview
            }
        }
        return nil
    }

    class Coordinator {
        private var keyboardObservers: [NSObjectProtocol] = []
        private weak var webView: WKWebView?
        private weak var bridge: MobileBridge?

        func setupKeyboardObservers(webView: WKWebView, bridge: MobileBridge) {
            self.webView = webView
            self.bridge = bridge

            let showObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidShowNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                // 键盘弹出后触发 fit
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.bridge?.triggerResize()
                }
            }

            let hideObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidHideNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.bridge?.triggerResize()
                }
            }

            keyboardObservers = [showObserver, hideObserver]
        }

        func removeKeyboardObservers() {
            for observer in keyboardObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            keyboardObservers.removeAll()
        }

        deinit {
            removeKeyboardObservers()
        }
    }
}

// MARK: - 关联对象 Key

private enum AssociatedKeys {
    static var accessoryView: UInt8 = 0
}
