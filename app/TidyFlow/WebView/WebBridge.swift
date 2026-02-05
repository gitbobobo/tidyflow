import Foundation
import WebKit
import Combine
import AppKit

/// Bridge protocol for Native <-> Web communication
/// Native -> Web: tidyflow:open_file, tidyflow:save_file, tidyflow:enter_mode, tidyflow:terminal_ensure
/// Web -> Native: tidyflow:ready, tidyflow:saved, tidyflow:save_error, tidyflow:terminal_ready, tidyflow:terminal_error
class WebBridge: NSObject, WKScriptMessageHandler, ObservableObject {
    private weak var webView: WKWebView?

    // Callbacks for Web -> Native events
    var onReady: (([String: Any]) -> Void)?
    var onSaved: ((String) -> Void)?
    var onSaveError: ((String, String) -> Void)?

    // Phase C1-2: Terminal callbacks (with tabId)
    var onTerminalReady: ((String, String, String, String) -> Void)?  // tabId, session_id, project, workspace
    var onTerminalClosed: ((String, String, Int?) -> Void)?  // tabId, session_id, code
    var onTerminalError: ((String?, String) -> Void)?  // tabId (optional), error message
    var onTerminalConnected: (() -> Void)?

    // Phase C2-1: Diff callbacks
    var onOpenFile: ((String, String, Int?) -> Void)?  // workspace, path, line (optional)
    var onDiffError: ((String) -> Void)?  // error message

    // State
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

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            print("[WebBridge] Invalid message format")
            return
        }

        print("[WebBridge] Received: \(type)")

        switch type {
        case "ready":
            isWebReady = true
            let capabilities = body["capabilities"] as? [String] ?? []
            onReady?(["capabilities": capabilities])
            // Flush pending events
            flushPendingEvents()

        case "saved":
            if let path = body["path"] as? String {
                onSaved?(path)
            }

        case "save_error":
            let path = body["path"] as? String ?? ""
            let errorMsg = body["message"] as? String ?? "Unknown error"
            onSaveError?(path, errorMsg)

        // Phase C1-2: Terminal events (with tabId)
        case "terminal_ready":
            let tabId = body["tab_id"] as? String ?? ""
            let sessionId = body["session_id"] as? String ?? ""
            let project = body["project"] as? String ?? ""
            let workspace = body["workspace"] as? String ?? ""
            onTerminalReady?(tabId, sessionId, project, workspace)

        case "terminal_closed":
            let tabId = body["tab_id"] as? String ?? ""
            let sessionId = body["session_id"] as? String ?? ""
            let code = body["code"] as? Int
            onTerminalClosed?(tabId, sessionId, code)

        case "terminal_error":
            let tabId = body["tab_id"] as? String
            let errorMsg = body["message"] as? String ?? "Unknown error"
            onTerminalError?(tabId, errorMsg)

        case "terminal_connected":
            onTerminalConnected?()

        // Phase C2-1: Diff callbacks
        case "open_file_request":
            let workspace = body["workspace"] as? String ?? ""
            let path = body["path"] as? String ?? ""
            let line = body["line"] as? Int
            onOpenFile?(workspace, path, line)

        case "diff_error":
            let errorMsg = body["message"] as? String ?? "Unknown diff error"
            onDiffError?(errorMsg)

        // 剪贴板操作：终端选中文字自动复制
        case "clipboard_copy":
            if let text = body["text"] as? String, !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                print("[WebBridge] Copied to clipboard: \(text.prefix(50))...")
            }

        // 打开 URL：终端中 Command+Click 链接
        case "open_url":
            if let urlString = body["url"] as? String,
               let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                print("[WebBridge] Opening URL: \(urlString)")
            }

        default:
            print("[WebBridge] Unknown message type: \(type)")
        }
    }

    // MARK: - Native -> Web

    /// Send event to WebView
    func send(type: String, payload: [String: Any]) {
        if isWebReady {
            evaluateEvent(type: type, payload: payload)
        } else {
            // Queue event until web is ready
            pendingEvents.append((type: type, payload: payload))
            print("[WebBridge] Queued event: \(type) (web not ready)")
        }
    }

    private func flushPendingEvents() {
        for event in pendingEvents {
            evaluateEvent(type: event.type, payload: event.payload)
        }
        pendingEvents.removeAll()
        print("[WebBridge] Flushed \(pendingEvents.count) pending events")
    }

    private func evaluateEvent(type: String, payload: [String: Any]) {
        guard let webView = webView else {
            print("[WebBridge] No webView available")
            return
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            let escapedJson = jsonString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")

            let js = "window.tidyflowNative && window.tidyflowNative.receive('\(type)', '\(escapedJson)')"

            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("[WebBridge] JS error: \(error.localizedDescription)")
                }
            }
            print("[WebBridge] Sent: \(type)")
        } catch {
            print("[WebBridge] JSON serialization error: \(error)")
        }
    }

    // MARK: - Convenience Methods

    /// Set the WebSocket URL for the JavaScript side
    /// This must be called before the JavaScript connects to the WebSocket
    func setWsURL(port: Int) {
        guard let webView = webView else {
            print("[WebBridge] setWsURL: No webView available")
            return
        }
        let wsURL = AppConfig.makeWsURLString(port: port)
        let js = "window.TIDYFLOW_WS_URL = '\(wsURL)'; console.log('[NativeBridge] WebSocket URL set to:', window.TIDYFLOW_WS_URL);"
        print("[WebBridge] Setting WebSocket URL to: \(wsURL)")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("[WebBridge] setWsURL error: \(error.localizedDescription)")
            } else {
                print("[WebBridge] WebSocket URL set successfully")
            }
        }
    }

    /// UX-1: Enable renderer-only mode (hide Web's sidebar/tabbar/tools)
    func setRendererOnly(_ enabled: Bool) {
        guard let webView = webView else { return }
        let js = "window.setRendererOnly && window.setRendererOnly(\(enabled))"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("[WebBridge] setRendererOnly error: \(error.localizedDescription)")
            }
        }
    }

    func openFile(project: String, workspace: String, path: String) {
        send(type: "open_file", payload: [
            "project": project,
            "workspace": workspace,
            "path": path
        ])
    }

    // Phase C2-1.5: Reveal line in editor with highlight
    func editorRevealLine(path: String, line: Int, highlightMs: Int = 2000) {
        send(type: "editor_reveal_line", payload: [
            "path": path,
            "line": line,
            "highlightMs": highlightMs
        ])
    }

    func saveFile(project: String, workspace: String, path: String) {
        send(type: "save_file", payload: [
            "project": project,
            "workspace": workspace,
            "path": path
        ])
    }

    // MARK: - Phase C1-2: Terminal Methods (Multi-Session)

    /// Enter a specific mode (editor or terminal)
    func enterMode(_ mode: String, project: String? = nil, workspace: String? = nil) {
        var payload: [String: Any] = ["mode": mode]
        if let project = project {
            payload["project"] = project
        }
        if let workspace = workspace {
            payload["workspace"] = workspace
        }
        send(type: "enter_mode", payload: payload)
    }

    /// Spawn a new terminal session for a tab
    func terminalSpawn(project: String, workspace: String, tabId: String) {
        print("[WebBridge] terminalSpawn called: project=\(project), workspace=\(workspace), tabId=\(tabId)")
        send(type: "terminal_spawn", payload: [
            "project": project,
            "workspace": workspace,
            "tab_id": tabId
        ])
    }

    /// Attach to an existing terminal session
    func terminalAttach(tabId: String, sessionId: String) {
        send(type: "terminal_attach", payload: [
            "tab_id": tabId,
            "session_id": sessionId
        ])
    }

    /// Kill a terminal session
    func terminalKill(tabId: String, sessionId: String) {
        send(type: "terminal_kill", payload: [
            "tab_id": tabId,
            "session_id": sessionId
        ])
    }

    /// Send input to a terminal session (for executing custom commands)
    func terminalSendInput(sessionId: String, input: String) {
        send(type: "terminal_input", payload: [
            "session_id": sessionId,
            "input": input
        ])
    }

    /// Legacy: Ensure a terminal exists for the given workspace (for backward compatibility)
    func terminalEnsure(project: String, workspace: String) {
        send(type: "terminal_ensure", payload: [
            "project": project,
            "workspace": workspace
        ])
    }

    // MARK: - Terminal Refresh

    /// 刷新当前活跃的终端，用于解决应用切换后的花屏问题
    func refreshActiveTerminal() {
        guard let webView = webView else { return }
        let js = "window.TidyFlowApp && window.TidyFlowApp.refreshActiveTerminal && window.TidyFlowApp.refreshActiveTerminal()"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("[WebBridge] refreshActiveTerminal error: \(error.localizedDescription)")
            }
        }
    }

    /// 刷新所有终端的 WebGL 状态，用于处理全局的 WebGL context 问题
    func refreshAllTerminals() {
        guard let webView = webView else { return }
        let js = "window.TidyFlowApp && window.TidyFlowApp.refreshAllTerminals && window.TidyFlowApp.refreshAllTerminals()"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("[WebBridge] refreshAllTerminals error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Phase C2-1: Diff Methods

    /// Open a diff view for a file
    func diffOpen(project: String, workspace: String, path: String, mode: String) {
        send(type: "diff_open", payload: [
            "project": project,
            "workspace": workspace,
            "path": path,
            "mode": mode
        ])
    }

    /// Set diff mode (working/staged) for current diff
    func diffSetMode(mode: String) {
        send(type: "diff_set_mode", payload: [
            "mode": mode
        ])
    }

    // MARK: - Bridge Script Injection

    /// Returns the JavaScript to inject into WKWebView for bridge setup
    static var bridgeScript: String {
        """
        (function() {
            // Native bridge object
            window.tidyflowNative = {
                // Called by Native to send events to Web
                receive: function(type, payloadJson) {
                    try {
                        const payload = JSON.parse(payloadJson);
                        console.log('[NativeBridge] Received:', type, payload);

                        if (window.tidyflowNative.onEvent) {
                            window.tidyflowNative.onEvent(type, payload);
                        }
                    } catch (e) {
                        console.error('[NativeBridge] Parse error:', e);
                    }
                },

                // Called by Web to send events to Native
                post: function(type, payload) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tidyflowBridge) {
                        window.webkit.messageHandlers.tidyflowBridge.postMessage({
                            type: type,
                            ...payload
                        });
                    } else {
                        console.warn('[NativeBridge] No message handler available');
                    }
                },

                // Event handler (set by main.js)
                onEvent: null
            };

            console.log('[NativeBridge] Bridge initialized');
        })();
        """
    }
}
