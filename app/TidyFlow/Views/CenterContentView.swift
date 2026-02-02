import SwiftUI

struct CenterContentView: View {
    @EnvironmentObject var appState: AppState
    let webBridge: WebBridge
    @State private var webViewVisible: Bool = false

    var body: some View {
        ZStack {
            // WebView layer - visible when editor or terminal tab is active
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
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Select a workspace to start")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Click a workspace in the left sidebar")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 60)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .onAppear {
            setupBridgeCallbacks()
            setupSaveNotification()
        }
    }

    /// Whether to show WebView (editor, terminal, or diff tab is active and web is ready)
    private var shouldShowWebView: Bool {
        webViewVisible && (appState.isActiveTabEditor || appState.isActiveTabTerminal || appState.isActiveTabDiff) && appState.editorWebReady
    }

    /// Setup WebBridge callbacks
    private func setupBridgeCallbacks() {
        webBridge.onReady = { [weak appState, weak webBridge] info in
            DispatchQueue.main.async {
                appState?.editorWebReady = true
                // UX-1: Enable renderer-only mode when Web is ready
                webBridge?.setRendererOnly(true)
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

        // Phase C1-2: Terminal callbacks (with tabId)
        webBridge.onTerminalReady = { [weak appState] tabId, sessionId, project, workspace in
            DispatchQueue.main.async {
                appState?.handleTerminalReady(tabId: tabId, sessionId: sessionId, project: project, workspace: workspace)
            }
        }

        webBridge.onTerminalClosed = { [weak appState] tabId, sessionId, code in
            DispatchQueue.main.async {
                appState?.handleTerminalClosed(tabId: tabId, sessionId: sessionId, code: code)
            }
        }

        webBridge.onTerminalError = { [weak appState] tabId, message in
            DispatchQueue.main.async {
                appState?.handleTerminalError(tabId: tabId, message: message)
            }
        }

        webBridge.onTerminalConnected = { [weak appState] in
            DispatchQueue.main.async {
                appState?.handleTerminalConnected()
            }
        }

        // Phase C1-2: Set terminal kill callback
        appState.onTerminalKill = { [weak webBridge] tabId, sessionId in
            webBridge?.terminalKill(tabId: tabId, sessionId: sessionId)
        }

        // Set Core ready callback to update WebBridge with the port
        appState.onCoreReadyWithPort = { [weak webBridge] port in
            print("[CenterContentView] Core ready on port \(port), setting WebSocket URL")
            webBridge?.setWsURL(port: port)
        }

        // If Core is already running, set the WebSocket URL now
        if let port = appState.coreProcessManager.currentPort {
            print("[CenterContentView] Core already running on port \(port), setting WebSocket URL")
            webBridge.setWsURL(port: port)
        }

        // Phase C2-1: Diff callbacks (extended C2-1.5 for line navigation)
        webBridge.onOpenFile = { [weak appState, weak webBridge] workspace, path, line in
            DispatchQueue.main.async {
                guard let appState = appState else { return }
                // Open file in editor tab with optional line
                appState.addEditorTab(workspaceKey: workspace, path: path, line: line)
                print("[CenterContentView] Opening file from diff: \(path), line: \(line ?? 0)")
            }
        }

        webBridge.onDiffError = { [weak appState] message in
            DispatchQueue.main.async {
                print("[CenterContentView] Diff error: \(message)")
                // Could show an alert or update status
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
