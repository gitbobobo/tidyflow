import SwiftUI
import WebKit

struct ContentView: View {
    @State private var connectionStatus: String = "Disconnected"
    @State private var webView: WKWebView?

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack {
                Circle()
                    .fill(connectionStatus == "Connected" ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(connectionStatus)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Reconnect") {
                    webView?.evaluateJavaScript("window.tidyflow?.reconnect()")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            // Terminal WebView
            TerminalWebView(connectionStatus: $connectionStatus, webView: $webView)
        }
        .background(Color.black)
    }
}

struct TerminalWebView: NSViewRepresentable {
    @Binding var connectionStatus: String
    @Binding var webView: WKWebView?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Allow local file access
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Set up message handler for Swift-JS communication
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "tidyflow")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Load local HTML
        if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        DispatchQueue.main.async {
            self.webView = webView
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: TerminalWebView

        init(_ parent: TerminalWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            DispatchQueue.main.async {
                switch type {
                case "connected":
                    self.parent.connectionStatus = "Connected"
                case "disconnected":
                    self.parent.connectionStatus = "Disconnected"
                case "error":
                    self.parent.connectionStatus = "Error"
                default:
                    break
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject WebSocket URL from environment or default
            let wsPort = ProcessInfo.processInfo.environment["TIDYFLOW_PORT"] ?? "47999"
            let wsURL = "ws://127.0.0.1:\(wsPort)/ws"
            webView.evaluateJavaScript("window.TIDYFLOW_WS_URL = '\(wsURL)'; window.tidyflow?.connect();")
        }
    }
}

#Preview {
    ContentView()
}
