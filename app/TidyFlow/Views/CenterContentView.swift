import SwiftUI

struct CenterContentView: View {
    @EnvironmentObject var appState: AppState
    let webBridge: WebBridge
    @State private var webViewVisible: Bool = false

    var body: some View {
        ZStack {
            // WebView layer - visible when editor tab is active
            WebViewContainer(bridge: webBridge, isVisible: $webViewVisible)
                .opacity(shouldShowWebView ? 1 : 0)
                .allowsHitTesting(shouldShowWebView)

            // Native UI layer
            if appState.selectedWorkspaceKey != nil {
                VStack(spacing: 0) {
                    TabStripView()
                    Divider()
                    TabContentHostView(
                        webBridge: webBridge,
                        webViewVisible: $webViewVisible
                    )
                }
                .background(shouldShowWebView ? Color.clear : Color(NSColor.windowBackgroundColor))
            } else {
                VStack {
                    Spacer()
                    Text("No Workspace Selected")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .onAppear {
            setupBridgeCallbacks()
            setupSaveNotification()
        }
    }

    /// Whether to show WebView (editor tab is active and web is ready)
    private var shouldShowWebView: Bool {
        webViewVisible && appState.isActiveTabEditor && appState.editorWebReady
    }

    /// Setup WebBridge callbacks
    private func setupBridgeCallbacks() {
        webBridge.onReady = { [weak appState] info in
            DispatchQueue.main.async {
                appState?.editorWebReady = true
                print("[CenterContentView] Web ready with capabilities: \(info)")
            }
        }

        webBridge.onSaved = { [weak appState] path in
            DispatchQueue.main.async {
                appState?.handleEditorSaved(path: path)
            }
        }

        webBridge.onSaveError = { [weak appState] path, message in
            DispatchQueue.main.async {
                appState?.handleEditorSaveError(path: path, message: message)
            }
        }
    }

    /// Setup notification listener for save command
    private func setupSaveNotification() {
        NotificationCenter.default.addObserver(
            forName: .saveEditorFile,
            object: nil,
            queue: .main
        ) { [weak appState] notification in
            guard let path = notification.object as? String,
                  let ws = appState?.selectedWorkspaceKey,
                  let project = appState?.selectedProjectName else { return }

            webBridge.saveFile(project: project, workspace: ws, path: path)
        }
    }
}
