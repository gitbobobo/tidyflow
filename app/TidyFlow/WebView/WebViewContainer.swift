import SwiftUI
import WebKit

struct WebViewContainer: NSViewRepresentable {
    let bridge: WebBridge
    
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        bridge.setWebView(webView)
        
        // Load the index.html from the bundle
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // Fallback if file not found (e.g. during development/preview)
            webView.loadHTMLString("<html><body><h1>Web Resource Not Found</h1><p>Please check if 'Web' folder is added to the target resources.</p></body></html>", baseURL: nil)
        }
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Handle updates if necessary
    }
}
