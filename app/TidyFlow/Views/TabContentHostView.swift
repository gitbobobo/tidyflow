import SwiftUI

struct TabContentHostView: View {
    @EnvironmentObject var appState: AppState
    let webBridge: WebBridge
    @Binding var webViewVisible: Bool

    /// 是否有需要展示 WebView 的活跃 tab（只读，用于驱动 webViewVisible）
    private var hasActiveContent: Bool {
        // 使用全局工作空间键来访问 tabs（区分不同项目的同名工作空间）
        guard let globalKey = appState.currentGlobalWorkspaceKey,
              let activeId = appState.activeTabIdByWorkspace[globalKey],
              let tabs = appState.workspaceTabs[globalKey],
              tabs.first(where: { $0.id == activeId }) != nil
        else { return false }
        return true
    }

    var body: some View {
        Group {
            // 使用全局工作空间键来访问 tabs（区分不同项目的同名工作空间）
            if let globalKey = appState.currentGlobalWorkspaceKey,
               let activeId = appState.activeTabIdByWorkspace[globalKey],
               let tabs = appState.workspaceTabs[globalKey],
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
                    .id(activeTab.payload) // 不同 path 视为不同 View，确保切换时触发 onAppear
                case .diff:
                    DiffContentView(
                        path: activeTab.payload,
                        webBridge: webBridge,
                        webViewVisible: $webViewVisible
                    )
                case .settings:
                    // 设置页面不需要 WebView
                    SettingsContentView()
                        .environmentObject(appState)
                        .onAppear { webViewVisible = false }
                }

            } else if appState.currentGlobalWorkspaceKey != nil {
                // 已选择工作空间但没有活跃 Tab，显示快捷操作视图
                QuickActionsView()
            } else {
                NoActiveTabView()
            }
        }
        .onAppear { webViewVisible = hasActiveContent }
        .onChange(of: hasActiveContent) { _, newValue in webViewVisible = newValue }
    }
}

// MARK: - No Active Tab View（空白提示视图）

struct NoActiveTabView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundColor(.secondary.opacity(0.6))

            Text("选择或添加项目开始")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            Text("在左侧边栏选择项目和工作区，或使用 ⌘⇧P 添加新项目")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: {
                appState.addProjectSheetPresented = true
            }) {
                Label("添加项目", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
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
                        Text("加载中")
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
            // webViewVisible 由 TabContentHostView 管理，不在子视图中设置
            // Switch back to editor mode when leaving terminal
            if appState.editorWebReady {
                webBridge.enterMode("editor")
            }
        }
        .onChange(of: appState.editorWebReady) { _, ready in
            if ready {
                sendTerminalMode()
            }
        }
        .onChange(of: appState.activeTabIdByWorkspace) { _, _ in
            // Detect tab switch within terminal tabs
            if let tab = appState.getActiveTab(), tab.kind == .terminal {
                if currentTabId != tab.id {
                    currentTabId = tab.id
                    handleTabSwitch(tab)
                }
            }
        }
        .onChange(of: appState.currentGlobalWorkspaceKey) { _, newGlobalKey in
            // 当全局工作空间键切换时（包括项目切换），重新发送 terminal mode 命令
            guard let newGlobalKey = newGlobalKey else { return }
            guard appState.editorWebReady else { return }
            guard let tab = appState.getActiveTab(), tab.kind == .terminal else { return }
            
            print("[TerminalContentView] global workspace key changed to: \(newGlobalKey), re-sending terminal mode")
            currentTabId = tab.id
            sendTerminalMode()
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
        
        // 如果这个 Tab 正在 pending spawn，跳过（避免重复 spawn）
        if appState.pendingSpawnTabs.contains(tab.id) {
            return
        }

        let sessionId = appState.getTerminalSessionId(for: tab.id)

        // Phase C1-2: Switch to this tab's session
        if let sessionId = sessionId {
            // 使用回调而不是直接调用，确保使用正确的 WebBridge 实例
            appState.onTerminalAttach?(tab.id.uuidString, sessionId)
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
            // 延后到下一 run loop 再发，确保 activeTabIdByWorkspace 已更新（避免切换 tab 时 guard 读到旧值）
            if appState.editorWebReady {
                DispatchQueue.main.async { sendOpenFile() }
            }
        }
        .onDisappear {
            // webViewVisible 由 TabContentHostView 管理，不在子视图中设置
        }
        .onChange(of: appState.editorWebReady) { _, ready in
            if ready {
                DispatchQueue.main.async { sendOpenFile() }
            }
        }
        .onChange(of: path) { _, newPath in
            if appState.editorWebReady {
                DispatchQueue.main.async { sendOpenFile() }
            }
        }
        .onChange(of: appState.currentGlobalWorkspaceKey) { _, newGlobalKey in
            // 当全局工作空间键切换时（包括项目切换），重新加载编辑器内容
            // 即使文件路径相同，不同工作空间的文件内容可能不同
            guard newGlobalKey != nil else { return }
            guard appState.editorWebReady else { return }
            DispatchQueue.main.async { sendOpenFile() }
        }
    }

    private func sendOpenFile() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        // 仅当当前活跃的 editor tab 仍是本 path 时才发送，避免切换 tab 后旧视图仍触发 sendOpenFile 导致乱序
        guard appState.getActiveTab()?.kind == .editor && appState.getActiveTab()?.payload == path else { return }
        // 先切换到编辑器模式，否则 Web 端可能仍在 terminal/diff 模式，编辑器 pane 被隐藏
        webBridge.enterMode("editor", project: appState.selectedProjectName, workspace: ws)
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
// WebView-based Diff View

struct DiffContentView: View {
    let path: String
    let webBridge: WebBridge
    @Binding var webViewVisible: Bool
    @EnvironmentObject var appState: AppState

    @State private var currentMode: DiffMode = .working

    var body: some View {
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
        .onChange(of: appState.editorWebReady) { _, ready in
            if ready {
                sendDiffOpen()
            }
        }
        .onChange(of: path) { _, _ in
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

        // Send the command to WebView
        guard let ws = appState.selectedWorkspaceKey else { return }
        webBridge.diffOpen(
            project: appState.selectedProjectName,
            workspace: ws,
            path: path,
            mode: newMode.rawValue
        )
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
