import Foundation
import WebKit

class WebBridge {
    private weak var webView: WKWebView?
    
    init() {}
    
    func setWebView(_ webView: WKWebView) {
        self.webView = webView
    }
    
    func send(eventName: String, payload: String) {
        print("[WebBridge] Sending event: \(eventName), payload: \(payload)")
        // In the future, this will evaluate JavaScript in the WebView
        // webView?.evaluateJavaScript("window.receiveEvent('\(eventName)', '\(payload)')")
    }
    
    // Phase B-1 Placeholders
    func openTerminal(workspaceKey: String) {
        print("[WebBridge] openTerminal workspace=\(workspaceKey)")
    }
    
    func openFile(workspaceKey: String, path: String) {
        print("[WebBridge] openFile workspace=\(workspaceKey) path=\(path)")
    }
    
    func openDiff(workspaceKey: String, path: String, mode: String) {
        print("[WebBridge] openDiff workspace=\(workspaceKey) path=\(path) mode=\(mode)")
    }
}
