import SwiftUI
import WebKit

struct WebViewContainer: NSViewRepresentable {
    let bridge: WebBridge
    @Binding var isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeNSView(context: Context) -> WKWebView {
        // Configure WKWebView with bridge
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        // Inject bridge script at document start
        let bridgeScript = WKUserScript(
            source: WebBridge.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(bridgeScript)

        // Register message handler for Web -> Native communication
        userContentController.add(bridge, name: "tidyflowBridge")

        config.userContentController = userContentController

        // Enable developer extras for debugging
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        bridge.setWebView(webView)

        // Load the index.html from the bundle
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("""
                <html><body style="background:#1e1e1e;color:#d4d4d4;font-family:system-ui;">
                <h1>Web Resource Not Found</h1>
                <p>Please check if 'Web' folder is added to the target resources.</p>
                </body></html>
            """, baseURL: nil)
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Visibility is handled by parent view's opacity/hidden state
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let bridge: WebBridge

        init(bridge: WebBridge) {
            self.bridge = bridge
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[WebViewContainer] Page loaded")
            // Web will send 'ready' event when tidyflowNative.onEvent is set up
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[WebViewContainer] Navigation failed: \(error.localizedDescription)")
        }
    }
}
