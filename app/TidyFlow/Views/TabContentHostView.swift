import SwiftUI
import AppKit

struct TabContentHostView: View {
    @EnvironmentObject var appState: AppState
    let webBridge: WebBridge
    @Binding var webViewVisible: Bool

    /// 是否有需要展示 WebView 的活跃 tab（只读，用于驱动 webViewVisible）
    private var hasActiveContent: Bool {
        // 使用全局工作空间键来访问 tabs（区分不同项目的同名工作空间）
        guard let globalKey = appState.currentGlobalWorkspaceKey,
              appState.workspaceSpecialPageByWorkspace[globalKey] == nil,
              let activeId = appState.activeTabIdByWorkspace[globalKey],
              let tabs = appState.workspaceTabs[globalKey],
              let tab = tabs.first(where: { $0.id == activeId })
        else { return false }
        return tab.kind == .terminal
    }

    var body: some View {
        Group {
            // 使用全局工作空间键来访问 tabs（区分不同项目的同名工作空间）
            if let globalKey = appState.currentGlobalWorkspaceKey {
                if let specialPage = appState.workspaceSpecialPageByWorkspace[globalKey] {
                    switch specialPage {
                    case .aiChat:
                        AITabView()
                            .environmentObject(appState)
                            .environmentObject(appState.fileCache)
                            .onAppear { webViewVisible = false }
                    case .evolution:
                        EvolutionTabView()
                            .environmentObject(appState)
                            .onAppear { webViewVisible = false }
                    }
                } else if let activeId = appState.activeTabIdByWorkspace[globalKey],
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
                        NativeEditorContentView(
                            path: activeTab.payload,
                            webViewVisible: $webViewVisible
                        )
                        .id(activeTab.payload) // 不同 path 视为不同 View，确保切换时触发 onAppear
                    case .diff:
                        NativeDiffContentView(
                            path: activeTab.payload,
                            webViewVisible: $webViewVisible
                        )
                    case .settings:
                        // 设置页面不需要 WebView
                        SettingsContentView()
                            .environmentObject(appState)
                            .onAppear { webViewVisible = false }
                    }
                } else {
                    // 已选择工作空间但没有活跃 Tab，显示快捷操作视图
                    QuickActionsView()
                }
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
            // Web 侧已 terminal-only，无需在离开时切回 editor 模式
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
        // 若已由 Native 侧主动触发 spawn，跳过本次，避免重复创建会话
        if appState.pendingSpawnTabs.contains(tab.id) {
            appState.requestTerminal()
            return
        }

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

// MARK: - 原生 Editor Content View

struct NativeEditorContentView: View {
    let path: String
    @Binding var webViewVisible: Bool
    @EnvironmentObject var appState: AppState
    @State private var highlightedLine: Int?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let globalKey = appState.currentGlobalWorkspaceKey,
                   let doc = appState.getEditorDocument(globalWorkspaceKey: globalKey, path: path) {
                    switch doc.status {
                    case .loading:
                        ProgressView("Loading editor...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .error(let message):
                        Text(message)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .idle, .ready:
                        NativeCodeEditorView(
                            text: editorBinding(globalKey: globalKey),
                            highlightedLine: $highlightedLine
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ProgressView("Loading editor...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            EditorStatusBar(path: path)
        }
        .onAppear {
            webViewVisible = false
            openDocumentIfNeeded(force: false)
            consumePendingRevealIfNeeded()
        }
        .onChange(of: appState.currentGlobalWorkspaceKey) { _, _ in
            openDocumentIfNeeded(force: true)
        }
        .onChange(of: appState.pendingEditorReveal?.path) { _, _ in
            consumePendingRevealIfNeeded()
        }
    }

    private func editorBinding(globalKey: String) -> Binding<String> {
        Binding(
            get: { appState.getEditorDocument(globalWorkspaceKey: globalKey, path: path)?.content ?? "" },
            set: { appState.updateEditorDocumentContent(globalWorkspaceKey: globalKey, path: path, content: $0) }
        )
    }

    private func openDocumentIfNeeded(force: Bool) {
        guard let ws = appState.selectedWorkspaceKey else { return }
        guard appState.getActiveTab()?.kind == .editor, appState.getActiveTab()?.payload == path else { return }
        appState.openEditorDocument(project: appState.selectedProjectName, workspace: ws, path: path, force: force)
        appState.lastEditorPath = path
    }

    private func consumePendingRevealIfNeeded() {
        guard let reveal = appState.pendingEditorReveal, reveal.path == path else { return }
        highlightedLine = reveal.line
        appState.pendingEditorReveal = nil
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
            if let globalKey = appState.currentGlobalWorkspaceKey,
               let context = appState.lastDiffNavigationContext,
               context.workspaceKey == globalKey,
               context.path == path {
                Button("返回 Diff") {
                    appState.addDiffTab(workspaceKey: context.workspaceKey, path: context.path, mode: context.mode)
                }
                .buttonStyle(.borderless)
            } else if let globalKey = appState.currentGlobalWorkspaceKey,
               let doc = appState.getEditorDocument(globalWorkspaceKey: globalKey, path: path),
               doc.conflictState != .none {
                Text(doc.conflictState == .deletedOnDisk ? "文件已被删除" : "磁盘内容已变更")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Button("重新加载") {
                    guard let workspace = appState.selectedWorkspaceKey else { return }
                    appState.reloadEditorDocument(project: appState.selectedProjectName, workspace: workspace, path: path)
                }
                .buttonStyle(.borderless)
            } else if !appState.editorStatus.isEmpty {
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

// MARK: - 原生 Diff Content View

struct NativeDiffContentView: View {
    let path: String
    @Binding var webViewVisible: Bool
    @EnvironmentObject var appState: AppState

    @State private var currentMode: DiffMode = .working

    var body: some View {
        VStack(spacing: 0) {
            DiffToolbar(currentMode: $currentMode, onModeChange: handleModeChange)
            diffBody
            DiffStatusBar(path: path, mode: currentMode)
        }
        .onAppear {
            webViewVisible = false
            currentMode = appState.activeDiffMode
            requestDiff()
        }
        .onChange(of: path) { _, _ in requestDiff() }
        .onChange(of: appState.currentGlobalWorkspaceKey) { _, _ in requestDiff() }
    }

    @ViewBuilder
    private var diffBody: some View {
        if let ws = appState.selectedWorkspaceKey,
           let cache = appState.gitCache.getDiffCache(workspaceKey: ws, path: path, mode: currentMode) {
            if cache.isLoading {
                ProgressView("Loading diff...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = cache.error {
                Text(err).foregroundColor(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cache.isBinary {
                Text("Binary file cannot be previewed")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(cache.parsedLines) { line in
                            DiffLineRowView(line: line) {
                                if let target = line.targetLine {
                                    openEditorAtLine(target)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ProgressView("Loading diff...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func requestDiff() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitCache.fetchGitDiff(workspaceKey: ws, path: path, mode: currentMode)
    }

    private func handleModeChange(_ newMode: DiffMode) {
        guard newMode != currentMode else { return }
        currentMode = newMode
        appState.setActiveDiffMode(newMode)
        requestDiff()
    }

    private func openEditorAtLine(_ line: Int) {
        guard let global = appState.currentGlobalWorkspaceKey else { return }
        appState.lastDiffNavigationContext = DiffNavigationContext(
            workspaceKey: global,
            path: path,
            mode: currentMode
        )
        appState.addEditorTab(workspaceKey: global, path: path, line: line)
    }
}

struct DiffLineRowView: View {
    let line: DiffLine
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(line.oldLineNumber.map { String($0) } ?? "")
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 11, design: .monospaced))
            Text(line.newLineNumber.map { String($0) } ?? "")
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 11, design: .monospaced))
            Text(prefix(for: line.kind))
                .foregroundColor(color(for: line.kind))
                .font(.system(size: 11, design: .monospaced))
            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(background(for: line.kind))
        .contentShape(Rectangle())
        .onTapGesture {
            if line.isNavigable {
                onOpen()
            }
        }
    }

    private func prefix(for kind: DiffLineKind) -> String {
        switch kind {
        case .add: return "+"
        case .del: return "-"
        case .context: return " "
        case .hunk: return "@@"
        case .header: return " "
        }
    }

    private func color(for kind: DiffLineKind) -> Color {
        switch kind {
        case .add: return .green
        case .del: return .red
        case .hunk: return .blue
        default: return .secondary
        }
    }

    private func background(for kind: DiffLineKind) -> Color {
        switch kind {
        case .add: return Color.green.opacity(0.10)
        case .del: return Color.red.opacity(0.10)
        case .hunk: return Color.blue.opacity(0.08)
        default: return Color.clear
        }
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

struct NativeCodeEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var highlightedLine: Int?

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditorView
        weak var textView: NSTextView?
        var suppressChange = false
        var highlightedRange: NSRange?

        init(parent: NativeCodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressChange, let textView else { return }
            parent.text = textView.string
        }

        func reveal(line: Int) {
            guard line > 0, let textView else { return }
            let ns = textView.string as NSString
            var target = 0
            var currentLine = 1
            while target < ns.length && currentLine < line {
                if ns.character(at: target) == 10 {
                    currentLine += 1
                }
                target += 1
            }
            textView.setSelectedRange(NSRange(location: min(target, ns.length), length: 0))
            textView.scrollRangeToVisible(NSRange(location: min(target, ns.length), length: 0))

            if let storage = textView.textStorage {
                if let old = highlightedRange {
                    storage.removeAttribute(.backgroundColor, range: old)
                }
                let lineEnd = lineEndIndex(ns: ns, start: target)
                let range = NSRange(location: target, length: max(0, lineEnd - target))
                highlightedRange = range
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), range: range)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, let storage = textView.textStorage, let old = self.highlightedRange else { return }
                    storage.removeAttribute(.backgroundColor, range: old)
                    self.highlightedRange = nil
                }
            }
        }

        private func lineEndIndex(ns: NSString, start: Int) -> Int {
            var index = start
            while index < ns.length {
                if ns.character(at: index) == 10 { break }
                index += 1
            }
            return index
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.textColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.string = text
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            context.coordinator.suppressChange = true
            textView.string = text
            context.coordinator.suppressChange = false
        }
        if let line = highlightedLine {
            context.coordinator.reveal(line: line)
            DispatchQueue.main.async {
                self.highlightedLine = nil
            }
        }
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

struct EvolutionEditableProfile: Identifiable, Equatable {
    let id: String
    let stage: String
    var aiTool: AIChatTool
    var mode: String
    var providerID: String
    var modelID: String
}

struct EvolutionTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var maxVerifyIterationsText: String = "3"
    @State private var autoLoopEnabled: Bool = true
    @State private var isSessionViewerPresented: Bool = false
    @State private var viewerStage: String?

    private var project: String { appState.selectedProjectName }
    private var workspace: String? { appState.selectedWorkspaceKey }
    private var workspaceReady: Bool { workspace != nil && !(workspace ?? "").isEmpty }

    private var currentItem: EvolutionWorkspaceItemV2? {
        guard let workspace else { return nil }
        return appState.evolutionItem(project: project, workspace: workspace)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
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
            
            #if os(macOS)
            if isSessionViewerPresented {
                EvolutionSessionDrawerView(isSessionViewerPresented: $isSessionViewerPresented)
                    .frame(width: 380)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.25), value: isSessionViewerPresented)
            }
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $isSessionViewerPresented) {
            EvolutionSessionDrawerView(isSessionViewerPresented: $isSessionViewerPresented)
        }
        #endif
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
        GroupBox("本轮代理状态") {
            VStack(alignment: .leading, spacing: 12) {
                Text("运行中的代理将置顶显示；点击状态徽章可查看聊天详情。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                let sortedAgents = sortedAgents()
                if sortedAgents.isEmpty {
                    Text("暂无运行中的代理")
                        .foregroundColor(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 12, alignment: .top)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(sortedAgents, id: \.stage) { agent in
                            stageStatusCard(agent: agent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sortedAgents() -> [EvolutionAgentInfoV2] {
        guard let item = currentItem else { return [] }
        return item.agents.sorted { a, b in
            let aStatus = normalizedStageStatus(a.status)
            let bStatus = normalizedStageStatus(b.status)
            // running 置顶
            if aStatus == "running" && bStatus != "running" { return true }
            if bStatus == "running" && aStatus != "running" { return false }
            // completed 排第二
            if (aStatus == "completed" || aStatus == "success" || aStatus == "succeeded" || aStatus == "已完成" || aStatus == "完成") &&
               !(bStatus == "completed" || bStatus == "success" || bStatus == "succeeded" || bStatus == "已完成" || bStatus == "完成") {
                return true
            }
            if (bStatus == "completed" || bStatus == "success" || bStatus == "succeeded" || bStatus == "已完成" || bStatus == "完成") &&
               !(aStatus == "completed" || aStatus == "success" || aStatus == "succeeded" || aStatus == "已完成" || aStatus == "完成") {
                return false
            }
            return a.stage < b.stage
        }
    }

    private func stageStatusCard(agent: EvolutionAgentInfoV2) -> some View {
        let statusText = agent.status
        let isRunning = normalizedStageStatus(statusText) == "running"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if isRunning {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .modifier(RunningPulseModifier())
                }
                Image(systemName: stageIconName(agent.stage))
                    .foregroundColor(.accentColor)
                Text(stageDisplayName(agent.stage))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if canOpenStageChat(statusText) {
                    Button {
                        openStageChat(stage: agent.stage)
                    } label: {
                        HStack(spacing: 4) {
                            Text(statusText)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .foregroundColor(stageStatusColor(statusText))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(stageStatusColor(statusText).opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(stageStatusColor(statusText))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(stageStatusColor(statusText).opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            if let latestMessage = agent.latestMessage, !latestMessage.isEmpty {
                Text(latestMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isRunning ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.12), lineWidth: isRunning ? 2 : 1)
        )
    }

    // MARK: - Running Animation Modifier

    struct RunningPulseModifier: ViewModifier {
        @State private var isAnimating = false

        func body(content: Content) -> some View {
            content
                .scaleEffect(isAnimating ? 1.2 : 1.0)
                .opacity(isAnimating ? 0.7 : 1.0)
                .animation(
                    Animation.easeInOut(duration: 0.8)
                        .repeatForever(autoreverses: true),
                    value: isAnimating
                )
                .onAppear {
                    isAnimating = true
                }
        }
    }

    private func refreshData() {
        appState.requestEvolutionSnapshot()
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
        return normalized == "running" ||
            normalized == "completed" ||
            normalized == "已完成" ||
            normalized == "完成" ||
            normalized == "success" ||
            normalized == "succeeded"
    }

    private func normalizedStageStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func stageDisplayName(_ stage: String) -> String {
        let trimmed = stage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未命名类型" }
        switch trimmed.lowercased() {
        case "direction":
            return "direction"
        case "plan":
            return "plan"
        case "implement":
            return "implement"
        case "verify":
            return "verify"
        case "judge":
            return "judge"
        case "report":
            return "report"
        default:
            return trimmed
        }
    }

    private func stageIconName(_ stage: String) -> String {
        switch stage.lowercased() {
        case "plan":
            return "map"
        case "code":
            return "chevron.left.forwardslash.chevron.right"
        case "verify":
            return "checkmark.seal"
        default:
            return "person.crop.square"
        }
    }

    private func openStageChat(stage: String) {
        guard let item = currentItem else { return }
        appState.openEvolutionStageChat(
            project: item.project,
            workspace: item.workspace,
            cycleId: item.cycleID,
            stage: stage
        )
        viewerStage = stage
        isSessionViewerPresented = true
    }

    private func startCurrentWorkspace() {
        guard let workspace else { return }
        let verify = max(1, Int(maxVerifyIterationsText) ?? 3)
        let defaultProfiles = appState.evolutionDefaultProfiles
        let profiles: [EvolutionStageProfileInfoV2] = defaultProfiles.map { item in
            let model: EvolutionModelSelectionV2? = {
                guard !item.providerID.isEmpty, !item.modelID.isEmpty else { return nil }
                return EvolutionModelSelectionV2(providerID: item.providerID, modelID: item.modelID)
            }()
            return EvolutionStageProfileInfoV2(
                stage: item.stage,
                aiTool: item.aiTool,
                mode: item.mode.isEmpty ? nil : item.mode,
                model: model
            )
        }
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


struct EvolutionSessionDrawerView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isSessionViewerPresented: Bool
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(appState.evolutionReplayTitle)
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    isSessionViewerPresented = false
                    dismiss()
                    appState.clearEvolutionReplay()
                }
            }
            .padding()
            
            Divider()
            
            // 内容区
            if appState.evolutionReplayLoading {
                ProgressView()
                    .frame(maxHeight: .infinity)
            } else if let error = appState.evolutionReplayError, !error.isEmpty {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            } else {
                List {
                    ForEach(appState.evolutionReplayMessages) { message in
                        // 消息展示（简化版）
                        VStack(alignment: .leading) {
                            Text(message.role.rawValue.capitalized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ForEach(message.parts) { part in
                                if let text = part.text {
                                    Text(text)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color(NSColor.separatorColor)),
            alignment: .leading
        )
        #endif
    }
}
