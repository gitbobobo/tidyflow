import SwiftUI
import AppKit

struct TabContentHostView: View {
    @EnvironmentObject var appState: AppState

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
                    case .evolution:
                        EvolutionTabView()
                            .environmentObject(appState)
                    case .evidence:
                        EvidenceTabView()
                            .environmentObject(appState)
                    }
                } else if let activeId = appState.activeTabIdByWorkspace[globalKey],
                          let tabs = appState.workspaceTabs[globalKey],
                          let activeTab = tabs.first(where: { $0.id == activeId }) {

                    switch activeTab.kind {
                    case .terminal:
                        TerminalContentView(tab: activeTab)
                            .id(activeTab.id)
                    case .editor:
                        NativeEditorContentView(path: activeTab.payload)
                        .id(activeTab.payload) // 不同 path 视为不同 View，确保切换时触发 onAppear
                    case .diff:
                        NativeDiffContentView(path: activeTab.payload)
                    case .settings:
                        SettingsContentView()
                            .environmentObject(appState)
                    }
                } else {
                    // 已选择工作空间但没有活跃 Tab，显示快捷操作视图
                    QuickActionsView()
                }
            } else {
                NoActiveTabView()
            }
        }
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

// MARK: - Terminal Content View

struct TerminalContentView: View {
    let tab: TabModel
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            MacSwiftTermTerminalView(appState: appState, tabId: tab.id)
                .background(Color.black)
            TerminalStatusBar()
                .environmentObject(appState)
        }
        .onAppear {
            appState.ensureTerminalForTab(tab)
        }
    }
}

// MARK: - Terminal Status Bar

struct TerminalStatusBar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var terminalStore: TerminalStore

    var body: some View {
        HStack {
            // Terminal indicator
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundColor(.green)

            // Session info
            switch terminalStore.terminalState {
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
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var editorStore: EditorStore
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
            openDocumentIfNeeded(force: false)
            consumePendingRevealIfNeeded()
        }
        .onChange(of: appState.currentGlobalWorkspaceKey) { _, _ in
            openDocumentIfNeeded(force: true)
        }
        .onChange(of: editorStore.pendingEditorReveal?.path) { _, _ in
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
        guard let reveal = editorStore.pendingEditorReveal, reveal.path == path else { return }
        highlightedLine = reveal.line
        editorStore.pendingEditorReveal = nil
    }
}

// MARK: - Editor Status Bar

struct EditorStatusBar: View {
    let path: String
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var editorStore: EditorStore

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
            } else if !editorStore.editorStatus.isEmpty {
                Text(editorStore.editorStatus)
                    .font(.system(size: 11))
                    .foregroundColor(editorStore.editorStatusIsError ? .red : .green)
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
    @EnvironmentObject var appState: AppState

    @State private var currentMode: DiffMode = .working

    var body: some View {
        VStack(spacing: 0) {
            DiffToolbar(currentMode: $currentMode, onModeChange: handleModeChange)
            diffBody
            DiffStatusBar(path: path, mode: currentMode)
        }
        .onAppear {
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

// MARK: - Evidence Tab Types

enum EvidenceTabType: String, CaseIterable, Identifiable {
    case screenshot = "screenshot"
    case log = "log"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .screenshot: return "截图"
        case .log: return "日志"
        }
    }
    
    var iconName: String {
        switch self {
        case .screenshot: return "photo"
        case .log: return "doc.text"
        }
    }
}

struct EvidenceTabView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedTab: EvidenceTabType = .screenshot
    @State private var selectedScreenshotID: String?
    @State private var selectedLogID: String?
    @State private var itemLoading: Bool = false
    @State private var itemPaging: Bool = false
    @State private var itemError: String?
    @State private var itemTextChunks: [String] = []
    @State private var itemTextNextOffset: UInt64 = 0
    @State private var itemTextHasMore: Bool = false
    @State private var itemImage: NSImage?
    @State private var itemByteCount: Int = 0
    @State private var actionMessage: String?
    @State private var screenshotThumbnails: [String: NSImage] = [:]
    @State private var screenshotThumbnailLoadingIDs: Set<String> = []
    @State private var screenshotThumbnailLoadFailedIDs: Set<String> = []
    @State private var screenshotThumbnailPendingIDs: [String] = []
    @State private var screenshotThumbnailActiveID: String?
    @State private var screenshotThumbnailRequestSequence: UInt64 = 0

    private var project: String { appState.selectedProjectName }
    private var workspace: String? { appState.selectedWorkspaceKey }

    private var snapshot: EvidenceSnapshotV2? {
        guard let workspace else { return nil }
        return appState.evidenceSnapshot(project: project, workspace: workspace)
    }

    private var snapshotLoading: Bool {
        guard let workspace else { return false }
        let key = appState.globalWorkspaceKey(projectName: project, workspaceName: appState.normalizeEvolutionWorkspaceName(workspace))
        return appState.evidenceLoadingByWorkspace[key] ?? false
    }

    private var snapshotError: String? {
        guard let workspace else { return nil }
        let key = appState.globalWorkspaceKey(projectName: project, workspaceName: appState.normalizeEvolutionWorkspaceName(workspace))
        return appState.evidenceErrorByWorkspace[key]
    }
    
    /// 根据当前选中的标签页获取对应的证据条目
    private var currentTabItems: [EvidenceItemInfoV2] {
        guard let snapshot else { return [] }
        return snapshot.items.filter { item in
            switch selectedTab {
            case .screenshot:
                return item.evidenceType == "screenshot" || item.mimeType.hasPrefix("image/")
            case .log:
                return item.evidenceType == "log" || (!item.mimeType.hasPrefix("image/") && item.evidenceType != "screenshot")
            }
        }.sorted { $0.order < $1.order }
    }
    
    /// 获取当前标签页下的设备类型列表（保持原有顺序）
    private var currentTabDeviceTypes: [String] {
        let deviceTypes = currentTabItems.map { $0.deviceType }
        var seen = Set<String>()
        var result: [String] = []
        for type in deviceTypes {
            if !seen.contains(type) {
                seen.insert(type)
                result.append(type)
            }
        }
        return result
    }
    
    /// 获取指定设备类型的条目
    private func items(for deviceType: String) -> [EvidenceItemInfoV2] {
        currentTabItems.filter { $0.deviceType == deviceType }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabSwitcher
            Divider()
            content
        }
        .onAppear {
            refreshEvidence()
        }
        .onChange(of: appState.selectedWorkspaceKey) { _, _ in
            selectedScreenshotID = nil
            selectedLogID = nil
            clearItemPreview()
            clearScreenshotThumbnailCache()
            refreshEvidence()
        }
        .onChange(of: appState.selectedProjectName) { _, _ in
            selectedScreenshotID = nil
            selectedLogID = nil
            clearItemPreview()
            clearScreenshotThumbnailCache()
            refreshEvidence()
        }
        .onChange(of: appState.connectionState) { _, state in
            guard state == .connected else { return }
            refreshEvidence()
        }
        .onChange(of: snapshot?.updatedAt) { _, _ in
            syncSelectionIfNeeded()
            pruneScreenshotThumbnailCache()
            processNextScreenshotThumbnailLoadIfNeeded()
        }
        .onChange(of: selectedTab) { _, _ in
            stopScreenshotThumbnailPrefetch()
            processNextScreenshotThumbnailLoadIfNeeded()
        }
        .onChange(of: selectedScreenshotID) { _, newValue in
            if newValue == nil {
                processNextScreenshotThumbnailLoadIfNeeded()
            } else {
                stopScreenshotThumbnailPrefetch()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("证据")
                .font(.headline)
            Spacer()
            if let actionMessage, !actionMessage.isEmpty {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Button("刷新") {
                refreshEvidence()
            }
            .buttonStyle(.borderless)
            Button("重建全链路证据") {
                rebuildEvidence()
            }
            .buttonStyle(.borderedProminent)
            .disabled(workspace == nil || workspace?.isEmpty == true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(EvidenceTabType.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                        clearItemPreview()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.iconName)
                        Text(tab.displayName)
                        Text("(\(itemsCount(for: tab)))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        selectedTab == tab
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                if tab != EvidenceTabType.allCases.last {
                    Divider()
                        .frame(height: 20)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func itemsCount(for tab: EvidenceTabType) -> Int {
        guard let snapshot else { return 0 }
        return snapshot.items.filter { item in
            switch tab {
            case .screenshot:
                return item.evidenceType == "screenshot" || item.mimeType.hasPrefix("image/")
            case .log:
                return item.evidenceType == "log" || (!item.mimeType.hasPrefix("image/") && item.evidenceType != "screenshot")
            }
        }.count
    }

    @ViewBuilder
    private var content: some View {
        if workspace == nil {
            emptyStateView(icon: "photo.stack", text: "请先选择工作空间")
        } else if snapshotLoading && snapshot == nil {
            ProgressView("读取证据中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshotError, snapshot == nil {
            errorView(message: snapshotError)
        } else if snapshot == nil {
            emptyStateView(icon: "photo.stack", text: "暂无证据数据", showRefresh: true)
        } else if currentTabItems.isEmpty {
            emptyStateView(
                icon: selectedTab == .screenshot ? "photo" : "doc.text",
                text: "暂无\(selectedTab.displayName)数据"
            )
        } else {
            mainContent
        }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        if currentSelectedItem == nil {
            evidenceListPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                evidenceListPane
                    .frame(minWidth: 340, maxWidth: 480)

                Divider()

                // 右侧详情区域
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var evidenceListPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(currentTabDeviceTypes, id: \.self) { deviceType in
                    deviceSection(deviceType: deviceType, items: items(for: deviceType))
                }
            }
            .padding(16)
        }
    }
    
    @ViewBuilder
    private func deviceSection(deviceType: String, items: [EvidenceItemInfoV2]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 设备类型标题
            HStack {
                Text(deviceType)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(items.count) 项")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
            
            // 根据当前标签页选择布局方式
            if selectedTab == .screenshot {
                screenshotGrid(items: items)
            } else {
                logList(items: items)
            }
        }
    }
    
    /// 截图网格布局
    private func screenshotGrid(items: [EvidenceItemInfoV2]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)
            ],
            spacing: 12
        ) {
            ForEach(items, id: \.itemID) { item in
                screenshotThumbnail(item: item)
            }
        }
    }
    
    /// 截图缩略图卡片
    private func screenshotThumbnail(item: EvidenceItemInfoV2) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedScreenshotID = item.itemID
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // 缩略图区域
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .aspectRatio(16/9, contentMode: .fit)

                    if let thumbnail = screenshotThumbnails[item.itemID] {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(.rect(cornerRadius: 6))
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.5))
                        if screenshotThumbnailLoadingIDs.contains(item.itemID) {
                            ProgressView()
                                .controlSize(.small)
                                .offset(y: 20)
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            selectedScreenshotID == item.itemID ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
                .clipShape(.rect(cornerRadius: 6))
                
                // 标题
                Text(item.title)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                // 序号
                Text("#\(item.order)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            enqueueScreenshotThumbnailLoad(for: item)
        }
    }
    
    /// 日志列表布局
    private func logList(items: [EvidenceItemInfoV2]) -> some View {
        VStack(spacing: 0) {
            ForEach(items, id: \.itemID) { item in
                logRow(item: item)
                if item.itemID != items.last?.itemID {
                    Divider()
                        .padding(.leading, 40)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
    }
    
    /// 日志列表行
    private func logRow(item: EvidenceItemInfoV2) -> some View {
        Button {
            selectedLogID = item.itemID
        } label: {
            HStack(spacing: 12) {
                // 序号
                Text("#\(item.order)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 32, alignment: .leading)
                
                // 文件图标
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                
                // 内容
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    if !item.description.isEmpty && item.description != item.title {
                        Text(item.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Text(item.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
                
                Spacer()
                
                // 文件大小
                if item.sizeBytes > 0 {
                    Text(formatByteCount(item.sizeBytes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                selectedLogID == item.itemID
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    /// 格式化字节数
    private func formatByteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    /// 空状态视图
    private func emptyStateView(icon: String, text: String, showRefresh: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.6))
            Text(text)
                .foregroundColor(.secondary)
            if showRefresh {
                Button("刷新") {
                    refreshEvidence()
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    /// 错误视图
    private func errorView(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(message)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
            Button("重试") {
                refreshEvidence()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailPane: some View {
        let selectedItem = currentSelectedItem
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 12) {
                // 标题栏
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.title3)
                    Text(item.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack {
                        Text(item.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        if item.sizeBytes > 0 {
                            Text(formatByteCount(item.sizeBytes))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.bottom, 8)
                
                Divider()

                // 内容区域
                detailContent(for: item)
            }
            .padding(16)
            .onAppear {
                loadItemIfNeeded(item)
            }
            .onChange(of: item.itemID) { _, _ in
                loadItem(item)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: selectedTab == .screenshot ? "photo" : "doc.text")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.6))
                Text("选择一项查看详情")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    /// 当前选中的条目
    private var currentSelectedItem: EvidenceItemInfoV2? {
        let selectedID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        if let id = selectedID {
            return currentTabItems.first { $0.itemID == id }
        }
        return nil
    }
    
    /// 详情内容
    @ViewBuilder
    private func detailContent(for item: EvidenceItemInfoV2) -> some View {
        if itemLoading {
            ProgressView("加载内容中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if let itemError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                Text(itemError)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if let itemImage, selectedTab == .screenshot {
            // 图片详情
            ZStack {
                Color.black.opacity(0.05)
                Image(nsImage: itemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 10))
        } else if !itemTextChunks.isEmpty {
            // 文本详情
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(itemTextChunks.indices, id: \.self) { idx in
                        Text(itemTextChunks[idx])
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if itemPaging || itemTextHasMore {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(itemPaging ? "加载更多中..." : "滚动到底部继续加载")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                        .onAppear {
                            loadNextTextPageIfNeeded(for: item)
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(10)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("无法预览该证据")
                    .foregroundColor(.secondary)
                if item.mimeType != "application/octet-stream" {
                    Text("MIME: \(item.mimeType)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
    
    private func loadItemIfNeeded(_ item: EvidenceItemInfoV2) {
        let currentID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        if currentID != item.itemID {
            if selectedTab == .screenshot {
                selectedScreenshotID = item.itemID
            } else {
                selectedLogID = item.itemID
            }
            loadItem(item)
        } else if itemTextChunks.isEmpty && itemImage == nil && !itemLoading && itemError == nil {
            loadItem(item)
        }
    }

    private func syncSelectionIfNeeded() {
        guard let snapshot else { return }
        var shouldClearPreview = false
        if let screenshotID = selectedScreenshotID,
           !snapshot.items.contains(where: { $0.itemID == screenshotID }) {
            selectedScreenshotID = nil
            shouldClearPreview = shouldClearPreview || selectedTab == .screenshot
        }
        if let logID = selectedLogID,
           !snapshot.items.contains(where: { $0.itemID == logID }) {
            selectedLogID = nil
            shouldClearPreview = shouldClearPreview || selectedTab == .log
        }
        if shouldClearPreview {
            clearItemPreview()
        }
    }

    private func clearItemPreview() {
        itemLoading = false
        itemPaging = false
        itemError = nil
        itemTextChunks = []
        itemTextNextOffset = 0
        itemTextHasMore = false
        itemImage = nil
        itemByteCount = 0
    }

    private func clearScreenshotThumbnailCache() {
        stopScreenshotThumbnailPrefetch()
        screenshotThumbnails.removeAll()
        screenshotThumbnailLoadFailedIDs.removeAll()
    }

    private func stopScreenshotThumbnailPrefetch() {
        screenshotThumbnailPendingIDs.removeAll()
        screenshotThumbnailActiveID = nil
        screenshotThumbnailLoadingIDs.removeAll()
        screenshotThumbnailRequestSequence &+= 1
    }

    private func pruneScreenshotThumbnailCache() {
        guard let snapshot else {
            clearScreenshotThumbnailCache()
            return
        }
        let validIDs = Set(
            snapshot.items.compactMap { item -> String? in
                if item.evidenceType == "screenshot" || item.mimeType.hasPrefix("image/") {
                    return item.itemID
                }
                return nil
            }
        )
        screenshotThumbnails = screenshotThumbnails.filter { validIDs.contains($0.key) }
        screenshotThumbnailLoadFailedIDs = screenshotThumbnailLoadFailedIDs.intersection(validIDs)
        screenshotThumbnailPendingIDs.removeAll { !validIDs.contains($0) }
        if let activeID = screenshotThumbnailActiveID, !validIDs.contains(activeID) {
            screenshotThumbnailActiveID = nil
            screenshotThumbnailLoadingIDs.remove(activeID)
        }
    }

    private var canPrefetchScreenshotThumbnails: Bool {
        selectedTab == .screenshot && selectedScreenshotID == nil
    }

    private func enqueueScreenshotThumbnailLoad(for item: EvidenceItemInfoV2) {
        guard canPrefetchScreenshotThumbnails else { return }
        guard screenshotThumbnails[item.itemID] == nil else { return }
        guard !screenshotThumbnailLoadingIDs.contains(item.itemID) else { return }
        guard !screenshotThumbnailLoadFailedIDs.contains(item.itemID) else { return }
        guard !screenshotThumbnailPendingIDs.contains(item.itemID) else { return }
        guard item.mimeType.hasPrefix("image/") || item.evidenceType == "screenshot" else { return }
        screenshotThumbnailPendingIDs.append(item.itemID)
        processNextScreenshotThumbnailLoadIfNeeded()
    }

    private func processNextScreenshotThumbnailLoadIfNeeded() {
        guard canPrefetchScreenshotThumbnails else { return }
        guard let workspace, !workspace.isEmpty else { return }
        guard screenshotThumbnailActiveID == nil else { return }

        while !screenshotThumbnailPendingIDs.isEmpty {
            let itemID = screenshotThumbnailPendingIDs.removeFirst()
            guard screenshotThumbnails[itemID] == nil else { continue }
            guard !screenshotThumbnailLoadFailedIDs.contains(itemID) else { continue }
            guard let item = currentTabItems.first(where: { $0.itemID == itemID }) else { continue }
            guard item.mimeType.hasPrefix("image/") || item.evidenceType == "screenshot" else { continue }

            screenshotThumbnailActiveID = itemID
            screenshotThumbnailLoadingIDs.insert(itemID)
            screenshotThumbnailRequestSequence &+= 1
            let requestSequence = screenshotThumbnailRequestSequence

            appState.readEvidenceItem(project: project, workspace: workspace, itemID: itemID) { payload, _ in
                DispatchQueue.main.async {
                    finalizeScreenshotThumbnailRequest(
                        itemID: itemID,
                        requestSequence: requestSequence,
                        payload: payload
                    )
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                finalizeScreenshotThumbnailRequest(
                    itemID: itemID,
                    requestSequence: requestSequence,
                    payload: nil
                )
            }
            return
        }
    }

    private func finalizeScreenshotThumbnailRequest(
        itemID: String,
        requestSequence: UInt64,
        payload: (mimeType: String, content: [UInt8])?
    ) {
        guard screenshotThumbnailActiveID == itemID else { return }
        guard screenshotThumbnailRequestSequence == requestSequence else { return }

        screenshotThumbnailLoadingIDs.remove(itemID)
        screenshotThumbnailActiveID = nil

        if let payload, let thumbnail = NSImage(data: Data(payload.content)) {
            screenshotThumbnails[itemID] = thumbnail
        } else {
            screenshotThumbnailLoadFailedIDs.insert(itemID)
        }

        processNextScreenshotThumbnailLoadIfNeeded()
    }

    private func refreshEvidence() {
        guard let workspace, !workspace.isEmpty else { return }
        appState.requestEvidenceSnapshot(project: project, workspace: workspace)
    }

    private func rebuildEvidence() {
        guard let workspace, !workspace.isEmpty else { return }
        appState.requestEvidenceRebuildPrompt(project: project, workspace: workspace) { prompt, errorMessage in
            DispatchQueue.main.async {
                if let prompt {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(prompt.prompt, forType: .string)
                    appState.setAIChatOneShotHint(
                        project: prompt.project,
                        workspace: prompt.workspace,
                        message: "提示词已复制，请在聊天输入框粘贴后发送。"
                    )
                    if let key = appState.currentGlobalWorkspaceKey {
                        appState.showWorkspaceSpecialPage(workspaceKey: key, page: .aiChat)
                    }
                    actionMessage = "已复制提示词并切换到聊天页"
                } else {
                    let error = errorMessage ?? "未知错误"
                    actionMessage = "重建提示词生成失败：\(error)"
                }
            }
        }
    }

    private func loadItem(_ item: EvidenceItemInfoV2) {
        guard let workspace, !workspace.isEmpty else { return }
        itemLoading = true
        itemPaging = false
        itemError = nil
        itemTextChunks = []
        itemTextNextOffset = 0
        itemTextHasMore = false
        itemImage = nil
        itemByteCount = 0

        if item.mimeType.hasPrefix("image/") || item.evidenceType == "screenshot" {
            appState.readEvidenceItem(project: project, workspace: workspace, itemID: item.itemID) { payload, errorMessage in
                DispatchQueue.main.async {
                    let currentID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
                    guard currentID == item.itemID else { return }
                    itemLoading = false
                    if let payload {
                        let data = Data(payload.content)
                        itemByteCount = payload.content.count
                        if let image = NSImage(data: data) {
                            itemImage = image
                            return
                        }
                        itemError = "图片解码失败"
                    } else {
                        itemError = errorMessage ?? "未知错误"
                    }
                }
            }
            return
        }

        loadNextTextPage(for: item, reset: true)
    }

    private func loadNextTextPageIfNeeded(for item: EvidenceItemInfoV2) {
        let currentID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        guard currentID == item.itemID else { return }
        guard itemTextHasMore, !itemPaging, !itemLoading else { return }
        loadNextTextPage(for: item, reset: false)
    }

    private func loadNextTextPage(for item: EvidenceItemInfoV2, reset: Bool) {
        guard let workspace, !workspace.isEmpty else { return }
        let offset: UInt64 = reset ? 0 : itemTextNextOffset
        if !reset, offset == 0 {
            return
        }
        itemPaging = true
        appState.readEvidenceItemPage(
            project: project,
            workspace: workspace,
            itemID: item.itemID,
            offset: offset,
            limit: 131_072
        ) { payload, errorMessage in
            DispatchQueue.main.async {
                let currentID = self.selectedTab == .screenshot ? self.selectedScreenshotID : self.selectedLogID
                guard currentID == item.itemID else { return }
                itemLoading = false
                itemPaging = false
                if let payload {
                    itemByteCount = Int(payload.totalSizeBytes)
                    let text = String(data: Data(payload.content), encoding: .utf8) ?? String(decoding: payload.content, as: UTF8.self)
                    if reset {
                        itemTextChunks = [text]
                    } else {
                        itemTextChunks.append(text)
                    }
                    itemTextNextOffset = payload.nextOffset
                    itemTextHasMore = !payload.eof
                    return
                }
                itemError = errorMessage ?? "未知错误"
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
    @State private var loopRoundLimitText: String = "1"
    @State private var isSessionViewerPresented: Bool = false
    @State private var viewerStage: String?
    @State private var isBlockerSheetPresented: Bool = false
    @State private var blockerDrafts: [String: EvolutionBlockerDraft] = [:]

    private struct EvolutionAgentDisplayItem {
        let id: String
        let stage: String
        let agent: String
        let status: String
        let toolCallCount: Int
    }

    private struct EvolutionBlockerDraft {
        var selected: Bool
        var selectedOptionID: String
        var answerText: String
    }

    private var project: String { appState.selectedProjectName }
    private var workspace: String? { appState.selectedWorkspaceKey }
    private var workspaceReady: Bool { workspace != nil && !(workspace ?? "").isEmpty }

    private var currentItem: EvolutionWorkspaceItemV2? {
        guard let workspace else { return nil }
        return appState.evolutionItem(project: project, workspace: workspace)
    }

    private let evolutionStageOrder: [String] = ["direction", "plan", "implement", "verify", "judge", "report"]

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        schedulerCard
                        workspaceCard
                        stageSectionsCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
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
        .sheet(isPresented: $isBlockerSheetPresented) {
            blockerSheet
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

        .onReceive(appState.$evolutionWorkspaceItems) { _ in
            syncStartOptionsFromCurrentItem()
        }
        .onReceive(appState.$evolutionBlockingRequired) { value in
            syncBlockerSheetState(value)
        }
    }

    private var blockerSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let blocking = appState.evolutionBlockingRequired {
                    Text("检测到阻塞任务，需人工完成后才能继续循环")
                        .font(.headline)
                    Text("触发: \(blocking.trigger)  阻塞文件: \(blocking.blockerFilePath)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    List {
                        ForEach(blocking.unresolvedItems, id: \.blockerID) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: bindingSelected(item.blockerID)) {
                                    Text(item.title)
                                }
                                .toggleStyle(.checkbox)
                                Text(item.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if !item.options.isEmpty {
                                    Picker("选项", selection: bindingOption(item.blockerID)) {
                                        Text("请选择").tag("")
                                        ForEach(item.options, id: \.optionID) { option in
                                            Text(option.label).tag(option.optionID)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }
                                if item.allowCustomInput || item.options.isEmpty {
                                    TextField("输入答案", text: bindingAnswer(item.blockerID))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    HStack {
                        Button("关闭") {
                            isBlockerSheetPresented = false
                        }
                        Spacer()
                        Button("提交已勾选项") {
                            submitBlockerAnswers(blocking)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("暂无阻塞任务")
                    Button("关闭") {
                        isBlockerSheetPresented = false
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 640, minHeight: 420)
            .navigationTitle("阻塞任务处理")
        }
    }

    private func bindingSelected(_ blockerID: String) -> Binding<Bool> {
        Binding(
            get: { blockerDrafts[blockerID]?.selected ?? true },
            set: { value in
                var draft = blockerDrafts[blockerID] ?? EvolutionBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
                draft.selected = value
                blockerDrafts[blockerID] = draft
            }
        )
    }

    private func bindingOption(_ blockerID: String) -> Binding<String> {
        Binding(
            get: { blockerDrafts[blockerID]?.selectedOptionID ?? "" },
            set: { value in
                var draft = blockerDrafts[blockerID] ?? EvolutionBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
                draft.selectedOptionID = value
                blockerDrafts[blockerID] = draft
            }
        )
    }

    private func bindingAnswer(_ blockerID: String) -> Binding<String> {
        Binding(
            get: { blockerDrafts[blockerID]?.answerText ?? "" },
            set: { value in
                var draft = blockerDrafts[blockerID] ?? EvolutionBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
                draft.answerText = value
                blockerDrafts[blockerID] = draft
            }
        )
    }

    private func syncBlockerSheetState(_ value: EvolutionBlockingRequiredV2?) {
        guard let value,
              let ws = workspace,
              value.project == project,
              appState.normalizeEvolutionWorkspaceName(value.workspace) == appState.normalizeEvolutionWorkspaceName(ws) else {
            return
        }
        for item in value.unresolvedItems {
            if blockerDrafts[item.blockerID] != nil {
                continue
            }
            blockerDrafts[item.blockerID] = EvolutionBlockerDraft(
                selected: true,
                selectedOptionID: item.options.first?.optionID ?? "",
                answerText: ""
            )
        }
        isBlockerSheetPresented = true
    }

    private func submitBlockerAnswers(_ blocking: EvolutionBlockingRequiredV2) {
        let resolutions: [EvolutionBlockerResolutionInputV2] = blocking.unresolvedItems.compactMap { item in
            let draft = blockerDrafts[item.blockerID] ?? EvolutionBlockerDraft(
                selected: true,
                selectedOptionID: "",
                answerText: ""
            )
            guard draft.selected else { return nil }
            let selectedOptionIDs = draft.selectedOptionID.isEmpty ? [] : [draft.selectedOptionID]
            let answer = draft.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
            return EvolutionBlockerResolutionInputV2(
                blockerID: item.blockerID,
                selectedOptionIDs: selectedOptionIDs,
                answerText: answer.isEmpty ? nil : answer
            )
        }
        appState.resolveEvolutionBlockers(
            project: blocking.project,
            workspace: blocking.workspace,
            resolutions: resolutions
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.title3)
                .foregroundStyle(.linearGradient(
                    colors: [.purple, .blue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text("自主进化")
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
            Button {
                refreshData()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新状态")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var schedulerCard: some View {
        HStack(spacing: 12) {
            schedulerStatCard(
                title: "激活状态",
                value: appState.evolutionScheduler.activationState,
                icon: "power",
                color: .green
            )
            schedulerStatCard(
                title: "并发上限",
                value: "\(appState.evolutionScheduler.maxParallelWorkspaces)",
                icon: "square.stack.3d.up",
                color: .blue
            )
            schedulerStatCard(
                title: "运行中",
                value: "\(appState.evolutionScheduler.runningCount)",
                icon: "play.circle.fill",
                color: .orange
            )
            schedulerStatCard(
                title: "排队中",
                value: "\(appState.evolutionScheduler.queuedCount)",
                icon: "clock.fill",
                color: .secondary
            )
        }
    }

    private func schedulerStatCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.title3)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var workspaceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let workspace {
                    LabeledContent("当前工作空间") {
                        Text("\(project)/\(workspace)")
                            .fontWeight(.medium)
                    }
                    if let item = currentItem {
                        LabeledContent("状态") {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(workspaceStatusColor(item.status))
                                    .frame(width: 8, height: 8)
                                Text(item.status)
                            }
                        }
                        LabeledContent("当前阶段") {
                            Text(item.currentStage)
                        }
                        LabeledContent("轮次") {
                            Text("\(item.globalLoopRound)/\(max(1, item.loopRoundLimit))")
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
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.secondary.opacity(0.5))
                                .frame(width: 8, height: 8)
                            Text("未启动")
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    HStack(spacing: 12) {
                        TextField("循环轮次", text: $loopRoundLimitText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("验证循环固定 3 次")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
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
                        .controlSize(.small)
                    }
                } else {
                    Text("请先选择工作空间")
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("工作空间控制", systemImage: "gearshape.2")
        }
    }

    private var stageSectionsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                let sortedAgents = sortedAgents()
                if sortedAgents.isEmpty {
                    Text("暂无代理配置")
                        .foregroundColor(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 12, alignment: .top)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(sortedAgents, id: \.id) { agent in
                            stageStatusCard(agent: agent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("代理列表", systemImage: "person.3.sequence")
        }
    }

    private func sortedAgents() -> [EvolutionAgentDisplayItem] {
        let runtimeAgents = currentItem?.agents ?? []
        var runtimeByStage: [String: EvolutionAgentInfoV2] = [:]
        for runtime in runtimeAgents {
            let key = normalizedStageKey(runtime.stage)
            guard !key.isEmpty else { continue }
            if runtimeByStage[key] == nil {
                runtimeByStage[key] = runtime
            }
        }

        let configuredProfiles: [EvolutionStageProfileInfoV2] = {
            if let workspace, !workspace.isEmpty {
                return appState.evolutionProfiles(project: project, workspace: workspace)
            }
            let defaults = appState.evolutionDefaultProfiles.map { item in
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
            return defaults.isEmpty ? AppState.defaultEvolutionProfiles() : defaults
        }()

        var items: [EvolutionAgentDisplayItem] = []
        var seenStages: Set<String> = []

        for profile in configuredProfiles {
            let key = normalizedStageKey(profile.stage)
            guard !key.isEmpty else { continue }
            guard seenStages.insert(key).inserted else { continue }

            if let runtime = runtimeByStage[key] {
                items.append(
                    EvolutionAgentDisplayItem(
                        id: key,
                        stage: runtime.stage,
                        agent: runtime.agent,
                        status: runtime.status,
                        toolCallCount: runtime.toolCallCount
                    )
                )
            } else {
                let mode = (profile.mode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let agentName = mode.isEmpty ? profile.aiTool.displayName : mode
                items.append(
                    EvolutionAgentDisplayItem(
                        id: key,
                        stage: profile.stage,
                        agent: agentName,
                        status: "未运行",
                        toolCallCount: 0
                    )
                )
            }
        }

        // 兼容运行时存在但配置中缺失的阶段，避免状态被吞掉。
        for runtime in runtimeAgents {
            let key = normalizedStageKey(runtime.stage)
            guard !key.isEmpty else { continue }
            guard seenStages.insert(key).inserted else { continue }
            items.append(
                EvolutionAgentDisplayItem(
                    id: key,
                    stage: runtime.stage,
                    agent: runtime.agent,
                    status: runtime.status,
                    toolCallCount: runtime.toolCallCount
                )
            )
        }

        return items.sorted { a, b in
            let leftOrder = stageOrder(for: a.stage)
            let rightOrder = stageOrder(for: b.stage)
            if leftOrder != rightOrder {
                return leftOrder < rightOrder
            }
            return a.stage < b.stage
        }
    }

    private func stageStatusCard(agent: EvolutionAgentDisplayItem) -> some View {
        let statusText = agent.status
        let isRunning = normalizedStageStatus(statusText) == "running"
        let isCompleted = isCompletedStatus(normalizedStageStatus(statusText))

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: stageIconName(agent.stage))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isRunning ? .orange : isCompleted ? .green : .accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill((isRunning ? Color.orange : isCompleted ? Color.green : Color.accentColor).opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(stageDisplayName(agent.stage))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(agent.agent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                if isRunning {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .modifier(RunningPulseModifier())
                }

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

            HStack(spacing: 4) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("工具调用 \(agent.toolCallCount) 次")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private func normalizedStageKey(_ stage: String) -> String {
        stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isCompletedStatus(_ status: String) -> Bool {
        status == "completed" || status == "done" || status == "success" || status == "succeeded" || status == "已完成" || status == "完成"
    }

    private func stageStatusColor(_ status: String) -> Color {
        let normalized = normalizedStageStatus(status)
        switch normalized {
        case "running":
            return .orange
        case _ where isCompletedStatus(normalized):
            return .green
        default:
            return .secondary
        }
    }

    private func workspaceStatusColor(_ status: String) -> Color {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "running", "进行中":
            return .orange
        case "idle", "空闲":
            return .green
        case "queued", "排队中":
            return .blue
        case "stopped", "已停止", "error", "failed":
            return .red
        default:
            return .secondary
        }
    }

    private func canOpenStageChat(_ status: String) -> Bool {
        let normalized = normalizedStageStatus(status)
        return normalized == "running" ||
            normalized == "done" ||
            normalized == "completed" ||
            normalized == "已完成" ||
            normalized == "完成" ||
            normalized == "success" ||
            normalized == "succeeded"
    }

    private func normalizedStageStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func stageOrder(for stage: String) -> Int {
        let normalized = normalizedStageKey(stage)
        if let index = evolutionStageOrder.firstIndex(of: normalized) {
            return index
        }
        return evolutionStageOrder.count
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
        case "direction":
            return "arrow.triangle.branch"
        case "plan":
            return "map"
        case "implement":
            return "hammer"
        case "code":
            return "chevron.left.forwardslash.chevron.right"
        case "verify":
            return "checkmark.seal"
        case "judge":
            return "scalemass"
        case "report":
            return "doc.text"
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
        let loopRoundLimit = max(1, Int(loopRoundLimitText) ?? 1)
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
            loopRoundLimit: loopRoundLimit,
            profiles: profiles
        )
    }

    private func syncStartOptionsFromCurrentItem() {
        guard let item = currentItem else {
            loopRoundLimitText = "1"
            return
        }
        loopRoundLimitText = "\(max(1, item.loopRoundLimit))"
    }
}


struct EvolutionSessionDrawerView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isSessionViewerPresented: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(appState.evolutionReplayTitle)
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    isSessionViewerPresented = false
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
            } else if appState.evolutionReplayStore.messages.isEmpty {
                Text("暂无消息")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                MessageListView(
                    messages: appState.evolutionReplayStore.messages,
                    sessionToken: appState.evolutionReplayStore.currentSessionId,
                    onQuestionReply: { _, _ in },
                    onQuestionReject: { _ in },
                    onQuestionReplyAsMessage: { _ in },
                    onOpenLinkedSession: nil
                )
                .environmentObject(appState.evolutionReplayStore)
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
