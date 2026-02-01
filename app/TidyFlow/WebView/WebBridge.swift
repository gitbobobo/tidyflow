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
}
