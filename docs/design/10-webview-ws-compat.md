# WKWebView WebSocket Compatibility

## Configuration Applied

### Info.plist (App Transport Security)
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSExceptionDomains</key>
    <dict>
        <key>127.0.0.1</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
        <key>localhost</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
    </dict>
</dict>
```

### Entitlements
- `com.apple.security.app-sandbox`: **false** (disabled for local development)
- `com.apple.security.network.client`: **true** (allows outgoing network connections)

## WebSocket Compatibility

| Feature | Status | Notes |
|---------|--------|-------|
| `ws://127.0.0.1:47999/ws` | ✅ Works | With ATS exceptions above |
| `ws://localhost:47999/ws` | ✅ Works | With ATS exceptions above |
| WebSocket in WKWebView | ✅ Works | Standard WebSocket API available |
| Local file loading | ✅ Works | Using `loadFileURL` with read access |

## WebGL Addon Compatibility

| Feature | Status | Notes |
|---------|--------|-------|
| WebGL in WKWebView | ✅ Works | Hardware accelerated on macOS |
| xterm-addon-webgl | ✅ Works | Falls back to DOM renderer on failure |
| Context loss handling | ✅ Handled | Auto-dispose on context loss |

## Known Issues & Mitigations

1. **Sandbox Mode**: App sandbox is disabled for development. For production, enable sandbox and add specific entitlements for network access.

2. **WebSocket URL Configuration**: The WebSocket URL is injected from Swift after page load. If the page loads before Swift injects the URL, it uses the default `ws://127.0.0.1:47999/ws`.

3. **Cross-Origin Restrictions**: WKWebView enforces CORS. Since we load local files and connect to localhost, this is not an issue.

4. **WebGL Fallback**: If WebGL context creation fails (rare on modern Macs), the terminal automatically falls back to DOM rendering with a console warning.

5. **Reconnection**: On disconnect, the user must click "Reconnect" button. Auto-reconnect is not implemented to avoid connection storms.

## Plan B: WKScriptMessageHandler Bridge

If WebSocket connections fail in future macOS versions, the `WebSocketTransport` class in `main.js` can be replaced with a `NativeBridgeTransport` that uses `WKScriptMessageHandler`:

```javascript
class NativeBridgeTransport {
    constructor(callbacks) {
        this.callbacks = callbacks;
        window.tidyflowBridge = {
            onMessage: (data) => this.callbacks.onMessage(data),
            onOpen: () => this.callbacks.onOpen(),
            onClose: () => this.callbacks.onClose(),
            onError: (e) => this.callbacks.onError(e),
        };
    }

    connect() {
        webkit.messageHandlers.tidyflow.postMessage({ type: 'connect' });
    }

    send(data) {
        webkit.messageHandlers.tidyflow.postMessage({ type: 'send', data });
    }
}
```

Swift side would then manage the actual WebSocket connection and relay messages via `evaluateJavaScript`.

## Verification Checklist

- [x] ATS configured for localhost
- [x] Entitlements allow network client
- [x] WebSocket connects from WKWebView
- [x] WebGL addon loads (with fallback)
- [x] Resize events propagate correctly
- [x] Base64 encoding/decoding works
