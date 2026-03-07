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
                        // macOS 端 AI 聊天已常驻在 CenterContentView 上方，此处不再渲染
                        EmptyView()
                    case .evolution:
                        // Mac 端进化页面已移至右侧面板，此处不再渲染
                        EmptyView()
                    case .evidence:
                        // Mac 端证据页面已移至右侧面板，此处不再渲染
                        EmptyView()
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
    @StateObject private var searchState = TerminalSearchState()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                MacSwiftTermTerminalView(appState: appState, tabId: tab.id, searchState: searchState)
                    .background(Color.black)
                if searchState.isVisible {
                    TerminalSearchBarView(searchState: searchState)
                        .padding(.top, 8)
                        .padding(.horizontal, 8)
                        .zIndex(1)
                }
            }
            .background(terminalSearchShortcuts)
            TerminalStatusBar()
                .environmentObject(appState)
        }
        .onAppear {
            appState.ensureTerminalForTab(tab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalSearchRequested)) { note in
            guard let requestedTabId = note.object as? UUID, requestedTabId == tab.id else { return }
            searchState.show()
        }
    }

    @ViewBuilder
    private var terminalSearchShortcuts: some View {
        Button("Terminal Search") {
            searchState.show()
        }
        .keyboardShortcut("f", modifiers: .command)
        .hidden()

        if searchState.isVisible {
            Button("Close Terminal Search") {
                searchState.close()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .hidden()
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
    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var matchRanges: [Range<String.Index>] = []
    @State private var currentMatchIndex: Int = -1
    @State private var isCaseSensitive: Bool = false
    @State private var useRegex: Bool = false

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
                        let textBinding = editorBinding(globalKey: globalKey)
                        VStack(spacing: 0) {
                            if editorStore.showFindReplacePanel && appState.activeEditorPath == path {
                                findReplacePanel(textBinding: textBinding)
                                Divider()
                            }

                            NativeCodeEditorView(
                                text: textBinding,
                                highlightedLine: $highlightedLine,
                                onUndoRedoStateChange: { canUndo, canRedo in
                                    editorStore.updateUndoRedoState(canUndo: canUndo, canRedo: canRedo)
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onAppear {
                                refreshMatches(for: textBinding.wrappedValue, keepSelection: false)
                            }
                        }
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
        .onChange(of: findText) { _, _ in
            refreshMatches(for: currentEditorText(), keepSelection: false)
        }
        .onChange(of: isCaseSensitive) { _, _ in
            refreshMatches(for: currentEditorText(), keepSelection: false)
        }
        .onChange(of: useRegex) { _, _ in
            refreshMatches(for: currentEditorText(), keepSelection: false)
        }
        .onChange(of: editorStore.showFindReplacePanel) { _, isShowing in
            guard isShowing, appState.activeEditorPath == path else { return }
            refreshMatches(for: currentEditorText(), keepSelection: false)
        }
        .onChange(of: appState.currentGlobalWorkspaceKey) { _, _ in
            openDocumentIfNeeded(force: true)
        }
        .onChange(of: editorStore.pendingEditorReveal?.path) { _, _ in
            consumePendingRevealIfNeeded()
        }
    }

    @ViewBuilder
    private func findReplacePanel(textBinding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            TextField("editor.find.placeholder".localized, text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
            TextField("editor.replace.placeholder".localized, text: $replaceText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)

            Button("Aa") {
                isCaseSensitive.toggle()
            }
            .buttonStyle(.bordered)
            .tint(isCaseSensitive ? .accentColor : .secondary)

            Button(".*") {
                useRegex.toggle()
            }
            .buttonStyle(.bordered)
            .tint(useRegex ? .accentColor : .secondary)

            Button {
                navigateToPreviousMatch(in: textBinding.wrappedValue)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(matchRanges.isEmpty)

            Button {
                navigateToNextMatch(in: textBinding.wrappedValue)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(matchRanges.isEmpty)

            Text(matchStatusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 52, alignment: .trailing)

            Button("editor.replace.one".localized) {
                replaceCurrent(in: textBinding)
            }
            .buttonStyle(.bordered)
            .disabled(currentMatchIndex < 0)

            Button("editor.replace.all".localized) {
                replaceAll(in: textBinding)
            }
            .buttonStyle(.borderedProminent)
            .disabled(matchRanges.isEmpty)

            Button {
                editorStore.showFindReplacePanel = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var matchStatusText: String {
        guard !matchRanges.isEmpty, currentMatchIndex >= 0 else { return "0/0" }
        return "\(currentMatchIndex + 1)/\(matchRanges.count)"
    }

    private func editorBinding(globalKey: String) -> Binding<String> {
        Binding(
            get: { appState.getEditorDocument(globalWorkspaceKey: globalKey, path: path)?.content ?? "" },
            set: { appState.updateEditorDocumentContent(globalWorkspaceKey: globalKey, path: path, content: $0) }
        )
    }

    private func currentEditorText() -> String {
        guard let globalKey = appState.currentGlobalWorkspaceKey else { return "" }
        return appState.getEditorDocument(globalWorkspaceKey: globalKey, path: path)?.content ?? ""
    }

    private func refreshMatches(for text: String, keepSelection: Bool) {
        let ranges = findRanges(in: text)
        matchRanges = ranges
        guard !ranges.isEmpty else {
            currentMatchIndex = -1
            return
        }

        if keepSelection, currentMatchIndex >= 0 {
            currentMatchIndex = min(currentMatchIndex, ranges.count - 1)
        } else {
            currentMatchIndex = 0
        }
        revealCurrentMatch(in: text)
    }

    private func navigateToNextMatch(in text: String) {
        guard !findText.isEmpty else { return }
        if matchRanges.isEmpty {
            refreshMatches(for: text, keepSelection: false)
            return
        }
        currentMatchIndex = currentMatchIndex < 0 ? 0 : (currentMatchIndex + 1) % matchRanges.count
        revealCurrentMatch(in: text)
    }

    private func navigateToPreviousMatch(in text: String) {
        guard !findText.isEmpty else { return }
        if matchRanges.isEmpty {
            refreshMatches(for: text, keepSelection: false)
            return
        }
        if currentMatchIndex < 0 {
            currentMatchIndex = 0
        } else {
            currentMatchIndex = (currentMatchIndex - 1 + matchRanges.count) % matchRanges.count
        }
        revealCurrentMatch(in: text)
    }

    private func replaceCurrent(in textBinding: Binding<String>) {
        guard currentMatchIndex >= 0, currentMatchIndex < matchRanges.count else { return }
        var text = textBinding.wrappedValue
        let range = matchRanges[currentMatchIndex]
        text.replaceSubrange(range, with: replaceText)
        textBinding.wrappedValue = text
        refreshMatches(for: text, keepSelection: true)
    }

    private func replaceAll(in textBinding: Binding<String>) {
        guard !matchRanges.isEmpty else { return }
        var text = textBinding.wrappedValue
        for range in matchRanges.reversed() {
            text.replaceSubrange(range, with: replaceText)
        }
        textBinding.wrappedValue = text
        refreshMatches(for: text, keepSelection: false)
    }

    private func revealCurrentMatch(in text: String) {
        guard currentMatchIndex >= 0, currentMatchIndex < matchRanges.count else { return }
        let range = matchRanges[currentMatchIndex]
        let line = 1 + text[..<range.lowerBound].reduce(into: 0) { partial, char in
            if char == "\n" { partial += 1 }
        }
        highlightedLine = line
    }

    private func findRanges(in text: String) -> [Range<String.Index>] {
        guard !findText.isEmpty else { return [] }

        if useRegex, let regex = try? NSRegularExpression(
            pattern: findText,
            options: isCaseSensitive ? [] : [.caseInsensitive]
        ) {
            let nsText = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap {
                Range($0.range, in: text)
            }
        }

        var ranges: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        while let range = text.range(of: findText, options: options, range: searchRange) {
            ranges.append(range)
            if range.upperBound == text.endIndex { break }
            searchRange = range.upperBound..<text.endIndex
        }
        return ranges
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

            Button("editor.findReplace".localized) {
                editorStore.showFindReplacePanel = true
            }
            .buttonStyle(.borderless)

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
                Button("覆盖保存") {
                    guard let workspace = appState.selectedWorkspaceKey else { return }
                    appState.saveEditorDocument(project: appState.selectedProjectName, workspace: workspace, path: path)
                }
                .buttonStyle(.borderless)
                Button("比较差异") {
                    appState.addDiffTab(workspaceKey: globalKey, path: path, mode: .working)
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
    var onUndoRedoStateChange: ((Bool, Bool) -> Void)?

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
            notifyUndoRedoStateChange()
        }

        // MARK: - 撤销/重做

        func performUndo() {
            guard let textView, let undoManager = textView.undoManager, undoManager.canUndo else { return }
            undoManager.undo()
            parent.text = textView.string
            notifyUndoRedoStateChange()
        }

        func performRedo() {
            guard let textView, let undoManager = textView.undoManager, undoManager.canRedo else { return }
            undoManager.redo()
            parent.text = textView.string
            notifyUndoRedoStateChange()
        }

        func notifyUndoRedoStateChange() {
            guard let textView, let undoManager = textView.undoManager else {
                parent.onUndoRedoStateChange?(false, false)
                return
            }
            parent.onUndoRedoStateChange?(undoManager.canUndo, undoManager.canRedo)
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
    @State private var showDetailSheet: Bool = false
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
        .sheet(isPresented: $showDetailSheet) {
            if let item = currentSelectedItem {
                EvidenceDetailSheetView(
                    item: item,
                    selectedTab: selectedTab,
                    itemLoading: $itemLoading,
                    itemPaging: $itemPaging,
                    itemError: $itemError,
                    itemTextChunks: $itemTextChunks,
                    itemTextNextOffset: $itemTextNextOffset,
                    itemTextHasMore: $itemTextHasMore,
                    itemImage: $itemImage,
                    itemByteCount: $itemByteCount,
                    onLoadNextPage: { loadNextTextPageIfNeeded(for: item) }
                )
            }
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
        HStack(spacing: 8) {
            if let actionMessage, !actionMessage.isEmpty {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                refreshEvidence()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("刷新")
            Button("重建") {
                rebuildEvidence()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(workspace == nil || workspace?.isEmpty == true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                    HStack(spacing: 4) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 11))
                        Text("\(tab.displayName)(\(itemsCount(for: tab)))")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
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
                        .frame(height: 16)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
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
        evidenceListPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var evidenceListPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(currentTabDeviceTypes, id: \.self) { deviceType in
                    deviceSection(deviceType: deviceType, items: items(for: deviceType))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
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
        return LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 8)
            ],
            spacing: 8
        ) {
            ForEach(items, id: \.itemID) { item in
                screenshotThumbnail(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    /// 截图缩略图卡片
    private func screenshotThumbnail(item: EvidenceItemInfoV2) -> some View {
        let thumbnailHeight: CGFloat = 80
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedScreenshotID = item.itemID
                loadItem(item)
                showDetailSheet = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // 缩略图区域
                ZStack {
                    if let thumbnail = screenshotThumbnails[item.itemID] {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(maxWidth: .infinity)
                .frame(height: thumbnailHeight)
                .clipped()
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
            loadItem(item)
            showDetailSheet = true
        } label: {
            HStack(spacing: 8) {
                // 文件图标
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                
                // 内容
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Text(item.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                selectedLogID == item.itemID
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    /// 当前选中的条目
    private var currentSelectedItem: EvidenceItemInfoV2? {
        let selectedID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        if let id = selectedID {
            return currentTabItems.first { $0.itemID == id }
        }
        return nil
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

// MARK: - 证据详情 Sheet

/// 证据详情弹出视图（用于右侧面板点击证据项后展示）
struct EvidenceDetailSheetView: View {
    let item: EvidenceItemInfoV2
    let selectedTab: EvidenceTabType
    @Binding var itemLoading: Bool
    @Binding var itemPaging: Bool
    @Binding var itemError: String?
    @Binding var itemTextChunks: [String]
    @Binding var itemTextNextOffset: UInt64
    @Binding var itemTextHasMore: Bool
    @Binding var itemImage: NSImage?
    @Binding var itemByteCount: Int
    var onLoadNextPage: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                    Text(item.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if item.sizeBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.sizeBytes), countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // 内容区域
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 500, idealWidth: 700, minHeight: 400, idealHeight: 600)
    }

    @ViewBuilder
    private var detailContent: some View {
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
            .padding(16)
        } else if !itemTextChunks.isEmpty {
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
                            onLoadNextPage()
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(10)
            .padding(16)
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
}

struct EvolutionEditableProfile: Identifiable, Equatable {
    let id: String
    let stage: String
    var aiTool: AIChatTool
    var mode: String
    var providerID: String
    var modelID: String
    var configOptions: [String: Any]

    init(
        id: String,
        stage: String,
        aiTool: AIChatTool,
        mode: String,
        providerID: String,
        modelID: String,
        configOptions: [String: Any] = [:]
    ) {
        self.id = id
        self.stage = stage
        self.aiTool = aiTool
        self.mode = mode
        self.providerID = providerID
        self.modelID = modelID
        self.configOptions = configOptions
    }

    static func == (lhs: EvolutionEditableProfile, rhs: EvolutionEditableProfile) -> Bool {
        guard lhs.id == rhs.id,
              lhs.stage == rhs.stage,
              lhs.aiTool == rhs.aiTool,
              lhs.mode == rhs.mode,
              lhs.providerID == rhs.providerID,
              lhs.modelID == rhs.modelID else {
            return false
        }
        return NSDictionary(dictionary: lhs.configOptions).isEqual(NSDictionary(dictionary: rhs.configOptions))
    }
}

struct EvolutionTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var loopRoundLimitText: String = "1"
    @State private var lastLoopRoundWorkspaceContext: String = ""
    @State private var isSessionViewerPresented: Bool = false
    @State private var viewerStage: String?
    @State private var isBlockerSheetPresented: Bool = false
    @State private var isHandoffSheetPresented: Bool = false
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
    private var workspaceContextKey: String {
        let normalizedWorkspace = appState.normalizeEvolutionWorkspaceName(workspace ?? "")
        return "\(project)/\(normalizedWorkspace)"
    }

    private var currentItem: EvolutionWorkspaceItemV2? {
        guard let workspace else { return nil }
        return appState.evolutionItem(project: project, workspace: workspace)
    }

    private var controlCapability: EvolutionControlCapability {
        appState.evolutionControlCapability(project: project, workspace: workspace)
    }

    /// 主控制按钮：运行中显示“停止”，其他状态显示“开始”。
    private var primaryControlShowsStop: Bool {
        controlCapability.canStop || controlCapability.isStopPending
    }

    private var canTriggerPrimaryControlAction: Bool {
        controlCapability.canStart || controlCapability.canStop
    }

    private var primaryControlButtonTitle: String {
        primaryControlShowsStop
            ? "evolution.page.action.stop".localized
            : "evolution.page.action.startManual".localized
    }

    private var primaryControlButtonSymbol: String {
        if primaryControlShowsStop {
            return controlCapability.isStopPending ? "clock" : "stop.fill"
        }
        return controlCapability.isStartPending ? "clock" : "play.fill"
    }

    private var primaryControlButtonTint: Color {
        primaryControlShowsStop ? .red : .green
    }

    private let evolutionStageOrder: [String] = [
        "direction",
        "plan",
        "implement_general",
        "implement_visual",
        "implement_advanced",
        "verify",
        "auto_commit",
    ]

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
        }
        #if os(iOS)
        .sheet(isPresented: $isSessionViewerPresented) {
            EvolutionSessionDrawerView(isSessionViewerPresented: $isSessionViewerPresented)
        }
        #endif
        .sheet(isPresented: $isBlockerSheetPresented) {
            blockerSheet
        }
        .sheet(isPresented: $isHandoffSheetPresented) {
            handoffSheet
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
                    Text("evolution.page.blocker.detectedHint".localized)
                        .font(.headline)
                    Text(
                        String(
                            format: "evolution.page.blocker.triggerAndFile".localized,
                            blocking.trigger,
                            blocking.blockerFilePath
                        )
                    )
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
                                    Picker("evolution.page.blocker.option".localized, selection: bindingOption(item.blockerID)) {
                                        Text("evolution.page.blocker.choose".localized).tag("")
                                        ForEach(item.options, id: \.optionID) { option in
                                            Text(option.label).tag(option.optionID)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }
                                if item.allowCustomInput || item.options.isEmpty {
                                    TextField("evolution.page.blocker.answerInput".localized, text: bindingAnswer(item.blockerID))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    HStack {
                        Button("common.close".localized) {
                            isBlockerSheetPresented = false
                        }
                        Spacer()
                        Button("evolution.page.blocker.submitSelected".localized) {
                            submitBlockerAnswers(blocking)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("evolution.page.blocker.noTasks".localized)
                    Button("common.close".localized) {
                        isBlockerSheetPresented = false
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 640, minHeight: 420)
            .navigationTitle("evolution.page.blocker.sheetTitle".localized)
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
            Text("evolution.page.title".localized)
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
            Button {
                refreshData()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("evolution.page.refreshStatusHelp".localized)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var schedulerCard: some View {
        HStack(spacing: 12) {
            schedulerStatCard(
                title: "evolution.page.scheduler.activation".localized,
                value: localizedSchedulerActivationDisplay(appState.evolutionScheduler.activationState),
                icon: "power",
                color: .green
            )
            schedulerStatCard(
                title: "evolution.page.scheduler.maxParallel".localized,
                value: "\(appState.evolutionScheduler.maxParallelWorkspaces)",
                icon: "square.stack.3d.up",
                color: .blue
            )
            schedulerStatCard(
                title: "evolution.page.scheduler.running".localized,
                value: "\(appState.evolutionScheduler.runningCount)",
                icon: "play.circle.fill",
                color: .orange
            )
            schedulerStatCard(
                title: "evolution.page.scheduler.queued".localized,
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
            VStack(alignment: .leading, spacing: 14) {
                if let workspace {
                    if let item = currentItem {
                        // 状态信息网格：两列布局，紧凑展示
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)
                            ],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            workspaceInfoCell(
                                label: "evolution.page.workspace.currentWorkspace".localized,
                                value: "\(project)/\(workspace)",
                                icon: "folder.fill",
                                color: .blue
                            )
                            workspaceStatusCell(item: item)
                            workspaceInfoCell(
                                label: "evolution.page.workspace.currentStage".localized,
                                value: stageDisplayName(item.currentStage),
                                icon: "flag.fill",
                                color: .purple
                            )
                            workspaceInfoCell(
                                label: "evolution.page.workspace.loopRound".localized,
                                value: "\(item.globalLoopRound)/\(max(1, item.loopRoundLimit))",
                                icon: "arrow.triangle.2.circlepath",
                                color: .teal
                            )
                            workspaceInfoCell(
                                label: "evolution.page.workspace.verifyRound".localized,
                                value: "\(item.verifyIteration)/\(item.verifyIterationLimit)",
                                icon: "checkmark.shield.fill",
                                color: .indigo
                            )
                            workspaceInfoCell(
                                label: "evolution.page.workspace.activeAgents".localized,
                                value: item.activeAgents.isEmpty
                                    ? "evolution.page.workspace.noActiveAgents".localized
                                    : item.activeAgents.joined(separator: ", "),
                                icon: "person.fill",
                                color: .orange
                            )
                        }
                    } else {
                        // 未启动状态
                        workspaceInfoCell(
                            label: "evolution.page.workspace.currentWorkspace".localized,
                            value: "\(project)/\(workspace)",
                            icon: "folder.fill",
                            color: .blue
                        )
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.secondary.opacity(0.5))
                                .frame(width: 8, height: 8)
                            Text("evolution.page.workspace.notStarted".localized)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // 控制区域
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            TextField("evolution.page.workspace.loopRoundInput".localized, text: $loopRoundLimitText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .disabled(!controlCapability.canStart && !controlCapability.canStop)
                                .onChange(of: loopRoundLimitText) { _, newValue in
                                    // 运行中时实时同步轮次调整到服务端
                                    guard controlCapability.canStop,
                                          let newLimit = Int(newValue), newLimit >= 1,
                                          let workspace = Optional(workspace), !workspace.isEmpty
                                    else { return }
                                    appState.adjustEvolutionLoopRound(
                                        project: project,
                                        workspace: workspace,
                                        loopRoundLimit: newLimit
                                    )
                                }
                            Text("evolution.page.workspace.verifyLoopFixed".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 6) {
                            Button {
                                triggerPrimaryControlAction()
                            } label: {
                                Label(primaryControlButtonTitle, systemImage: primaryControlButtonSymbol)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(primaryControlButtonTint)
                            .disabled(!canTriggerPrimaryControlAction)
                            Button {
                                guard controlCapability.canResume else { return }
                                appState.resumeEvolution(project: project, workspace: workspace)
                            } label: {
                                if controlCapability.isResumePending {
                                    Label("evolution.page.action.resume".localized, systemImage: "clock")
                                } else {
                                    Label("evolution.page.action.resume".localized, systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!controlCapability.canResume)
                            Divider().frame(height: 16)
                            Button {
                                loadHandoffAndPresent()
                            } label: {
                                Label("evolution.page.action.previewHandoff".localized, systemImage: "doc.text")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(currentItem == nil)
                        }
                    }
                } else {
                    Text("evolution.page.workspace.selectWorkspaceFirst".localized)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("evolution.page.workspace.section".localized, systemImage: "gearshape.2")
        }
    }

    /// 工作空间信息单元格
    private func workspaceInfoCell(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// 状态单元格（带指示灯）
    private func workspaceStatusCell(item: EvolutionWorkspaceItemV2) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(workspaceStatusColor(item.status))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .fill(workspaceStatusColor(item.status).opacity(0.3))
                        .frame(width: 28, height: 28)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("evolution.page.workspace.status".localized)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(localizedWorkspaceStatusDisplay(item.status))
                    .font(.callout)
                    .fontWeight(.medium)
            }
        }
    }

    // MARK: - Handoff 文档预览

    private func loadHandoffAndPresent() {
        guard let item = currentItem else { return }
        appState.requestEvolutionHandoff(project: project, workspace: item.workspace, cycleID: item.cycleID)
        isHandoffSheetPresented = true
    }

    @ViewBuilder
    private func handoffSection(
        titleKey: String,
        icon: String,
        color: Color,
        items: [String]
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(titleKey.localized, systemImage: icon)
                    .font(.headline)
                    .foregroundColor(color)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(color.opacity(0.8))
                                .frame(width: 6, height: 6)
                                .padding(.top, 6)
                            Text(item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.08))
            )
        }
    }

    private var handoffSheet: some View {
        NavigationStack {
            Group {
                if appState.evolutionHandoffLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("evolution.page.handoff.loading".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = appState.evolutionHandoffError {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let handoff = appState.evolutionHandoff {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            handoffSection(
                                titleKey: "evolution.page.handoff.completed",
                                icon: "checkmark.circle.fill",
                                color: .green,
                                items: handoff.completed
                            )
                            handoffSection(
                                titleKey: "evolution.page.handoff.risks",
                                icon: "exclamationmark.triangle.fill",
                                color: .orange,
                                items: handoff.risks
                            )
                            handoffSection(
                                titleKey: "evolution.page.handoff.next",
                                icon: "arrow.right.circle.fill",
                                color: .blue,
                                items: handoff.next
                            )
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("evolution.page.handoff.empty".localized)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("evolution.page.handoff.title".localized)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        loadHandoffAndPresent()
                    } label: {
                        Label("evolution.page.handoff.refresh".localized, systemImage: "arrow.clockwise")
                    }
                    .disabled(currentItem == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isHandoffSheetPresented = false
                    } label: {
                        Text("common.close".localized)
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var stageSectionsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                let sortedAgents = sortedAgents()
                if sortedAgents.isEmpty {
                    Text("evolution.page.agentList.empty".localized)
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
            Label("evolution.page.agentList.section".localized, systemImage: "person.3.sequence")
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
                    model: model,
                    configOptions: item.configOptions
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
                        status: "not_started",
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
        let displayStatusText = localizedStageStatusDisplay(statusText)
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



                if canOpenStageChat(stage: agent.stage, status: statusText) {
                    Button {
                        openStageChat(stage: agent.stage)
                    } label: {
                        HStack(spacing: 4) {
                            Text(displayStatusText)
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
                    Text(displayStatusText)
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
                Text(String(format: "evolution.page.toolCallCount".localized, agent.toolCallCount))
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
                .fill(isRunning ? Color(NSColor.controlBackgroundColor) : Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isRunning ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.12), lineWidth: isRunning ? 2 : 1)
        )
    }


    private func refreshData() {
        appState.requestEvolutionSnapshot()
    }

    private func normalizedStageKey(_ stage: String) -> String {
        let normalized = stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "implement" {
            return "implement_general"
        }
        return normalized
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

    private func canOpenStageChat(stage: String, status: String) -> Bool {
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
        guard !trimmed.isEmpty else { return "evolution.stage.unnamed".localized }
        switch trimmed.lowercased() {
        case "direction":
            return "evolution.stage.direction".localized
        case "plan":
            return "evolution.stage.plan".localized
        case "implement_general":
            return "evolution.stage.implementGeneral".localized
        case "implement_visual":
            return "evolution.stage.implementVisual".localized
        case "implement_advanced":
            return "evolution.stage.implementAdvanced".localized
        case "implement":
            return "evolution.stage.implementGeneral".localized
        case "verify":
            return "evolution.stage.verify".localized
        case "auto_commit":
            return "evolution.stage.autoCommit".localized
        default:
            return trimmed
        }
    }

    private func localizedSchedulerActivationDisplay(_ status: String) -> String {
        let normalized = normalizedStageStatus(status)
        switch normalized {
        case "active", "激活":
            return "evolution.status.active".localized
        default:
            return status
        }
    }

    private func localizedWorkspaceStatusDisplay(_ status: String) -> String {
        let normalized = normalizedStageStatus(status)
        switch normalized {
        case "running", "进行中":
            return "evolution.status.running".localized
        case "queued", "排队中":
            return "evolution.status.queued".localized
        case "idle", "空闲":
            return "evolution.status.idle".localized
        case "stopped", "已停止":
            return "evolution.status.stopped".localized
        case "error", "failed", "失败":
            return "evolution.status.failed".localized
        case "completed", "done", "success", "succeeded", "已完成", "完成":
            return "evolution.status.completed".localized
        case "interrupted":
            return "evolution.status.interrupted".localized
        case "failed_exhausted":
            return "evolution.status.failedExhausted".localized
        case "failed_system":
            return "evolution.status.failedSystem".localized
        default:
            return status
        }
    }

    private func localizedStageStatusDisplay(_ status: String) -> String {
        let normalized = normalizedStageStatus(status)
        switch normalized {
        case "running":
            return "evolution.status.running".localized
        case "queued":
            return "evolution.status.queued".localized
        case "idle":
            return "evolution.status.idle".localized
        case "stopped":
            return "evolution.status.stopped".localized
        case "completed", "done", "success", "succeeded", "已完成", "完成":
            return "evolution.status.completed".localized
        case "error", "failed", "失败":
            return "evolution.status.failed".localized
        case "not_started", "not started", "未启动", "未运行":
            return "evolution.status.notStarted".localized
        case "skipped", "skip", "已跳过":
            return "evolution.status.skipped".localized
        default:
            return status
        }
    }

    private func stageIconName(_ stage: String) -> String {
        switch stage.lowercased() {
        case "direction":
            return "arrow.triangle.branch"
        case "plan":
            return "map"
        case "implement_general", "implement":
            return "hammer"
        case "implement_visual":
            return "paintbrush"
        case "implement_advanced":
            return "wand.and.stars"
        case "code":
            return "chevron.left.forwardslash.chevron.right"
        case "verify":
            return "checkmark.seal"
        case "auto_commit":
            return "sparkles"
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
        #if os(iOS)
        isSessionViewerPresented = true
        #endif
    }

    private func startCurrentWorkspace() {
        guard let workspace else { return }
        guard controlCapability.canStart else { return }
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
                model: model,
                configOptions: item.configOptions
            )
        }
        appState.startEvolution(
            project: project,
            workspace: workspace,
            loopRoundLimit: loopRoundLimit,
            profiles: profiles
        )
    }

    private func triggerPrimaryControlAction() {
        guard let workspace else { return }
        if controlCapability.canStop {
            appState.stopEvolution(project: project, workspace: workspace)
            return
        }
        if controlCapability.canStart {
            startCurrentWorkspace()
        }
    }

    private func syncStartOptionsFromCurrentItem() {
        guard workspaceReady else { return }
        if let item = currentItem {
            loopRoundLimitText = "\(max(1, item.loopRoundLimit))"
            lastLoopRoundWorkspaceContext = workspaceContextKey
            return
        }
        guard workspaceContextKey != lastLoopRoundWorkspaceContext else { return }
        loopRoundLimitText = "1"
        lastLoopRoundWorkspaceContext = workspaceContextKey
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
                Button("common.close".localized) {
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
                Text("evolution.page.session.noMessages".localized)
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
