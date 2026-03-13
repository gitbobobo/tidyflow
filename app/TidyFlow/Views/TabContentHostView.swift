import SwiftUI
import ImageIO
import CoreGraphics

private let tfPanelBackgroundColor = Color.primary.opacity(0.03)
private let tfPanelChromeColor = Color.secondary.opacity(0.10)
private let tfTextSurfaceColor = Color.primary.opacity(0.06)
private let tfSeparatorColor = Color.secondary.opacity(0.16)

struct TabContentHostView: View {
    let appState: AppState
    @State private var projectionStore = BottomPanelProjectionStore()

    var body: some View {
        let _ = Self.debugPrintChangesIfNeeded()
        let projection = projectionStore.projection
        Group {
            if let globalKey = projection.workspaceKey {
                if let specialPage = projection.specialPage {
                    switch specialPage {
                    case .aiChat:
                        EmptyView()
                    case .evolution:
                        EmptyView()
                    case .evidence:
                        EmptyView()
                    }
                } else {
                    BottomPanelWorkspaceContent(
                        appState: appState,
                        workspaceKey: globalKey,
                        projection: projection
                    )
                }
            } else {
                NoActiveTabView()
            }
        }
        .tfRenderProbe("TabContentHostView", metadata: [
            "workspace": projection.workspaceKey ?? "none"
        ])
        .tfHotspotBaseline(
            .macBottomPanel,
            renderProbeName: "TabContentHostView",
            metadata: ["workspace": projection.workspaceKey ?? "none"]
        )
        .onAppear {
            projectionStore.bind(appState: appState)
        }
    }

    private static func debugPrintChangesIfNeeded() {
        SwiftUIPerformanceDebug.runPrintChangesIfEnabled(
            SwiftUIPerformanceDebug.tabContentHostPrintChangesEnabled
        ) {
#if DEBUG
            Self._printChanges()
#endif
        }
    }
}

private struct BottomPanelWorkspaceContent: View {
    let appState: AppState
    let workspaceKey: String
    let projection: BottomPanelProjection

    var body: some View {
        HStack(spacing: 0) {
            if projection.activeCategory != .projectConfig && projection.displayedTabs.count > 1 {
                BottomPanelVerticalTabList(
                    appState: appState,
                    workspaceKey: workspaceKey,
                    category: projection.activeCategory ?? .terminal,
                    tabs: projection.displayedTabs,
                    activeTabId: projection.activeTab?.id
                )
                Divider()
            }

            Group {
                if projection.activeCategory == .projectConfig {
                    ProjectConfigView()
                        .environmentObject(appState)
                } else if let activeTab = projection.activeTab {
                    content(for: activeTab)
                } else {
                    BottomPanelCategoryEmptyView(category: projection.activeCategory ?? .terminal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(for tab: TabModel) -> some View {
        switch tab.kind {
        case .terminal:
            TerminalContentView(tab: tab)
                .id(tab.id)
        case .editor:
            NativeEditorContentView(path: tab.payload)
                .id(tab.payload)
        case .diff:
            NativeDiffContentView(path: tab.payload)
                .id("\(tab.payload)-\(tab.diffMode ?? "working")")
        }
    }
}

private struct BottomPanelVerticalTabList: View {
    let appState: AppState
    let workspaceKey: String
    let category: BottomPanelCategory
    let tabs: [TabModel]
    let activeTabId: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(tabs) { tab in
                    BottomPanelInstanceItemView(
                        appState: appState,
                        tab: tab,
                        isActive: activeTabId == tab.id,
                        workspaceKey: workspaceKey
                    )
                }
            }
            .padding(4)
        }
        .frame(width: 172)
        .background(tfPanelBackgroundColor)
        .accessibilityIdentifier("tf.mac.bottomPanel.instance-list.\(category.rawValue)")
    }
}

private struct BottomPanelInstanceItemView: View {
    let appState: AppState

    let tab: TabModel
    let isActive: Bool
    let workspaceKey: String

    @State private var isHovered: Bool = false

    private var aiStatus: TerminalAIStatus {
        guard tab.kind == .terminal else { return .idle }
        guard let wsId = CoordinatorWorkspaceId.fromGlobalKey(workspaceKey) else { return .idle }
        return TerminalSessionSemantics.terminalAIStatus(
            fromCache: appState.coordinatorStateCache,
            workspaceId: wsId
        )
    }

    private var backgroundColor: Color {
        if isActive {
            return tfPanelChromeColor
        }
        if isHovered {
            return tfPanelChromeColor.opacity(0.5)
        }
        return .clear
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(displayTitle)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            trailingIndicators
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(backgroundColor)
        .clipShape(.rect(cornerRadius: 4))
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.activateTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if tab.kind == .terminal {
                Button(tab.isPinned ? "tab.unpin".localized : "tab.pin".localized) {
                    appState.toggleTerminalTabPinned(workspaceKey: workspaceKey, tabId: tab.id)
                }
                Divider()
            }

            Button("tab.close".localized) {
                appState.closeTab(workspaceKey: workspaceKey, tabId: tab.id)
            }

            if tab.kind == .editor {
                Divider()
                Button("editor.findReplace".localized) {
                    appState.activateTab(workspaceKey: workspaceKey, tabId: tab.id)
                    appState.editorStore.showFindReplacePanel = true
                }
                Button("editor.newFile".localized) {
                    appState.createNewEditorFile()
                }
                Button("editor.saveAs".localized) {
                    appState.activateTab(workspaceKey: workspaceKey, tabId: tab.id)
                    appState.requestSaveAsForActiveEditor()
                }
            }

            let otherTabs = appState.tabs(in: tab.bottomPanelCategory, workspaceKey: workspaceKey).filter { $0.id != tab.id }
            Button("tab.closeOthers".localized) {
                appState.closeOtherTabs(workspaceKey: workspaceKey, keepTabId: tab.id)
            }
            .disabled(otherTabs.isEmpty)

            let sameCategoryTabs = appState.tabs(in: tab.bottomPanelCategory, workspaceKey: workspaceKey)
            let tabIndex = sameCategoryTabs.firstIndex(where: { $0.id == tab.id }) ?? sameCategoryTabs.endIndex
            let hasTabsBelow = tabIndex < sameCategoryTabs.count - 1
            Button("tab.closeBelow".localized) {
                appState.closeTabsBelow(workspaceKey: workspaceKey, ofTabId: tab.id)
            }
            .disabled(!hasTabsBelow)

            Divider()

            Button("tab.closeSaved".localized) {
                appState.activateTab(workspaceKey: workspaceKey, tabId: tab.id)
                appState.closeSavedTabs(workspaceKey: workspaceKey)
            }

            Button("tab.closeAll".localized) {
                appState.activateTab(workspaceKey: workspaceKey, tabId: tab.id)
                appState.closeAllTabs(workspaceKey: workspaceKey)
            }
        }
        .accessibilityIdentifier("tf.mac.bottomPanel.instance.\(tab.id.uuidString)")
    }

    private var effectiveIconName: String {
        if tab.kind == .terminal, let commandIcon = tab.commandIcon {
            return commandIcon
        }
        return tab.kind.iconName
    }

    private var displayTitle: String {
        if tab.kind == .editor || tab.kind == .diff {
            return String(tab.payload.split(separator: "/").last ?? Substring(tab.title))
        }
        return tab.title
    }

    @ViewBuilder
    private var trailingIndicators: some View {
        HStack(spacing: 4) {
            if tab.kind == .terminal && tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            // AI 六态指示器：idle 不显示，其余五态实时展示工作区 AI 状态
            if tab.kind == .terminal && aiStatus.isVisible {
                Image(systemName: aiStatus.iconName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(aiStatus.color)
                    .help(aiStatus.hint)
                    .accessibilityLabel(aiStatus.hint)
            }

            if isActive || isHovered {
                Button {
                    appState.closeTab(workspaceKey: workspaceKey, tabId: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct BottomPanelCategoryEmptyView: View {
    let category: BottomPanelCategory

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tfPanelBackgroundColor)
        .accessibilityIdentifier("tf.mac.bottomPanel.empty.\(category.rawValue)")
    }

    private var title: String {
        switch category {
        case .terminal:
            return "bottomPanel.empty.terminal.title".localized
        case .edit:
            return "bottomPanel.empty.edit.title".localized
        case .diff:
            return "bottomPanel.empty.diff.title".localized
        case .projectConfig:
            return "bottomPanel.empty.projectConfig.title".localized
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
        .background(tfPanelBackgroundColor)
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
        .accessibilityIdentifier("tf.mac.terminal.container")
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
        .background(tfPanelChromeColor)
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
        .background(tfPanelBackgroundColor)
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
        .background(tfPanelChromeColor)
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
                            DiffLineRowView(line: line, onNavigate: {
                                if let target = line.targetLine {
                                    openEditorAtLine(target)
                                }
                            })
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
        .background(tfPanelChromeColor)
    }
}

struct NativeCodeEditorView: View {
    @Binding var text: String
    @Binding var highlightedLine: Int?
    var onUndoRedoStateChange: ((Bool, Bool) -> Void)?
    @State private var selection: TextSelection?
    @State private var revealedLineBanner: Int?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(tfTextSurfaceColor)
            .focused($isFocused)
            .overlay(alignment: .topTrailing) {
                if let revealedLineBanner {
                    Text("已定位到第 \(revealedLineBanner) 行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .onAppear {
                isFocused = true
                onUndoRedoStateChange?(false, false)
                reveal(line: highlightedLine)
            }
            .onChange(of: text) { _, _ in
                onUndoRedoStateChange?(false, false)
            }
            .onChange(of: highlightedLine) { _, line in
                reveal(line: line)
            }
    }

    private func reveal(line: Int?) {
        guard let line, line > 0 else { return }
        let targetIndex = indexForLine(line, in: text)
        selection = TextSelection(insertionPoint: targetIndex)
        revealedLineBanner = line
        DispatchQueue.main.async {
            highlightedLine = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if revealedLineBanner == line {
                revealedLineBanner = nil
            }
        }
    }

    private func indexForLine(_ line: Int, in text: String) -> String.Index {
        var currentLine = 1
        var index = text.startIndex
        while index < text.endIndex && currentLine < line {
            if text[index] == "\n" {
                currentLine += 1
            }
            index = text.index(after: index)
        }
        return index
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
        .background(tfPanelChromeColor)
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
            tfTextSurfaceColor
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
// EvidenceTabType 已移至 EvidenceTabSemantics.swift（Networking 层），macOS 与 iOS 共享同一定义。

struct EvidenceTabView: View {
    let appState: AppState

    @State private var projectionStore = EvidenceProjectionStore()
    @State private var selectedTab: EvidenceTabType = .screenshot
    @State private var selectedScreenshotID: String?
    @State private var selectedLogID: String?
    @State private var showDetailSheet: Bool = false
    @StateObject private var evidenceViewer = EvidenceViewerStore()
    @State private var itemImage: CGImage?
    @State private var actionMessage: String?
    @State private var screenshotThumbnails: [String: CGImage] = [:]
    @State private var screenshotThumbnailLoadingIDs: Set<String> = []
    @State private var screenshotThumbnailLoadFailedIDs: Set<String> = []
    @State private var screenshotThumbnailPendingIDs: [String] = []
    @State private var screenshotThumbnailActiveID: String?
    @State private var screenshotThumbnailRequestSequence: UInt64 = 0

    private var projection: EvidenceProjection { projectionStore.projection }
    private var project: String { projection.project }
    private var workspace: String? { projection.workspace }
    private var currentTabItems: [EvidenceItemProjection] { projection.currentTabItems }

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
                    item: item.rawValue,
                    selectedTab: selectedTab,
                    viewer: evidenceViewer,
                    itemImage: $itemImage,
                    onLoadNextPage: { loadNextTextPageIfNeeded(for: item) }
                )
            }
        }
        .onAppear {
            projectionStore.bind(appState: appState, selectedTab: selectedTab)
            refreshEvidence()
        }
        .onChange(of: projection.workspaceContextKey) { _, _ in
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
        .onChange(of: projection.snapshotUpdatedAt) { _, _ in
            syncSelectionIfNeeded()
            pruneScreenshotThumbnailCache()
            processNextScreenshotThumbnailLoadIfNeeded()
        }
        .onChange(of: selectedTab) { _, _ in
            projectionStore.refresh(appState: appState, selectedTab: selectedTab)
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
                        Text("\(tab.displayName)(\(projection.tabCount(for: tab)))")
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
        .background(tfPanelChromeColor)
    }

    @ViewBuilder
    private var content: some View {
        if !projection.workspaceReady {
            emptyStateView(icon: "photo.stack", text: "请先选择工作空间")
        } else if projection.snapshotLoading && !projection.snapshotAvailable {
            ProgressView("读取证据中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshotError = projection.snapshotError, !projection.snapshotAvailable {
            errorView(message: snapshotError)
        } else if !projection.snapshotAvailable {
            emptyStateView(icon: "photo.stack", text: "暂无证据数据", showRefresh: true)
        } else if projection.currentTabItemCount == 0 {
            emptyStateView(
                icon: selectedTab.iconName,
                text: selectedTab.emptyStateText
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
                ForEach(projection.deviceSections) { section in
                    deviceSection(section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }
    
    @ViewBuilder
    private func deviceSection(_ section: EvidenceDeviceSectionProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.deviceType)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(section.items.count) 项")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
            
            if selectedTab == .screenshot {
                screenshotGrid(items: section.items)
            } else {
                logList(items: section.items)
            }
        }
    }
    
    private func screenshotGrid(items: [EvidenceItemProjection]) -> some View {
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
    
    private func screenshotThumbnail(item: EvidenceItemProjection) -> some View {
        let thumbnailHeight: CGFloat = 80
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedScreenshotID = item.itemID
                loadItem(item)
                showDetailSheet = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let thumbnail = screenshotThumbnails[item.itemID] {
                        Image(decorative: thumbnail, scale: 1)
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
                
                Text(item.title)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
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
    
    private func logList(items: [EvidenceItemProjection]) -> some View {
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
                .fill(tfPanelChromeColor.opacity(0.5))
        )
    }
    
    private func logRow(item: EvidenceItemProjection) -> some View {
        Button {
            selectedLogID = item.itemID
            loadItem(item)
            showDetailSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                
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

    private var currentSelectedItem: EvidenceItemProjection? {
        let selectedID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        if let id = selectedID {
            return currentTabItems.first { $0.itemID == id }
        }
        return nil
    }

    private func syncSelectionIfNeeded() {
        var shouldClearPreview = false
        if let screenshotID = selectedScreenshotID,
           !projection.allItemIDs.contains(screenshotID) {
            selectedScreenshotID = nil
            shouldClearPreview = shouldClearPreview || selectedTab == .screenshot
        }
        if let logID = selectedLogID,
           !projection.allItemIDs.contains(logID) {
            selectedLogID = nil
            shouldClearPreview = shouldClearPreview || selectedTab == .log
        }
        if shouldClearPreview {
            clearItemPreview()
        }
    }

    private func clearItemPreview() {
        evidenceViewer.clear()
        itemImage = nil
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
        guard projection.snapshotAvailable else {
            clearScreenshotThumbnailCache()
            return
        }
        let validIDs = projection.screenshotItemIDs
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

    private func enqueueScreenshotThumbnailLoad(for item: EvidenceItemProjection) {
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

        if let payload,
           let thumbnail = decodeEvidenceImage(data: Data(payload.content), maxPixelSize: 640) {
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
                    appState.setAIChatOneShotHint(
                        project: prompt.project,
                        workspace: prompt.workspace,
                        message: "已填充证据提示词，请确认后发送。"
                    )
                    appState.setAIChatOneShotPrefill(
                        project: prompt.project,
                        workspace: prompt.workspace,
                        text: prompt.prompt
                    )
                    if let key = appState.currentGlobalWorkspaceKey {
                        appState.showWorkspaceSpecialPage(workspaceKey: key, page: .aiChat)
                    }
                    actionMessage = "已填充提示词并切换到聊天页"
                } else {
                    let error = errorMessage ?? "未知错误"
                    actionMessage = "重建提示词生成失败：\(error)"
                }
            }
        }
    }

    private func loadItem(_ item: EvidenceItemProjection) {
        guard let workspace, !workspace.isEmpty else { return }
        evidenceViewer.beginLoading(itemID: item.itemID)
        itemImage = nil

        if item.mimeType.hasPrefix("image/") || item.evidenceType == "screenshot" {
            appState.readEvidenceItem(project: project, workspace: workspace, itemID: item.itemID) { payload, errorMessage in
                DispatchQueue.main.async {
                    let currentID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
                    guard currentID == item.itemID else { return }
                    if let payload {
                        let data = Data(payload.content)
                        if let image = decodeEvidenceImage(data: data) {
                            itemImage = image
                            evidenceViewer.applyImageLoadResult(
                                itemID: item.itemID,
                                byteCount: payload.content.count,
                                errorMessage: nil
                            )
                            return
                        }
                        evidenceViewer.applyImageLoadResult(
                            itemID: item.itemID,
                            byteCount: payload.content.count,
                            errorMessage: "图片解码失败"
                        )
                    } else {
                        evidenceViewer.applyImageLoadResult(
                            itemID: item.itemID,
                            byteCount: 0,
                            errorMessage: errorMessage ?? "未知错误"
                        )
                    }
                }
            }
            return
        }

        loadNextTextPage(for: item, reset: true)
    }

    private func loadNextTextPageIfNeeded(for item: EvidenceItemProjection) {
        let currentID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        guard currentID == item.itemID else { return }
        guard evidenceViewer.shouldLoadNextPage(itemID: item.itemID) else { return }
        loadNextTextPage(for: item, reset: false)
    }

    private func loadNextTextPage(for item: EvidenceItemProjection, reset: Bool) {
        guard let workspace, !workspace.isEmpty else { return }
        let offset: UInt64 = reset ? 0 : evidenceViewer.nextOffset
        if !reset, offset == 0 {
            return
        }
        evidenceViewer.beginPaging(itemID: item.itemID)
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
                let perfTraceId: String? = {
                    guard !reset, payload != nil, let workspace = self.workspace else { return nil }
                    return self.appState.performanceTracer.begin(TFPerformanceContext(
                        event: .evidencePageAppend,
                        project: self.project,
                        workspace: workspace,
                        metadata: ["item_id": item.itemID, "offset": String(offset)]
                    ))
                }()
                self.evidenceViewer.applyTextPage(
                    itemID: item.itemID,
                    offset: offset,
                    payload: payload.map {
                        EvidenceTextPagePayload(
                            content: $0.content,
                            nextOffset: $0.nextOffset,
                            totalSizeBytes: $0.totalSizeBytes,
                            eof: $0.eof
                        )
                    },
                    reset: reset,
                    errorMessage: errorMessage
                )
                if let perfTraceId {
                    self.appState.performanceTracer.end(perfTraceId)
                }
            }
        }
    }

    private func decodeEvidenceImage(data: Data, maxPixelSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        if let maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return thumbnail
            }
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - 证据详情 Sheet

/// 证据详情弹出视图（用于右侧面板点击证据项后展示）
struct EvidenceDetailSheetView: View {
    let item: EvidenceItemInfoV2
    let selectedTab: EvidenceTabType
    @ObservedObject var viewer: EvidenceViewerStore
    @Binding var itemImage: CGImage?
    var onLoadNextPage: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = Self.debugPrintChangesIfNeeded()
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
        if viewer.isLoading {
            ProgressView("加载内容中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if let itemError = viewer.errorMessage {
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
                Image(decorative: itemImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 10))
            .padding(16)
        } else if !viewer.textChunks.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewer.textChunks) { chunk in
                        Text(chunk.text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if viewer.isPaging || viewer.hasMoreText {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(viewer.isPaging ? "加载更多中..." : "滚动到底部继续加载")
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
            .background(tfTextSurfaceColor)
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

    private static func debugPrintChangesIfNeeded() {
#if DEBUG
        guard SwiftUIPerformanceDebug.evidenceTextListPrintChangesEnabled else { return }
        Self._printChanges()
#endif
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
    @State private var isPlanDocumentSheetPresented: Bool = false
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
        .sheet(isPresented: $isPlanDocumentSheetPresented) {
            planDocumentSheet
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

        .onChange(of: currentItem?.statusStageRoundSignature) { _, _ in
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
                .fill(tfPanelChromeColor)
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
                                loadPlanDocumentAndPresent()
                            } label: {
                                Label("evolution.page.action.previewPlanDocument".localized, systemImage: "doc.text")
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

    // MARK: - 计划文档预览

    private func loadPlanDocumentAndPresent() {
        guard let item = currentItem else { return }
        appState.requestEvolutionPlanDocument(project: project, workspace: item.workspace, cycleID: item.cycleID)
        isPlanDocumentSheetPresented = true
    }

    private var planDocumentSheet: some View {
        NavigationStack {
            Group {
                if appState.evolutionPlanDocumentLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("evolution.page.planDocument.loading".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = appState.evolutionPlanDocumentError {
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
                } else if let content = appState.evolutionPlanDocumentContent {
                    ScrollView {
                        MarkdownTextView(text: content)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("evolution.page.planDocument.empty".localized)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("evolution.page.planDocument.title".localized)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        loadPlanDocumentAndPresent()
                    } label: {
                        Label("evolution.page.planDocument.refresh".localized, systemImage: "arrow.clockwise")
                    }
                    .disabled(currentItem == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isPlanDocumentSheetPresented = false
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
            let key = runtime.stage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if runtimeByStage[key] == nil {
                runtimeByStage[key] = runtime
            }
        }
        let runtimeProfileKeys = Set(runtimeAgents.map { profileStageKey(for: $0.stage) })

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
            guard !runtimeProfileKeys.contains(key) else { continue }
            guard seenStages.insert(key).inserted else { continue }
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

        // 兼容运行时存在但配置中缺失的阶段，避免状态被吞掉。
        for runtime in runtimeAgents {
            let key = runtime.stage.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let leftOrder = stageSortOrder(a.stage)
            let rightOrder = stageSortOrder(b.stage)
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



                if canOpenStageSession(stage: agent.stage) {
                    Button {
                        openStageSession(stage: agent.stage)
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
                .fill(isRunning ? tfPanelChromeColor : Color.gray.opacity(0.06))
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
        EvolutionStageSemantics.profileStageKey(for: stage)
    }

    private func profileStageKey(for stage: String) -> String {
        EvolutionStageSemantics.profileStageKey(for: stage)
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

    private func canOpenStageSession(stage: String) -> Bool {
        currentItem?.latestResolvedExecution(forExactStage: stage) != nil
    }

    private func normalizedStageStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func stageSortOrder(_ stage: String) -> (Int, Int, Int, String) {
        EvolutionStageSemantics.stageSortOrder(stage)
    }

    private func stageDisplayName(_ stage: String) -> String {
        EvolutionStageSemantics.displayName(for: stage)
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
        EvolutionStageSemantics.iconName(for: stage)
    }

    private func openStageSession(stage: String) {
        guard let item = currentItem,
              let execution = item.latestResolvedExecution(forExactStage: stage),
              let aiTool = AIChatTool(rawValue: execution.aiTool) else { return }
        let workspace = item.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return }

        let cached = appState.cachedAISession(
            projectName: item.project,
            workspaceName: workspace,
            aiTool: aiTool,
            sessionId: execution.sessionID
        )
        let session = AISessionInfo(
            projectName: item.project,
            workspaceName: workspace,
            aiTool: aiTool,
            id: execution.sessionID,
            title: cached?.title ?? "\(stageDisplayName(execution.stage)) · \(item.cycleID)",
            updatedAt: cached?.updatedAt ?? 0,
            origin: .evolutionSystem
        )
        appState.upsertAISession(session, for: aiTool)
        appState.sessionPanelAction = .loadSession(session)
        viewerStage = stage
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
                .environment(appState.evolutionReplayStore)
            }
        }
        #if os(macOS)
        .background(tfPanelBackgroundColor)
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(tfSeparatorColor),
            alignment: .leading
        )
        #endif
    }
}
