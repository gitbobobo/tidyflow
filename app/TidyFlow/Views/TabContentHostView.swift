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

struct EvidenceTabView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedItemID: String?
    @State private var itemLoading: Bool = false
    @State private var itemError: String?
    @State private var itemTextContent: String?
    @State private var itemImage: NSImage?
    @State private var itemByteCount: Int = 0
    @State private var actionMessage: String?

    private var project: String { appState.selectedProjectName }
    private var workspace: String? { appState.selectedWorkspaceKey }

    private var snapshot: EvolutionEvidenceSnapshotV2? {
        guard let workspace else { return nil }
        return appState.evidenceSnapshot(project: project, workspace: workspace)
    }

    private var snapshotLoading: Bool {
        guard let workspace else { return false }
        let key = appState.globalWorkspaceKey(projectName: project, workspaceName: appState.normalizeEvolutionWorkspaceName(workspace))
        return appState.evolutionEvidenceLoadingByWorkspace[key] ?? false
    }

    private var snapshotError: String? {
        guard let workspace else { return nil }
        let key = appState.globalWorkspaceKey(projectName: project, workspaceName: appState.normalizeEvolutionWorkspaceName(workspace))
        return appState.evolutionEvidenceErrorByWorkspace[key]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            refreshEvidence()
        }
        .onChange(of: appState.selectedWorkspaceKey) { _, _ in
            selectedItemID = nil
            clearItemPreview()
            refreshEvidence()
        }
        .onChange(of: appState.selectedProjectName) { _, _ in
            selectedItemID = nil
            clearItemPreview()
            refreshEvidence()
        }
        .onChange(of: appState.connectionState) { _, state in
            guard state == .connected else { return }
            refreshEvidence()
        }
        .onChange(of: snapshot?.updatedAt) { _, _ in
            syncSelectionIfNeeded()
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

    @ViewBuilder
    private var content: some View {
        if workspace == nil {
            VStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("请先选择工作空间")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshotLoading && snapshot == nil {
            ProgressView("读取证据中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshotError, snapshot == nil {
            VStack(spacing: 10) {
                Text(snapshotError)
                    .foregroundColor(.red)
                Button("重试") {
                    refreshEvidence()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot == nil {
            VStack(spacing: 10) {
                Text("暂无证据数据")
                    .foregroundColor(.secondary)
                Button("刷新") {
                    refreshEvidence()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        statusCard(snapshot)
                        ForEach(displayPlatforms(in: snapshot), id: \.self) { platform in
                            GroupBox(platform.uppercased()) {
                                let rows = snapshot.items.filter { $0.platform == platform }
                                if rows.isEmpty {
                                    Text("暂无条目")
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    VStack(spacing: 8) {
                                        ForEach(rows, id: \.itemID) { item in
                                            evidenceRow(item)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(minWidth: 340, maxWidth: 440)

                Divider()

                detailPane(snapshot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func statusCard(_ snapshot: EvolutionEvidenceSnapshotV2) -> some View {
        GroupBox("状态") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("证据目录") {
                    Text(snapshot.evidenceRoot)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                }
                LabeledContent("索引文件") {
                    Text(snapshot.indexFile)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                }
                LabeledContent("索引状态") {
                    Text(snapshot.indexExists ? "存在" : "缺失")
                        .foregroundColor(snapshot.indexExists ? .green : .orange)
                }
                LabeledContent("子系统") {
                    Text(snapshot.detectedSubsystems.isEmpty ? "未识别" : snapshot.detectedSubsystems.map(\.id).joined(separator: ", "))
                        .lineLimit(2)
                }
                LabeledContent("平台") {
                    Text(snapshot.detectedPlatforms.isEmpty ? "未识别" : snapshot.detectedPlatforms.joined(separator: ", "))
                        .lineLimit(2)
                }
                if !snapshot.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("告警")
                            .font(.subheadline)
                        ForEach(snapshot.issues.indices, id: \.self) { idx in
                            let issue = snapshot.issues[idx]
                            Text("• [\(issue.level)] \(issue.message)")
                                .font(.caption)
                                .foregroundColor(issue.level.lowercased() == "warning" ? .orange : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func evidenceRow(_ item: EvolutionEvidenceItemInfoV2) -> some View {
        Button {
            selectedItemID = item.itemID
            loadItem(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("#\(item.order)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(item.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Text(item.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: item.exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(item.exists ? .green : .orange)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedItemID == item.itemID ? Color.accentColor.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detailPane(_ snapshot: EvolutionEvidenceSnapshotV2) -> some View {
        let selected = snapshot.items.first { $0.itemID == selectedItemID } ?? snapshot.items.first
        if let selected {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.title)
                        .font(.title3)
                    Text(selected.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(selected.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                if itemLoading {
                    ProgressView("加载内容中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if let itemError {
                    Text(itemError)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if let itemImage {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: itemImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .background(Color.black.opacity(0.04))
                    .cornerRadius(10)
                } else if let itemTextContent {
                    ScrollView {
                        Text(itemTextContent)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(Color.black.opacity(0.03))
                    .cornerRadius(10)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("无法预览该证据")
                        Text("MIME: \(selected.mimeType)")
                        Text("大小: \(itemByteCount) bytes")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .padding(16)
            .onAppear {
                if selectedItemID != selected.itemID {
                    selectedItemID = selected.itemID
                    loadItem(selected)
                } else if itemTextContent == nil && itemImage == nil && !itemLoading && itemError == nil {
                    loadItem(selected)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 38))
                    .foregroundColor(.secondary)
                Text("暂无证据条目")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func displayPlatforms(in snapshot: EvolutionEvidenceSnapshotV2) -> [String] {
        var ordered: [String] = []
        for platform in snapshot.detectedPlatforms where !ordered.contains(platform) {
            ordered.append(platform)
        }
        for item in snapshot.items where !ordered.contains(item.platform) {
            ordered.append(item.platform)
        }
        return ordered
    }

    private func syncSelectionIfNeeded() {
        guard let snapshot else { return }
        if let selectedItemID,
           snapshot.items.contains(where: { $0.itemID == selectedItemID }) {
            return
        }
        selectedItemID = snapshot.items.first?.itemID
        clearItemPreview()
        if let first = snapshot.items.first {
            loadItem(first)
        }
    }

    private func clearItemPreview() {
        itemLoading = false
        itemError = nil
        itemTextContent = nil
        itemImage = nil
        itemByteCount = 0
    }

    private func refreshEvidence() {
        guard let workspace, !workspace.isEmpty else { return }
        appState.requestEvolutionEvidenceSnapshot(project: project, workspace: workspace)
    }

    private func rebuildEvidence() {
        guard let workspace, !workspace.isEmpty else { return }
        appState.requestEvolutionEvidenceRebuildPrompt(project: project, workspace: workspace) { prompt, errorMessage in
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

    private func loadItem(_ item: EvolutionEvidenceItemInfoV2) {
        guard let workspace, !workspace.isEmpty else { return }
        itemLoading = true
        itemError = nil
        itemTextContent = nil
        itemImage = nil
        itemByteCount = 0

        appState.readEvolutionEvidenceItem(project: project, workspace: workspace, itemID: item.itemID) { payload, errorMessage in
            DispatchQueue.main.async {
                itemLoading = false
                if let payload {
                    let data = Data(payload.content)
                    itemByteCount = payload.content.count
                    if payload.mimeType.hasPrefix("image/") || item.evidenceType == "screenshot" {
                        if let image = NSImage(data: data) {
                            itemImage = image
                            return
                        }
                        itemError = "图片解码失败"
                        return
                    }
                    let text = String(data: data, encoding: .utf8) ?? String(decoding: payload.content, as: UTF8.self)
                    itemTextContent = text
                } else {
                    let error = errorMessage ?? "未知错误"
                    itemError = error
                }
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
    private let stageCardHeight: CGFloat = 96

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
                        Text("状态: 未启动")
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 12) {
                        TextField("循环轮次", text: $loopRoundLimitText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Text("验证循环固定 3 次")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                } else {
                    Text("请先选择工作空间")
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stageSectionsCard: some View {
        GroupBox("代理列表") {
            VStack(alignment: .leading, spacing: 12) {
                let sortedAgents = sortedAgents()
                if sortedAgents.isEmpty {
                    Text("暂无代理配置")
                        .foregroundColor(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 12, alignment: .top)],
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
                Text(agent.agent)
                    .font(.caption)
                    .foregroundColor(.secondary)
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

            Text("工具调用 \(agent.toolCallCount) 次")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: stageCardHeight, alignment: .topLeading)
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
