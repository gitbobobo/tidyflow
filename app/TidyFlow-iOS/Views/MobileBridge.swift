import Foundation
import WebKit
import os

/// iOS 版 Native ↔ JS 桥接，仅处理终端相关事件
/// JS → Native: ready, terminal_data, terminal_resized, open_url
/// Native → JS: write_output, resize, write_input
@MainActor
final class MobileBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?

    // 回调
    var onReady: ((Int, Int) -> Void)?          // cols, rows
    var onTerminalData: ((String) -> Void)?      // 用户输入
    var onTerminalResized: ((Int, Int) -> Void)? // cols, rows
    var onOpenURL: ((String) -> Void)?

    // 状态
    private(set) var isWebReady = false
    private var pendingEvents: [(type: String, payload: [String: Any])] = []

    override init() {
        super.init()
    }

    func setWebView(_ webView: WKWebView) {
        self.webView = webView
        isWebReady = false
        pendingEvents.removeAll()
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }
        Task { @MainActor in
            self.handleMessage(type: type, body: body)
        }
    }

    private func handleMessage(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            isWebReady = true
            let cols = body["cols"] as? Int ?? 80
            let rows = body["rows"] as? Int ?? 24
            onReady?(cols, rows)
            flushPendingEvents()

        case "terminal_data":
            if let data = body["data"] as? String {
                onTerminalData?(data)
            }

        case "terminal_resized":
            let cols = body["cols"] as? Int ?? 80
            let rows = body["rows"] as? Int ?? 24
            onTerminalResized?(cols, rows)

        case "open_url":
            if let url = body["url"] as? String {
                onOpenURL?(url)
            }

        default:
            break
        }
    }

    // MARK: - Native → JS

    /// 写入终端输出（二进制数据 Base64 编码）
    func writeOutput(_ bytes: [UInt8]) {
        let base64 = Data(bytes).base64EncodedString()
        send(type: "write_output", payload: ["base64": base64])
    }

    /// 通知 JS 执行 resize
    func triggerResize() {
        send(type: "resize", payload: [:])
    }

    /// 直接写入输入数据到终端显示（特殊键等）
    func writeInput(_ data: String) {
        send(type: "write_input", payload: ["data": data])
    }

    func send(type: String, payload: [String: Any]) {
        if isWebReady {
            evaluateEvent(type: type, payload: payload)
        } else {
            pendingEvents.append((type: type, payload: payload))
        }
    }

    private func flushPendingEvents() {
        let events = pendingEvents
        pendingEvents.removeAll()
        for event in events {
            evaluateEvent(type: event.type, payload: event.payload)
        }
    }

    private func evaluateEvent(type: String, payload: [String: Any]) {
        guard let webView = webView else { return }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            let base64String = jsonData.base64EncodedString()
            let js = "window.tidyflowMobile && window.tidyflowMobile.receiveBase64('\(type)', '\(base64String)')"
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    os_log(.error, "[MobileBridge] JS error for %{public}@: %{public}@", type, error.localizedDescription)
                }
            }
        } catch {
            os_log(.error, "[MobileBridge] JSON error: %{public}@", error.localizedDescription)
        }
    }

    // MARK: - Bridge Script

    static var bridgeScript: String {
        """
        (function() {
            // 确保 tidyflowMobile 对象存在（mobile-terminal.js 会覆盖）
            if (!window.tidyflowMobile) {
                window.tidyflowMobile = {
                    receiveBase64: function(type, base64) {
                        console.warn('[MobileBridge] receiveBase64 called before init');
                    }
                };
            }
        })();
        """
    }
}