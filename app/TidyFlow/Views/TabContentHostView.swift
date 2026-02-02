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
                    // Phase C1-1: Show WebView for terminal tabs
                    TerminalContentView(
                        webBridge: webBridge,
                        webViewVisible: $webViewVisible
                    )
                case .editor:
                    EditorContentView(
                        path: activeTab.payload,
                        webBridge: webBridge,
                        webViewVisible: $webViewVisible
                    )
                case .diff:
                    DiffContentView(
                        path: activeTab.payload,
                        webBridge: webBridge,
                        webViewVisible: $webViewVisible
                    )
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

// MARK: - Phase C1-2: Terminal Content View (WebView + Status Bar, Multi-Session)

struct TerminalContentView: View {
    let webBridge: WebBridge
    @Binding var webViewVisible: Bool
    @EnvironmentObject var appState: AppState

    // Track the current tab to detect tab switches
    @State private var currentTabId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // WebView container (managed by parent CenterContentView)
            ZStack {
                // Show loading or error state
                if !appState.editorWebReady {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading terminal...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                } else if case .error(let message) = appState.terminalState {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Terminal Error")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.gray)
                        Button("Reconnect") {
                            appState.wsClient.reconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                } else {
                    // WebView is visible and ready - show transparent overlay
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .onAppear {
            print("[TerminalContentView] onAppear - setting webViewVisible = true")
            webViewVisible = true
            // Send enter_mode and terminal commands when terminal tab becomes active
            if appState.editorWebReady {
                print("[TerminalContentView] editorWebReady is true, sending terminal mode")
                sendTerminalMode()
            } else {
                print("[TerminalContentView] editorWebReady is false, waiting...")
            }
        }
        .onDisappear {
            webViewVisible = false
            // Switch back to editor mode when leaving terminal
            if appState.editorWebReady {
                webBridge.enterMode("editor")
            }
        }
        .onChange(of: appState.editorWebReady) { ready in
            if ready {
                sendTerminalMode()
            }
        }
        .onChange(of: appState.activeTabIdByWorkspace) { _ in
            // Detect tab switch within terminal tabs
            if let tab = appState.getActiveTab(), tab.kind == .terminal {
                if currentTabId != tab.id {
                    currentTabId = tab.id
                    handleTabSwitch(tab)
                }
            }
        }
    }

    private func sendTerminalMode() {
        guard let tab = appState.getActiveTab(), tab.kind == .terminal else { return }
        guard let ws = appState.selectedWorkspaceKey else { return }

        currentTabId = tab.id
        // 传递 project 和 workspace 以便 JavaScript 端更新当前工作空间
        webBridge.enterMode("terminal", project: appState.selectedProjectName, workspace: ws)

        // Phase C1-2: Check if this tab has a session
        if let sessionId = appState.getTerminalSessionId(for: tab.id) {
            // Attach to existing session
            webBridge.terminalAttach(tabId: tab.id.uuidString, sessionId: sessionId)
        } else if appState.terminalNeedsRespawn(tab.id) {
            // Respawn session (was stale or never had one)
            appState.staleTerminalTabs.remove(tab.id)
            webBridge.terminalSpawn(
                project: appState.selectedProjectName,
                workspace: ws,
                tabId: tab.id.uuidString
            )
        } else {
            // New tab, spawn session
            webBridge.terminalSpawn(
                project: appState.selectedProjectName,
                workspace: ws,
                tabId: tab.id.uuidString
            )
        }
        appState.requestTerminal()
    }

    private func handleTabSwitch(_ tab: TabModel) {
        guard appState.editorWebReady else { return }
        guard let ws = appState.selectedWorkspaceKey else { return }

        // Phase C1-2: Switch to this tab's session
        if let sessionId = appState.getTerminalSessionId(for: tab.id) {
            webBridge.terminalAttach(tabId: tab.id.uuidString, sessionId: sessionId)
        } else {
            // No session, spawn new one
            webBridge.terminalSpawn(
                project: appState.selectedProjectName,
                workspace: ws,
                tabId: tab.id.uuidString
            )
        }
    }
}

// MARK: - Terminal Status Bar

struct TerminalStatusBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            // Terminal indicator
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundColor(.green)

            // Session info
            switch appState.terminalState {
            case .idle:
                Text("Terminal")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            case .connecting:
                Text("Connecting...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.orange)
            case .ready(let sessionId):
                Text("Session: \(sessionId.prefix(8))...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            case .error(let message):
                Text("Error: \(message)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red)
            }

            Spacer()

            // Connection status
            Circle()
                .fill(appState.connectionState == .connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
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

        // Phase C2-1.5: Check for pending line reveal
        if let reveal = appState.pendingEditorReveal, reveal.path == path {
            // Delay slightly to ensure file is loaded
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak appState, weak webBridge] in
                guard let appState = appState, let webBridge = webBridge else { return }
                if let reveal = appState.pendingEditorReveal, reveal.path == path {
                    webBridge.editorRevealLine(path: reveal.path, line: reveal.line, highlightMs: reveal.highlightMs)
                    appState.pendingEditorReveal = nil
                }
            }
        }
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

// MARK: - Phase C2-1: Diff Content View (WebView + Mode Toggle)
// Phase C2-2a: Updated to use Native Diff by default

struct DiffContentView: View {
    let path: String
    let webBridge: WebBridge
    @Binding var webViewVisible: Bool
    @EnvironmentObject var appState: AppState

    @State private var currentMode: DiffMode = .working
    @State private var currentViewMode: DiffViewMode = .unified

    var body: some View {
        Group {
            if appState.useNativeDiff {
                // Phase C2-2a/C2-2b: Native diff rendering with split view support
                NativeDiffView(
                    path: path,
                    currentMode: $currentMode,
                    currentViewMode: $currentViewMode,
                    onModeChange: handleModeChange,
                    onViewModeChange: handleViewModeChange,
                    onLineClick: handleLineClick
                )
                .onAppear {
                    webViewVisible = false  // Hide WebView for native diff
                    currentMode = appState.activeDiffMode
                    currentViewMode = appState.activeDiffViewMode
                }
            } else {
                // Legacy: WebView-based diff (fallback)
                webDiffContent
            }
        }
    }

    // MARK: - Legacy WebView Diff Content

    private var webDiffContent: some View {
        VStack(spacing: 0) {
            // Diff toolbar with mode toggle
            DiffToolbar(currentMode: $currentMode, onModeChange: handleModeChange)

            // WebView container
            ZStack {
                if !appState.editorWebReady {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading diff viewer...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status bar
            DiffStatusBar(path: path, mode: currentMode)
        }
        .onAppear {
            webViewVisible = true
            // Initialize mode from tab
            currentMode = appState.activeDiffMode
            if appState.editorWebReady {
                sendDiffOpen()
            }
        }
        .onDisappear {
            webViewVisible = false
        }
        .onChange(of: appState.editorWebReady) { ready in
            if ready {
                sendDiffOpen()
            }
        }
        .onChange(of: path) { _ in
            if appState.editorWebReady {
                sendDiffOpen()
            }
        }
    }

    private func sendDiffOpen() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        webBridge.enterMode("diff")
        webBridge.diffOpen(
            project: appState.selectedProjectName,
            workspace: ws,
            path: path,
            mode: currentMode.rawValue
        )
    }

    private func handleModeChange(_ newMode: DiffMode) {
        guard newMode != currentMode else { return }
        currentMode = newMode
        appState.setActiveDiffMode(newMode)

        // For native diff, the view will auto-reload via onChange
        // For web diff, send the command
        if !appState.useNativeDiff {
            guard let ws = appState.selectedWorkspaceKey else { return }
            webBridge.diffOpen(
                project: appState.selectedProjectName,
                workspace: ws,
                path: path,
                mode: newMode.rawValue
            )
        }
    }

    // Phase C2-2b: Handle view mode change (unified/split)
    private func handleViewModeChange(_ newViewMode: DiffViewMode) {
        guard newViewMode != currentViewMode else { return }
        currentViewMode = newViewMode
        appState.setActiveDiffViewMode(newViewMode)
    }

    // Phase C2-2a: Handle line click to navigate to editor
    private func handleLineClick(_ line: Int) {
        guard let ws = appState.selectedWorkspaceKey else { return }

        // Open or activate editor tab and navigate to line
        appState.addEditorTab(workspaceKey: ws, path: path, line: line)
    }
}

// MARK: - Diff Toolbar

struct DiffToolbar: View {
    @Binding var currentMode: DiffMode
    let onModeChange: (DiffMode) -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Mode toggle (Working / Staged)
            Picker("", selection: Binding(
                get: { currentMode },
                set: { onModeChange($0) }
            )) {
                Text("Working").tag(DiffMode.working)
                Text("Staged").tag(DiffMode.staged)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .help("Working: unstaged changes (git diff)\nStaged: staged changes (git diff --cached)")

            Spacer()

            // Info text
            Text("Click a line to open in editor")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Diff Status Bar

struct DiffStatusBar: View {
    let path: String
    let mode: DiffMode

    var body: some View {
        HStack {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11))
                .foregroundColor(.orange)

            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(mode == .working ? "Working Changes" : "Staged Changes")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
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
                Text("(Legacy - should not appear)")
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
