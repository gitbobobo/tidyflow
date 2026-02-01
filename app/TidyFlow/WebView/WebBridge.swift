import Foundation
import WebKit
import Combine

/// Bridge protocol for Native <-> Web communication
/// Native -> Web: tidyflow:open_file, tidyflow:save_file
/// Web -> Native: tidyflow:ready, tidyflow:saved, tidyflow:save_error
class WebBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?

    // Callbacks for Web -> Native events
    var onReady: (([String: Any]) -> Void)?
    var onSaved: ((String) -> Void)?
    var onSaveError: ((String, String) -> Void)?

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

    func openFile(project: String, workspace: String, path: String) {
        send(type: "open_file", payload: [
            "project": project,
            "workspace": workspace,
            "path": path
        ])
    }

    func saveFile(project: String, workspace: String, path: String) {
        send(type: "save_file", payload: [
            "project": project,
            "workspace": workspace,
            "path": path
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
