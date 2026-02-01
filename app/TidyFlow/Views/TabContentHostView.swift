import SwiftUI

struct TabContentHostView: View {
    @EnvironmentObject var appState: AppState
    let webBridge: WebBridge
    @Binding var webViewVisible: Bool

    var body: some View {
        Group {
            if let workspaceKey = appState.selectedWorkspaceKey,
               let activeId = appState.activeTabIdByWorkspace[workspaceKey],
               let tabs = appState.workspaceTabs[workspaceKey],
               let activeTab = tabs.first(where: { $0.id == activeId }) {

                switch activeTab.kind {
                case .terminal:
                    TerminalPlaceholderView()
                case .editor:
                    EditorContentView(
                        path: activeTab.payload,
                        webBridge: webBridge,
                        webViewVisible: $webViewVisible
                    )
                case .diff:
                    DiffPlaceholderView(path: activeTab.payload)
                }

            } else {
                VStack {
                    Spacer()
                    Text("No Active Tab")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Editor Content View (WebView + Status Bar)

struct EditorContentView: View {
    let path: String
    let webBridge: WebBridge
    @Binding var webViewVisible: Bool
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // WebView container (managed by parent CenterContentView)
            // This view just shows the status bar overlay
            ZStack {
                // Placeholder shown while WebView loads
                if !appState.editorWebReady {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading editor...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
                } else {
                    // WebView is visible and ready - show transparent overlay
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status bar
            EditorStatusBar(path: path)
        }
        .onAppear {
            webViewVisible = true
            // Send open_file event when editor tab becomes active
            if appState.editorWebReady {
                sendOpenFile()
            }
        }
        .onDisappear {
            webViewVisible = false
        }
        .onChange(of: appState.editorWebReady) { ready in
            if ready {
                sendOpenFile()
            }
        }
        .onChange(of: path) { newPath in
            if appState.editorWebReady {
                sendOpenFile()
            }
        }
    }

    private func sendOpenFile() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        webBridge.openFile(
            project: appState.selectedProjectName,
            workspace: ws,
            path: path
        )
        appState.lastEditorPath = path
    }
}

// MARK: - Editor Status Bar

struct EditorStatusBar: View {
    let path: String
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            // File path
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Status indicator
            if !appState.editorStatus.isEmpty {
                Text(appState.editorStatus)
                    .font(.system(size: 11))
                    .foregroundColor(appState.editorStatusIsError ? .red : .green)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Placeholder Views

struct TerminalPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack {
                Text("Terminal Placeholder")
                    .font(.monospaced(.body)())
                    .foregroundColor(.green)
                Text("(WebView will be embedded here in Phase B-3)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
}

struct DiffPlaceholderView: View {
    let path: String
    var body: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)
            VStack {
                Image(systemName: "arrow.left.arrow.right.circle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Diff Placeholder")
                    .font(.headline)
                Text(path)
                    .font(.monospaced(.caption)())
                Text("(working / staged)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
