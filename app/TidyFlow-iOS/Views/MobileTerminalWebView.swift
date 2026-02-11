import SwiftUI
import WebKit

/// WKWebView 包装，加载 mobile-terminal.html
struct MobileTerminalWebView: UIViewRepresentable {
    let bridge: MobileBridge

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
