# Native Shell - Phase A: Skeleton

## Context
We are migrating TidyFlow from a pure Web-based shell to a Native macOS Shell using SwiftUI. This transition is done in phases to maintain stability while building up the native capabilities.

## Phase A: Skeleton
**Goal**: Establish the minimal native structure without disrupting existing Web logic.

### Scope
1.  **3-Column Layout**:
    - Left Sidebar: Workspaces/Projects (Mock data)
    - Center Content: WKWebView (Loading existing Web app)
    - Right Panel: Tool container (Explorer/Search/Git icons, empty content)
2.  **Native Toolbar**:
    - Connection Status (Connected/Disconnected)
    - Project Selector (Mock)
3.  **Architecture**:
    - `AppState` (ObservableObject): Single source of truth for shell state.
    - `WebBridge`: Placeholder for Swift <-> JS communication.
    - `WebViewContainer`: NSViewRepresentable wrapper for WKWebView.

### Why Phased?
- **Risk Mitigation**: Avoid breaking the working Web app by keeping it running inside the WebView.
- **Incremental Value**: We get a native frame immediately, then gradually move features (Tabs, Command Palette, File Explorer) from Web to Native.

## Next Steps (Phase B & C)
- **Phase B**: Native Tabs & Command Palette.
    - Move tab management out of WebView into native SwiftUI.
    - Implement native Command Palette (Cmd+P/Shift+Cmd+P).
- **Phase C**: Native Right Panel Tools.
    - Implement real File Explorer using Rust Core.
    - Implement native Search and Git panels.
