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
                case .aiChat:
                    // AI Chat Tab (Native SwiftUI)
                    AITabView()
                        .environmentObject(appState)
                        .environmentObject(appState.fileCache)
                        .onAppear { webViewVisible = false }
                case .evolution:
                    EvolutionTabView()
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

            Text("tabContent.selectOrAdd".localized)
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            Text("tabContent.selectOrAdd.hint".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: {
                appState.addProjectSheetPresented = true
            }) {
                Label("tabContent.addProject".localized, systemImage: "plus.circle.fill")
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
                        Text("common.loading".localized)
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
            webViewVisible = true
            // Send enter_mode and terminal commands when terminal tab becomes active
            if appState.editorWebReady {
                sendTerminalMode()
            }
        }
        .onDisappear {
            // webViewVisible 由 TabContentHostView 管理，不在子视图中设置
            // 如果下一个活跃 tab 仍是终端，跳过模式切换，避免 terminal→editor→terminal 闪烁
            if appState.editorWebReady {
                if let nextTab = appState.getActiveTab(), nextTab.kind == .terminal {
                    // 终端间切换，不切换模式
                } else {
                    webBridge.enterMode("editor")
                }
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
            guard newGlobalKey != nil else { return }
            guard appState.editorWebReady else { return }
            guard let tab = appState.getActiveTab(), tab.kind == .terminal else { return }

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
        } else if appState.staleTerminalTabs.contains(tab.id),
                  let sessionId = tab.terminalSessionId, !sessionId.isEmpty {
            // Stale tab 且有 terminalSessionId → 尝试通过服务端 attach（WS 重连场景）
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

private struct EvolutionEditableProfile: Identifiable {
    let id: String
    let stage: String
    var aiTool: AIChatTool
    var mode: String
    var providerID: String
    var modelID: String
}

struct EvolutionTabView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var maxVerifyIterationsText: String = "3"
    @State private var autoLoopEnabled: Bool = true
    @State private var editableProfiles: [EvolutionEditableProfile] = []
    @State private var isApplyingRemoteProfiles: Bool = false
    @State private var lastSyncedProfileSignature: String = ""
    @State private var pendingProfileSaveSignature: String?
    @State private var pendingProfileSaveDate: Date?
    @State private var hasPendingUserProfileEdit: Bool = false

    private var project: String { appState.selectedProjectName }
    private var workspace: String? { appState.selectedWorkspaceKey }
    private var workspaceReady: Bool { workspace != nil && !(workspace ?? "").isEmpty }

    private var currentItem: EvolutionWorkspaceItemV2? {
        guard let workspace else { return nil }
        return appState.evolutionItem(project: project, workspace: workspace)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    schedulerCard
                    workspaceCard
                    stageSectionsCard
                }
                .padding(16)
            }
        }
        .onAppear {
            refreshData()
            syncStartOptionsFromCurrentItem()
        }
        .onChange(of: appState.selectedWorkspaceKey) { _, _ in
            refreshData()
            syncStartOptionsFromCurrentItem()
        }
        .onChange(of: appState.selectedProjectName) { _, _ in
            refreshData()
            syncStartOptionsFromCurrentItem()
        }
        .onChange(of: appState.connectionState) { _, state in
            guard state == .connected else { return }
            refreshData()
        }
        .onReceive(appState.$evolutionStageProfilesByWorkspace) { _ in
            syncProfilesFromState()
        }
        .onReceive(appState.$evolutionWorkspaceItems) { _ in
            syncStartOptionsFromCurrentItem()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("自主进化")
                .font(.headline)
            Spacer()
            Button("刷新") {
                refreshData()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var schedulerCard: some View {
        GroupBox("调度器状态") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("激活状态") {
                    Text(appState.evolutionScheduler.activationState)
                }
                LabeledContent("并发上限") {
                    Text("\(appState.evolutionScheduler.maxParallelWorkspaces)")
                }
                LabeledContent("运行中 / 排队") {
                    Text("\(appState.evolutionScheduler.runningCount) / \(appState.evolutionScheduler.queuedCount)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var workspaceCard: some View {
        GroupBox("工作空间控制") {
            VStack(alignment: .leading, spacing: 12) {
                if let workspace {
                    LabeledContent("当前工作空间") {
                        Text("\(project)/\(workspace)")
                    }
                    if let item = currentItem {
                        LabeledContent("状态") {
                            Text(item.status)
                        }
                        LabeledContent("当前阶段") {
                            Text(item.currentStage)
                        }
                        LabeledContent("轮次") {
                            Text("\(item.globalLoopRound)")
                        }
                        LabeledContent("校验轮次") {
                            Text("\(item.verifyIteration)/\(item.verifyIterationLimit)")
                        }
                        LabeledContent("活跃代理") {
                            Text(item.activeAgents.isEmpty ? "无" : item.activeAgents.joined(separator: ", "))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else {
                        Text("状态: 未启动")
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 12) {
                        TextField("最大 verify 次数", text: $maxVerifyIterationsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Toggle("循环续轮", isOn: $autoLoopEnabled)
                            .toggleStyle(.switch)
                    }

                    ControlGroup {
                        Button("手动启动") {
                            startCurrentWorkspace()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("停止") {
                            appState.stopEvolution(project: project, workspace: workspace)
                        }
                        Button("恢复") {
                            appState.resumeEvolution(project: project, workspace: workspace)
                        }
                    }

                    Text(autoLoopEnabled ? "运行模式: 自动循环续轮" : "运行模式: 仅运行 1 轮后结束")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("请先选择工作空间")
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stageSectionsCard: some View {
        GroupBox("代理类型") {
            VStack(alignment: .leading, spacing: 12) {
                Text("按代理类型配置 AI 工具 / 模式 / 模型；运行中或已完成的代理可进入聊天详情。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if editableProfiles.isEmpty {
                    Text("暂无阶段配置")
                        .foregroundColor(.secondary)
                } else {
                    ForEach($editableProfiles) { $profile in
                        stageSection(profile: $profile)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stageSection(profile: Binding<EvolutionEditableProfile>) -> some View {
        let stage = profile.wrappedValue.stage
        let runtime = runtimeAgent(for: stage)
        let statusText = runtime?.status ?? "未启动"
        let aiToolBinding = Binding<AIChatTool>(
            get: { profile.wrappedValue.aiTool },
            set: { newValue in
                guard profile.wrappedValue.aiTool != newValue else { return }
                hasPendingUserProfileEdit = true
                profile.wrappedValue.aiTool = newValue
                sanitizeProfileSelection(profileID: profile.wrappedValue.id)
                autoSaveProfilesIfNeeded()
            }
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text(sectionTitle(for: profile.wrappedValue, runtime: runtime))
                .font(.headline)

            Text("代理类型: \(stage)")
                .font(.caption)
                .foregroundColor(.secondary)

            LabeledContent("工作状态") {
                if canOpenStageChat(statusText) {
                    Button {
                        openStageChat(stage: stage)
                    } label: {
                        HStack(spacing: 4) {
                            Text(statusText)
                                .foregroundColor(stageStatusColor(statusText))
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(statusText)
                        .foregroundColor(stageStatusColor(statusText))
                }
            }

            LabeledContent("AI 工具") {
                Picker("", selection: aiToolBinding) {
                    ForEach(AIChatTool.allCases) { tool in
                        Text(tool.displayName).tag(tool)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            LabeledContent("模式") {
                Menu {
                    Button("默认模式") {
                        hasPendingUserProfileEdit = true
                        profile.wrappedValue.mode = ""
                        autoSaveProfilesIfNeeded()
                    }
                    let options = modeOptions(for: profile.wrappedValue.aiTool)
                    if options.isEmpty {
                        Text("暂无可用模式")
                    } else {
                        ForEach(options, id: \.self) { option in
                            Button(option) {
                                hasPendingUserProfileEdit = true
                                profile.wrappedValue.mode = option
                                applyAgentDefaultModelIfAvailable(
                                    profileID: profile.wrappedValue.id,
                                    agentName: option
                                )
                                autoSaveProfilesIfNeeded()
                            }
                        }
                    }
                } label: {
                    Text(profile.wrappedValue.mode.isEmpty ? "默认模式" : profile.wrappedValue.mode)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
            }

            LabeledContent("模型") {
                Menu {
                    Button("默认模型") {
                        hasPendingUserProfileEdit = true
                        profile.wrappedValue.providerID = ""
                        profile.wrappedValue.modelID = ""
                        autoSaveProfilesIfNeeded()
                    }
                    let providers = modelProviders(for: profile.wrappedValue.aiTool)
                    if providers.isEmpty {
                        Text("暂无可用模型")
                    } else if providers.count <= 1 {
                        if let onlyProvider = providers.first {
                            ForEach(onlyProvider.models) { model in
                                Button(model.name) {
                                    hasPendingUserProfileEdit = true
                                    profile.wrappedValue.providerID = onlyProvider.id
                                    profile.wrappedValue.modelID = model.id
                                    autoSaveProfilesIfNeeded()
                                }
                            }
                        }
                    } else {
                        ForEach(providers) { provider in
                            Menu(provider.name) {
                                ForEach(provider.models) { model in
                                    Button(model.name) {
                                        hasPendingUserProfileEdit = true
                                        profile.wrappedValue.providerID = provider.id
                                        profile.wrappedValue.modelID = model.id
                                        autoSaveProfilesIfNeeded()
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text(selectedModelDisplayName(for: profile.wrappedValue))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func refreshData() {
        appState.requestEvolutionSnapshot()
        if let workspace {
            appState.requestEvolutionSelectorResourcesThenProfile(project: project, workspace: workspace)
        }
        syncProfilesFromState()
    }

    private func runtimeAgent(for stage: String) -> EvolutionAgentInfoV2? {
        currentItem?.agents.first { $0.stage == stage }
    }

    private func stageStatusColor(_ status: String) -> Color {
        switch normalizedStageStatus(status) {
        case "running":
            return .orange
        case "completed":
            return .green
        default:
            return .secondary
        }
    }

    private func canOpenStageChat(_ status: String) -> Bool {
        let normalized = normalizedStageStatus(status)
        return normalized == "running" || normalized == "completed"
    }

    private func normalizedStageStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func sectionTitle(for profile: EvolutionEditableProfile, runtime: EvolutionAgentInfoV2?) -> String {
        let runtimeAgent = runtime?.agent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !runtimeAgent.isEmpty { return runtimeAgent }
        let configuredMode = profile.mode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredMode.isEmpty { return configuredMode }
        return profile.stage
    }

    private func openStageChat(stage: String) {
        guard let item = currentItem else { return }
        appState.openEvolutionStageChat(
            project: item.project,
            workspace: item.workspace,
            cycleId: item.cycleID,
            stage: stage
        )
        openWindow(id: "evolution-stage-chat")
    }

    private func modeOptions(for tool: AIChatTool) -> [String] {
        // 与聊天输入框一致：mode 选择来自动态 agent.name 列表，而不是 agent.mode 分组字段。
        var seen: Set<String> = []
        var values: [String] = []
        for agent in appState.aiAgents(for: tool) {
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard seen.insert(name).inserted else { continue }
            values.append(name)
        }
        return values
    }

    private func applyAgentDefaultModelIfAvailable(profileID: String, agentName: String) {
        guard let index = editableProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        var profile = editableProfiles[index]
        let target = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        let agent = appState.aiAgents(for: profile.aiTool).first { info in
            info.name == target || info.name.caseInsensitiveCompare(target) == .orderedSame
        }
        guard let agent,
              let providerID = agent.defaultProviderID,
              let modelID = agent.defaultModelID,
              !providerID.isEmpty,
              !modelID.isEmpty else { return }

        // 与聊天输入框保持一致：选中 agent 后直接切换到其默认模型。
        profile.providerID = providerID
        profile.modelID = modelID
        editableProfiles[index] = profile
    }

    private func modelProviders(for tool: AIChatTool) -> [AIProviderInfo] {
        appState.aiProviders(for: tool).filter { !$0.models.isEmpty }
    }

    private func selectedModelDisplayName(for profile: EvolutionEditableProfile) -> String {
        guard !profile.providerID.isEmpty, !profile.modelID.isEmpty else {
            return "默认模型"
        }
        for provider in modelProviders(for: profile.aiTool) {
            if provider.id == profile.providerID,
               let model = provider.models.first(where: { $0.id == profile.modelID }) {
                return model.name
            }
        }
        return profile.modelID
    }

    private func sanitizeProfileSelection(profileID: String) {
        guard let index = editableProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        var profile = editableProfiles[index]

        if !profile.mode.isEmpty {
            let modes = modeOptions(for: profile.aiTool)
            if !modes.isEmpty, !modes.contains(profile.mode) {
                profile.mode = ""
            }
        }

        if !profile.providerID.isEmpty || !profile.modelID.isEmpty {
            let providers = modelProviders(for: profile.aiTool)
            let modelExists = providers.contains { provider in
                provider.id == profile.providerID &&
                    provider.models.contains(where: { $0.id == profile.modelID })
            }
            if !providers.isEmpty, !modelExists {
                profile.providerID = ""
                profile.modelID = ""
            }
        }

        editableProfiles[index] = profile
    }

    private func buildStageProfilesForSubmit() -> [EvolutionStageProfileInfoV2] {
        editableProfiles.map { item in
            var mode: String?
            if !item.mode.isEmpty {
                let modes = modeOptions(for: item.aiTool)
                if modes.isEmpty || modes.contains(item.mode) {
                    mode = item.mode
                }
            }

            let model: EvolutionModelSelectionV2? = {
                guard !item.providerID.isEmpty, !item.modelID.isEmpty else { return nil }
                return EvolutionModelSelectionV2(providerID: item.providerID, modelID: item.modelID)
            }()

            return EvolutionStageProfileInfoV2(
                stage: item.stage,
                aiTool: item.aiTool,
                mode: mode,
                model: model
            )
        }
    }

    private func syncProfilesFromState() {
        guard let workspace else {
            editableProfiles = []
            isApplyingRemoteProfiles = false
            lastSyncedProfileSignature = ""
            pendingProfileSaveSignature = nil
            pendingProfileSaveDate = nil
            hasPendingUserProfileEdit = false
            return
        }
        let profiles = appState.evolutionProfiles(project: project, workspace: workspace)
        let loadedProfiles = profiles.map { profile in
            EvolutionEditableProfile(
                id: profile.stage,
                stage: profile.stage,
                aiTool: profile.aiTool,
                mode: profile.mode ?? "",
                providerID: profile.model?.providerID ?? "",
                modelID: profile.model?.modelID ?? ""
            )
        }
        let incomingSignature = profileSignature(loadedProfiles)
        if shouldIgnoreIncomingProfiles(signature: incomingSignature) {
            return
        }

        isApplyingRemoteProfiles = true
        editableProfiles = loadedProfiles
        lastSyncedProfileSignature = profileSignature(editableProfiles)
        if pendingProfileSaveSignature == lastSyncedProfileSignature {
            pendingProfileSaveSignature = nil
            pendingProfileSaveDate = nil
        }
        hasPendingUserProfileEdit = false
        DispatchQueue.main.async {
            isApplyingRemoteProfiles = false
        }
    }

    private func saveProfiles() {
        guard let workspace else { return }
        let profiles = buildStageProfilesForSubmit()
        appState.updateEvolutionAgentProfile(project: project, workspace: workspace, profiles: profiles)
    }

    private func autoSaveProfilesIfNeeded() {
        guard workspaceReady, !isApplyingRemoteProfiles else { return }
        guard hasPendingUserProfileEdit else { return }
        let signature = profileSignature(editableProfiles)
        guard signature != lastSyncedProfileSignature else {
            hasPendingUserProfileEdit = false
            return
        }
        guard signature != pendingProfileSaveSignature else { return }
        pendingProfileSaveSignature = signature
        pendingProfileSaveDate = Date()
        hasPendingUserProfileEdit = false
        saveProfiles()
    }

    private func shouldIgnoreIncomingProfiles(signature: String) -> Bool {
        guard let pending = pendingProfileSaveSignature else { return false }
        guard pending != signature else { return false }

        let timeout: TimeInterval = 3
        if let date = pendingProfileSaveDate, Date().timeIntervalSince(date) < timeout {
            return true
        }

        pendingProfileSaveSignature = nil
        pendingProfileSaveDate = nil
        return false
    }

    private func profileSignature(_ values: [EvolutionEditableProfile]) -> String {
        values
            .sorted { $0.stage < $1.stage }
            .map {
                [
                    $0.stage,
                    $0.aiTool.rawValue,
                    $0.mode,
                    $0.providerID,
                    $0.modelID
                ].joined(separator: "::")
            }
            .joined(separator: "||")
    }

    private func startCurrentWorkspace() {
        guard let workspace else { return }
        let verify = max(1, Int(maxVerifyIterationsText) ?? 3)
        let profiles = buildStageProfilesForSubmit()
        appState.startEvolution(
            project: project,
            workspace: workspace,
            maxVerifyIterations: verify,
            autoLoopEnabled: autoLoopEnabled,
            profiles: profiles
        )
    }

    private func syncStartOptionsFromCurrentItem() {
        guard let item = currentItem else { return }
        autoLoopEnabled = item.autoLoopEnabled
    }
}

struct EvolutionStageChatWindowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var replayStore: AIChatStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(appState.evolutionReplayTitle.isEmpty ? "阶段聊天" : appState.evolutionReplayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("清空") {
                    appState.clearEvolutionReplay()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                if appState.evolutionReplayLoading {
                    ProgressView("加载聊天记录中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if let error = appState.evolutionReplayError, !error.isEmpty {
                    Text(error)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(20)
                } else if replayStore.messages.isEmpty {
                    Text("暂无阶段聊天内容")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    MessageListView(
                        messages: replayStore.messages,
                        onQuestionReply: { _, _ in },
                        onQuestionReject: { _ in },
                        onQuestionReplyAsMessage: { _ in }
                    )
                    .environmentObject(replayStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.windowBackgroundColor))
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}
