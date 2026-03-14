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
                    if let docKey = EditorDocumentKey(globalWorkspaceKey: workspaceKey, path: tab.payload) {
                        appState.editorStore.presentFindReplace(documentKey: docKey)
                    }
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

            // Session info — 从 AppState 派生的共享壳层相位读取
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
        .background(tfPanelChromeColor)
    }
}

// MARK: - 原生 Editor Content View

struct NativeEditorContentView: View {
    let path: String
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var editorStore: EditorStore
    @State private var highlightedLine: Int?
    @State private var matchRanges: [Range<String.Index>] = []
    @State private var currentMatchIndex: Int = -1
    @State private var regexError: String?

    /// 当前文档的 EditorDocumentKey（若可解析）
    private var documentKey: EditorDocumentKey? {
        guard let globalKey = appState.currentGlobalWorkspaceKey else { return nil }
        return EditorDocumentKey(globalWorkspaceKey: globalKey, path: path)
    }

    /// 当前文档的查找替换状态
    private var findState: EditorFindReplaceState {
        guard let docKey = documentKey else { return EditorFindReplaceState() }
        return editorStore.findReplaceState(for: docKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let globalKey = appState.currentGlobalWorkspaceKey,
                   let doc = appState.getEditorDocument(globalWorkspaceKey: globalKey, path: path) {
                    switch doc.loadStatus {
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
                            if findState.isVisible && appState.activeEditorPath == path {
                                findReplacePanel(textBinding: textBinding)
                                Divider()
                            }

                            NativeCodeEditorView(
                                text: textBinding,
                                highlightedLine: $highlightedLine,
                                documentKey: documentKey,
                                editorStore: editorStore,
                                filePath: path
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
        .onChange(of: findState.findText) { _, _ in
            refreshMatches(for: currentEditorText(), keepSelection: false)
        }
        .onChange(of: findState.isCaseSensitive) { _, _ in
            refreshMatches(for: currentEditorText(), keepSelection: false)
        }
        .onChange(of: findState.useRegex) { _, _ in
            refreshMatches(for: currentEditorText(), keepSelection: false)
        }
        .onChange(of: findState.isVisible) { _, isShowing in
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
        let findBinding = Binding<String>(
            get: { findState.findText },
            set: { newValue in
                guard let docKey = documentKey else { return }
                var state = editorStore.findReplaceState(for: docKey)
                state.findText = newValue
                editorStore.updateFindReplaceState(state, for: docKey)
            }
        )
        let replaceBinding = Binding<String>(
            get: { findState.replaceText },
            set: { newValue in
                guard let docKey = documentKey else { return }
                var state = editorStore.findReplaceState(for: docKey)
                state.replaceText = newValue
                editorStore.updateFindReplaceState(state, for: docKey)
            }
        )

        HStack(spacing: 8) {
            TextField("editor.find.placeholder".localized, text: findBinding)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
            TextField("editor.replace.placeholder".localized, text: replaceBinding)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)

            Button("Aa") {
                guard let docKey = documentKey else { return }
                var state = editorStore.findReplaceState(for: docKey)
                state.isCaseSensitive.toggle()
                editorStore.updateFindReplaceState(state, for: docKey)
            }
            .buttonStyle(.bordered)
            .tint(findState.isCaseSensitive ? .accentColor : .secondary)

            Button(".*") {
                guard let docKey = documentKey else { return }
                var state = editorStore.findReplaceState(for: docKey)
                state.useRegex.toggle()
                state.regexError = nil
                editorStore.updateFindReplaceState(state, for: docKey)
            }
            .buttonStyle(.bordered)
            .tint(findState.useRegex ? .accentColor : .secondary)

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

            if let regexError {
                Text(regexError)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .frame(maxWidth: 120)
            }

            Button("editor.replace.one".localized) {
                replaceCurrent(in: textBinding)
            }
            .buttonStyle(.bordered)
            .disabled(currentMatchIndex < 0 || regexError != nil)

            Button("editor.replace.all".localized) {
                replaceAll(in: textBinding)
            }
            .buttonStyle(.borderedProminent)
            .disabled(matchRanges.isEmpty || regexError != nil)

            Button {
                guard let docKey = documentKey else { return }
                editorStore.dismissFindReplace(documentKey: docKey)
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
        EditorFindReplaceEngine.matchStatusText(currentIndex: currentMatchIndex, matchCount: matchRanges.count)
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

    // MARK: - 查找替换（消费共享引擎 EditorFindReplaceEngine）

    private func refreshMatches(for text: String, keepSelection: Bool) {
        let result = EditorFindReplaceEngine.findMatches(in: text, state: findState)
        matchRanges = result.ranges
        regexError = result.regexError
        currentMatchIndex = EditorFindReplaceEngine.clampMatchIndex(
            currentIndex: currentMatchIndex,
            matchCount: result.ranges.count,
            keepSelection: keepSelection
        )
        revealCurrentMatch(in: text)
    }

    private func navigateToNextMatch(in text: String) {
        guard !findState.findText.isEmpty else { return }
        if matchRanges.isEmpty {
            refreshMatches(for: text, keepSelection: false)
            return
        }
        currentMatchIndex = EditorFindReplaceEngine.nextMatchIndex(
            currentIndex: currentMatchIndex, matchCount: matchRanges.count
        )
        revealCurrentMatch(in: text)
    }

    private func navigateToPreviousMatch(in text: String) {
        guard !findState.findText.isEmpty else { return }
        if matchRanges.isEmpty {
            refreshMatches(for: text, keepSelection: false)
            return
        }
        currentMatchIndex = EditorFindReplaceEngine.previousMatchIndex(
            currentIndex: currentMatchIndex, matchCount: matchRanges.count
        )
        revealCurrentMatch(in: text)
    }

    private func replaceCurrent(in textBinding: Binding<String>) {
        guard let result = EditorFindReplaceEngine.replaceCurrent(
            in: textBinding.wrappedValue,
            matchRanges: matchRanges,
            currentIndex: currentMatchIndex,
            replaceText: findState.replaceText,
            state: findState
        ) else { return }
        textBinding.wrappedValue = result.text
        matchRanges = result.newRanges
        currentMatchIndex = result.currentMatchIndex
        revealCurrentMatch(in: result.text)
    }

    private func replaceAll(in textBinding: Binding<String>) {
        guard let result = EditorFindReplaceEngine.replaceAll(
            in: textBinding.wrappedValue,
            matchRanges: matchRanges,
            replaceText: findState.replaceText,
            state: findState
        ) else { return }
        textBinding.wrappedValue = result.text
        matchRanges = result.newRanges
        currentMatchIndex = result.currentMatchIndex
        revealCurrentMatch(in: result.text)
    }

    private func revealCurrentMatch(in text: String) {
        highlightedLine = EditorFindReplaceEngine.targetLineForCurrentMatch(
            in: text, matchRanges: matchRanges, currentIndex: currentMatchIndex
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

            Button("editor.findReplace".localized) {
                if let globalKey = appState.currentGlobalWorkspaceKey,
                   let docKey = EditorDocumentKey(globalWorkspaceKey: globalKey, path: path) {
                    editorStore.presentFindReplace(documentKey: docKey)
                }
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

// MARK: - NSTextView 包装编辑器

#if os(macOS)
import AppKit
import TidyFlowShared

// MARK: - macOS 语法高亮颜色映射

/// macOS 平台的语义角色到颜色映射。
/// 集中管理，不散落在词法规则或视图代码中。
enum EditorSyntaxColorMapMacOS {
    static func colors(for theme: EditorSyntaxTheme) -> [EditorSyntaxRole: NSColor] {
        switch theme {
        case .systemDark:
            return [
                .plain: NSColor(red: 0.84, green: 0.84, blue: 0.84, alpha: 1.0),
                .keyword: NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1.0),
                .type: NSColor(red: 0.35, green: 0.75, blue: 0.84, alpha: 1.0),
                .string: NSColor(red: 0.99, green: 0.52, blue: 0.40, alpha: 1.0),
                .number: NSColor(red: 0.82, green: 0.73, blue: 0.55, alpha: 1.0),
                .comment: NSColor(red: 0.51, green: 0.55, blue: 0.59, alpha: 1.0),
                .attribute: NSColor(red: 0.80, green: 0.58, blue: 0.93, alpha: 1.0),
                .function: NSColor(red: 0.40, green: 0.78, blue: 0.47, alpha: 1.0),
                .punctuation: NSColor(red: 0.67, green: 0.67, blue: 0.67, alpha: 1.0),
            ]
        case .systemLight:
            return [
                .plain: NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0),
                .keyword: NSColor(red: 0.67, green: 0.05, blue: 0.33, alpha: 1.0),
                .type: NSColor(red: 0.11, green: 0.40, blue: 0.59, alpha: 1.0),
                .string: NSColor(red: 0.77, green: 0.20, blue: 0.13, alpha: 1.0),
                .number: NSColor(red: 0.10, green: 0.35, blue: 0.58, alpha: 1.0),
                .comment: NSColor(red: 0.42, green: 0.47, blue: 0.51, alpha: 1.0),
                .attribute: NSColor(red: 0.50, green: 0.18, blue: 0.68, alpha: 1.0),
                .function: NSColor(red: 0.20, green: 0.44, blue: 0.22, alpha: 1.0),
                .punctuation: NSColor(red: 0.40, green: 0.40, blue: 0.40, alpha: 1.0),
            ]
        }
    }
}

/// NSViewRepresentable 包装的 NSTextView / NSScrollView 方案。
/// 从原生 undoManager 驱动 canUndo/canRedo；支持程序化选区、行跳转和查找替换桥接。
/// 集成共享折叠投影层，提供代码折叠控制、隐藏行管理和缩进导线渲染。
struct NativeCodeEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var highlightedLine: Int?
    var documentKey: EditorDocumentKey?
    var editorStore: EditorStore
    var filePath: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = UndoTrackingTextView()
        textView.isEditable = true
        textView.isSelectable = true
        // 禁用原生文本编辑 undo 注册——编辑历史由共享语义层驱动
        textView.allowsUndo = false
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.06)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // 左侧留出 gutter 空间（初始值，后续由 gutter 投影动态更新）
        textView.textContainerInset = NSSize(width: 48, height: 4)
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        // 撤销/重做状态由共享历史语义层驱动（不再依赖 NSUndoManager 通知）
        textView.onUndoRedoStateDidChange = nil

        // 注册补全键盘事件处理
        textView.onAutocompleteKeyDown = { [weak textView] event in
            guard let textView = textView else { return false }
            let coordinator = context.coordinator

            // Ctrl-Space 手动触发
            if event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == " " {
                coordinator.triggerManualAutocomplete(textView: textView)
                return true
            }

            // 以下按键仅在补全面板可见时拦截
            guard coordinator.isAutocompleteVisible else { return false }

            switch event.keyCode {
            case 126: // Up
                coordinator.moveAutocompleteSelectionUp()
                return true
            case 125: // Down
                coordinator.moveAutocompleteSelectionDown()
                return true
            case 48: // Tab
                coordinator.acceptSelectedAutocomplete(textView: textView)
                return true
            case 36: // Return/Enter
                coordinator.acceptSelectedAutocomplete(textView: textView)
                return true
            case 53: // Esc
                coordinator.dismissAutocompletePopup()
                return true
            default:
                return false
            }
        }

        // 注册共享历史撤销/重做回调
        editorStore.onEditorUndo = { [weak textView, weak editorStore] docKey in
            guard let textView = textView, let editorStore = editorStore else { return }
            guard docKey == context.coordinator.parent.documentKey else { return }
            guard let result = editorStore.undoEdit(documentKey: docKey, currentText: textView.string) else { return }
            context.coordinator.isProgrammaticTextUpdate = true
            textView.string = result.text
            // 恢复多选区
            let nsRanges = result.selections.regions.map {
                NSValue(range: NSRange(location: $0.location, length: $0.length))
            }
            textView.setSelectedRanges(nsRanges, affinity: .downstream, stillSelecting: false)
            context.coordinator.isProgrammaticTextUpdate = false
            context.coordinator.parent.text = result.text
            context.coordinator.applySyntaxHighlighting(to: textView)
            context.coordinator.applyFoldingProjection(to: textView)
            context.coordinator.refreshPairMatchOverlay(textView: textView)
        }
        editorStore.onEditorRedo = { [weak textView, weak editorStore] docKey in
            guard let textView = textView, let editorStore = editorStore else { return }
            guard docKey == context.coordinator.parent.documentKey else { return }
            guard let result = editorStore.redoEdit(documentKey: docKey, currentText: textView.string) else { return }
            context.coordinator.isProgrammaticTextUpdate = true
            textView.string = result.text
            // 恢复多选区
            let nsRanges = result.selections.regions.map {
                NSValue(range: NSRange(location: $0.location, length: $0.length))
            }
            textView.setSelectedRanges(nsRanges, affinity: .downstream, stillSelecting: false)
            context.coordinator.isProgrammaticTextUpdate = false
            context.coordinator.parent.text = result.text
            context.coordinator.applySyntaxHighlighting(to: textView)
            context.coordinator.applyFoldingProjection(to: textView)
            context.coordinator.refreshPairMatchOverlay(textView: textView)
        }

        // 配置折叠 overlay
        let foldOverlay = EditorFoldOverlayView()
        foldOverlay.translatesAutoresizingMaskIntoConstraints = false
        foldOverlay.onToggleFold = { [weak editorStore] regionID in
            guard let docKey = context.coordinator.parent.documentKey else { return }
            var state = editorStore?.foldingState(for: docKey) ?? EditorCodeFoldingState()
            state.toggle(regionID)
            editorStore?.updateFoldingState(state, for: docKey)
            // 重新应用折叠投影
            context.coordinator.applyFoldingProjection(to: textView)
        }
        foldOverlay.onToggleBreakpoint = { [weak editorStore] line in
            guard let docKey = context.coordinator.parent.documentKey else { return }
            editorStore?.toggleBreakpoint(line: line, for: docKey)
            // 刷新 gutter 显示
            context.coordinator.updateGutterOverlayIfNeeded(textView: textView)
        }
        context.coordinator.foldOverlay = foldOverlay

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // 把 fold overlay 添加到 scrollView 的 contentView 上（跟随滚动）
        scrollView.contentView.addSubview(foldOverlay)
        NSLayoutConstraint.activate([
            foldOverlay.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            foldOverlay.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            foldOverlay.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
        // 初始宽度由首次 gutter 投影更新动态设置

        // 设置初始文本
        textView.string = text

        // 首次加载后自动聚焦并应用高亮
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
            context.coordinator.applySyntaxHighlighting(to: textView)
            context.coordinator.applyFoldingProjection(to: textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? UndoTrackingTextView else { return }
        context.coordinator.parent = self

        // 同步文本内容（避免循环更新）
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            context.coordinator.isProgrammaticTextUpdate = true
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.isProgrammaticTextUpdate = false
            // 外部文本变化时关闭补全弹层
            context.coordinator.dismissAutocompletePopup()
            // 文本变化时重新应用高亮和折叠
            context.coordinator.applySyntaxHighlighting(to: textView)
            context.coordinator.applyFoldingProjection(to: textView)
            context.coordinator.refreshPairMatchOverlay(textView: textView)
        } else {
            // 文本未变，但检查主题是否变化（深浅色切换）
            context.coordinator.applyHighlightingIfThemeChanged(to: textView)
            // 检查折叠状态是否被外部更新（如状态容器中的 toggle）
            context.coordinator.applyFoldingProjectionIfNeeded(to: textView)
            context.coordinator.refreshPairMatchOverlay(textView: textView)
        }

        // 处理行跳转
        if let line = highlightedLine, line > 0 {
            // 跳转前自动展开包含目标行的折叠区域
            if let docKey = documentKey {
                var foldState = editorStore.foldingState(for: docKey)
                if let snapshot = context.coordinator.lastStructureSnapshot {
                    let targetLine0 = line - 1
                    foldState.expandRegions(containingLine: targetLine0, in: snapshot)
                    editorStore.updateFoldingState(foldState, for: docKey)
                    // 更新当前行到跳转目标
                    editorStore.updateCurrentLine(targetLine0, for: docKey)
                    context.coordinator.applyFoldingProjection(to: textView)
                }
            }
            let targetIndex = indexForLine(line, in: textView.string)
            let nsRange = NSRange(location: targetIndex, length: 0)
            textView.setSelectedRange(nsRange)
            textView.scrollRangeToVisible(nsRange)
            DispatchQueue.main.async {
                highlightedLine = nil
            }
        }
    }

    private func indexForLine(_ line: Int, in text: String) -> Int {
        var currentLine = 1
        for (i, char) in text.enumerated() {
            if currentLine >= line { return i }
            if char == "\n" { currentLine += 1 }
        }
        return text.count
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditorView
        weak var textView: UndoTrackingTextView?
        weak var foldOverlay: EditorFoldOverlayView?
        private let highlighter = EditorSyntaxHighlighter()
        private let structureAnalyzer = EditorStructureAnalyzer()
        /// 补全引擎（共享语义层）
        private let autocompleteEngine = EditorAutocompleteEngine()
        /// 补全候选弹层（macOS NSPanel/子视图）
        private var autocompletePopupView: EditorAutocompletePopupView?
        /// 上次应用的高亮快照指纹，用于跳过重复应用
        private var lastAppliedFingerprint: Int?
        /// 上次应用的主题
        private var lastAppliedTheme: EditorSyntaxTheme?
        /// 标记当前是否正在程序性地更新属性（防止触发 textDidChange）
        private var isApplyingHighlight = false
        /// 标记当前是否正在程序性地回放共享历史（防止再次入栈）
        var isProgrammaticTextUpdate = false
        /// 最近一次结构分析快照（供行跳转时展开折叠区域用）
        var lastStructureSnapshot: EditorStructureSnapshot?
        /// 上次应用的折叠投影指纹（用于跳过重复应用）
        private var lastAppliedFoldingFingerprint: Int?
        private var lastAppliedCollapsedCount: Int?
        /// 上次应用的 gutter 缓存键（内容指纹、折叠数、当前行、断点数）
        private var lastGutterCacheKey: (Int, Int, Int?, Int)?

        // MARK: - 括号/引号匹配覆盖层

        /// 匹配高亮覆盖层（轻量子视图，仅绘制配对分隔符的背景/描边）
        private var pairMatchOverlays: [NSView] = []
        /// 上次匹配快照缓存键（内容指纹、选区位置、主题）
        private var lastPairMatchCacheKey: (Int, Int, EditorSyntaxTheme)?

        init(parent: NativeCodeEditorView) {
            self.parent = parent
        }

        // MARK: - 共享历史桥接

        /// 拦截文本变更前记录共享编辑命令。
        /// 用户编辑走此路径入栈；程序化回放（undo/redo 写回）由 isProgrammaticTextUpdate 旗标跳过。
        /// 支持 NSTextView 多选区：为每个选区生成原子 mutation，构建批量命令。
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !isProgrammaticTextUpdate, !isApplyingHighlight else { return true }
            guard let docKey = parent.documentKey,
                  let replacement = replacementString else { return true }

            let currentText = textView.string

            // 读取当前所有选区，构建多选区编辑命令
            let selectedRanges = textView.selectedRanges.map { $0.rangeValue }

            // 如果只有一个选区，走简单路径
            if selectedRanges.count <= 1 {
                let selectedRange = textView.selectedRange()
                let replacedText = (currentText as NSString).substring(with: affectedCharRange)

                let command = EditorEditCommand(
                    mutation: EditorTextMutation(
                        rangeLocation: affectedCharRange.location,
                        rangeLength: affectedCharRange.length,
                        replacementText: replacement
                    ),
                    beforeSelection: EditorSelectionSnapshot(
                        location: selectedRange.location,
                        length: selectedRange.length
                    ),
                    afterSelection: EditorSelectionSnapshot(
                        location: affectedCharRange.location + (replacement as NSString).length,
                        length: 0
                    ),
                    timestamp: Date(),
                    replacedText: replacedText
                )

                let result = parent.editorStore.recordEdit(
                    currentText: currentText,
                    command: command,
                    documentKey: docKey
                )

                isProgrammaticTextUpdate = true
                textView.string = result.text
                let primarySel = result.selections.primarySnapshot
                textView.setSelectedRange(NSRange(location: primarySel.location, length: primarySel.length))
                isProgrammaticTextUpdate = false

                parent.text = result.text

                if let snapshot = lastStructureSnapshot {
                    let cursorLine = lineNumber(for: primarySel.location, in: result.text)
                    var foldState = parent.editorStore.foldingState(for: docKey)
                    let beforeCount = foldState.collapsedRegionIDs.count
                    foldState.expandRegions(containingLine: cursorLine, in: snapshot)
                    if foldState.collapsedRegionIDs.count != beforeCount {
                        parent.editorStore.updateFoldingState(foldState, for: docKey)
                    }
                    parent.editorStore.updateCurrentLine(cursorLine, for: docKey)
                }
            } else {
                // 多选区：为每个选区生成 mutation（NSTextView 对多选区编辑会对
                // 每个选区分别调用 shouldChangeTextIn，这里处理批量场景的首次调用）
                let nsText = currentText as NSString
                let replacementLen = (replacement as NSString).length

                // 构建 before/after 选区集合
                var beforeRegions: [EditorSelectionRegion] = []
                var afterRegions: [EditorSelectionRegion] = []
                var mutations: [EditorTextMutation] = []
                var replacedTexts: [String] = []

                // 按降序处理以正确计算 after 位置
                let sortedRanges = selectedRanges.sorted { $0.location > $1.location }
                var offsetAccum = 0

                for (idx, range) in sortedRanges.enumerated() {
                    let isPrimary = (idx == sortedRanges.count - 1) // 最低位置的为主选区
                    beforeRegions.append(EditorSelectionRegion(
                        location: range.location, length: range.length, isPrimary: isPrimary
                    ))
                    let replaced = nsText.substring(with: range)
                    mutations.append(EditorTextMutation(
                        rangeLocation: range.location,
                        rangeLength: range.length,
                        replacementText: replacement
                    ))
                    replacedTexts.append(replaced)
                }

                // 计算 after 选区：按升序累计偏移
                let ascRanges = selectedRanges.sorted { $0.location < $1.location }
                offsetAccum = 0
                for (idx, range) in ascRanges.enumerated() {
                    let isPrimary = (idx == 0)
                    let newLoc = range.location + offsetAccum + replacementLen
                    afterRegions.append(EditorSelectionRegion(
                        location: newLoc, length: 0, isPrimary: isPrimary
                    ))
                    offsetAccum += replacementLen - range.length
                }

                let command = EditorEditCommand(
                    mutations: mutations,
                    beforeSelections: EditorSelectionSet(regions: beforeRegions),
                    afterSelections: EditorSelectionSet(regions: afterRegions),
                    timestamp: Date(),
                    replacedTexts: replacedTexts
                )

                let result = parent.editorStore.recordEdit(
                    currentText: currentText,
                    command: command,
                    documentKey: docKey
                )

                isProgrammaticTextUpdate = true
                textView.string = result.text
                let nsRanges = result.selections.regions.map {
                    NSValue(range: NSRange(location: $0.location, length: $0.length))
                }
                textView.setSelectedRanges(nsRanges, affinity: .downstream, stillSelecting: false)
                isProgrammaticTextUpdate = false

                parent.text = result.text

                if let snapshot = lastStructureSnapshot {
                    let primarySel = result.selections.primarySnapshot
                    let cursorLine = lineNumber(for: primarySel.location, in: result.text)
                    var foldState = parent.editorStore.foldingState(for: docKey)
                    let beforeCount = foldState.collapsedRegionIDs.count
                    foldState.expandRegions(containingLine: cursorLine, in: snapshot)
                    if foldState.collapsedRegionIDs.count != beforeCount {
                        parent.editorStore.updateFoldingState(foldState, for: docKey)
                    }
                    parent.editorStore.updateCurrentLine(cursorLine, for: docKey)
                }
            }

            // 重新应用高亮和折叠
            applySyntaxHighlighting(to: textView as! UndoTrackingTextView)
            applyFoldingProjection(to: textView as! UndoTrackingTextView)
            refreshPairMatchOverlay(textView: textView as! UndoTrackingTextView)

            // 刷新补全状态
            refreshAutocompleteState(textView: textView as! UndoTrackingTextView, triggerKind: .automatic)

            // 已自行处理文本变更，阻止 NSTextView 再次应用
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? UndoTrackingTextView else { return }
            guard !isApplyingHighlight, !isProgrammaticTextUpdate else { return }
            // 程序化回放或 shouldChangeTextIn 已处理的用户编辑不会到这里记录。
            // 此回调仅处理未被 shouldChangeTextIn 拦截的情况（如外部程序化写入 textView.string = ...）。
            parent.text = textView.string

            // 编辑时自动展开包含光标位置的已折叠区域
            if let docKey = parent.documentKey, let snapshot = lastStructureSnapshot {
                let cursorLine = lineNumber(for: textView.selectedRange().location, in: textView.string)
                var foldState = parent.editorStore.foldingState(for: docKey)
                let beforeCount = foldState.collapsedRegionIDs.count
                foldState.expandRegions(containingLine: cursorLine, in: snapshot)
                if foldState.collapsedRegionIDs.count != beforeCount {
                    parent.editorStore.updateFoldingState(foldState, for: docKey)
                }
                // 更新当前行
                parent.editorStore.updateCurrentLine(cursorLine, for: docKey)
            }

            // 用户输入后异步重算高亮和折叠
            applySyntaxHighlighting(to: textView)
            applyFoldingProjection(to: textView)
            refreshPairMatchOverlay(textView: textView)
            // 刷新补全状态
            refreshAutocompleteState(textView: textView, triggerKind: .automatic)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? UndoTrackingTextView else { return }
            guard !isApplyingHighlight else { return }
            guard let docKey = parent.documentKey else { return }

            let cursorLine = lineNumber(for: textView.selectedRange().location, in: textView.string)
            let oldLine = parent.editorStore.gutterState(for: docKey).currentLine
            if cursorLine != oldLine {
                parent.editorStore.updateCurrentLine(cursorLine, for: docKey)
                // 仅当前行变化时刷新 gutter（无需重新分析结构）
                updateGutterOverlayIfNeeded(textView: textView)
            }
            // 选区变化时刷新括号/引号匹配覆盖层
            refreshPairMatchOverlay(textView: textView)
            // 选区变化时关闭补全（如果选区有长度，即有选中文本）
            if textView.selectedRange().length > 0 {
                dismissAutocompletePopup()
            }
        }

        /// 计算字符偏移对应的行号（0-based）
        private func lineNumber(for charOffset: Int, in text: String) -> Int {
            let prefix = text.prefix(charOffset)
            return prefix.filter { $0 == "\n" }.count
        }

        /// 检测当前系统主题
        private func currentTheme() -> EditorSyntaxTheme {
            if let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
               appearance == .darkAqua {
                return .systemDark
            }
            return .systemLight
        }

        /// 应用语法高亮到 NSTextView
        func applySyntaxHighlighting(to textView: UndoTrackingTextView) {
            guard let filePath = parent.filePath else { return }
            let text = textView.string
            guard !text.isEmpty else {
                lastAppliedFingerprint = nil
                lastAppliedTheme = nil
                return
            }

            let theme = currentTheme()
            let snapshot = highlighter.highlight(filePath: filePath, text: text, theme: theme)

            // 校验内容版本匹配（防止旧结果回写）
            let currentFingerprint = EditorSyntaxFingerprint.compute(textView.string)
            guard snapshot.contentFingerprint == currentFingerprint else { return }

            // 跳过重复应用
            if lastAppliedFingerprint == snapshot.contentFingerprint,
               lastAppliedTheme == snapshot.theme {
                return
            }

            applySnapshot(snapshot, to: textView, theme: theme)
        }

        /// 当主题变化时重新应用高亮（不重算词法）
        func applyHighlightingIfThemeChanged(to textView: UndoTrackingTextView) {
            let theme = currentTheme()
            guard theme != lastAppliedTheme else { return }
            guard let filePath = parent.filePath else { return }
            let text = textView.string
            guard !text.isEmpty else { return }

            let snapshot = highlighter.highlight(filePath: filePath, text: text, theme: theme)
            let currentFingerprint = EditorSyntaxFingerprint.compute(textView.string)
            guard snapshot.contentFingerprint == currentFingerprint else { return }

            applySnapshot(snapshot, to: textView, theme: theme)
        }

        /// 将快照属性应用到 NSTextStorage
        private func applySnapshot(_ snapshot: EditorSyntaxSnapshot, to textView: UndoTrackingTextView, theme: EditorSyntaxTheme) {
            guard let textStorage = textView.textStorage else { return }

            isApplyingHighlight = true
            let selectedRanges = textView.selectedRanges
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let fullRange = NSRange(location: 0, length: textStorage.length)
            let colorMap = EditorSyntaxColorMapMacOS.colors(for: theme)

            textStorage.beginEditing()

            // 重置全部属性为默认
            textStorage.setAttributes([
                .font: font,
                .foregroundColor: colorMap[.plain] ?? NSColor.textColor,
            ], range: fullRange)

            // 逐条应用高亮
            for run in snapshot.runs {
                guard run.location + run.length <= textStorage.length else { continue }
                let color = colorMap[run.role] ?? colorMap[.plain] ?? NSColor.textColor
                textStorage.addAttributes([.foregroundColor: color], range: run.nsRange)
            }

            textStorage.endEditing()
            textView.selectedRanges = selectedRanges
            isApplyingHighlight = false

            lastAppliedFingerprint = snapshot.contentFingerprint
            lastAppliedTheme = theme
        }

        // MARK: - 折叠投影

        /// 计算并应用折叠投影到 overlay
        func applyFoldingProjection(to textView: UndoTrackingTextView) {
            guard let filePath = parent.filePath else { return }
            let text = textView.string

            // 计算结构快照
            let snapshot = structureAnalyzer.analyze(filePath: filePath, text: text)
            lastStructureSnapshot = snapshot

            // 获取当前折叠状态并 reconcile
            guard let docKey = parent.documentKey else { return }
            var foldState = parent.editorStore.foldingState(for: docKey)
            foldState.reconcile(snapshot: snapshot)
            parent.editorStore.updateFoldingState(foldState, for: docKey)

            // 生成折叠投影
            let foldingProjection = EditorCodeFoldingProjection.make(snapshot: snapshot, state: foldState)

            // 获取 gutter 状态并构建 gutter 投影
            let gutterState = parent.editorStore.gutterState(for: docKey)
            let gutterProjection = EditorGutterProjectionBuilder.make(
                snapshot: snapshot,
                folding: foldingProjection,
                state: gutterState
            )

            // 更新缓存指纹
            lastAppliedFoldingFingerprint = snapshot.contentFingerprint
            lastAppliedCollapsedCount = foldState.collapsedRegionIDs.count
            lastGutterCacheKey = (snapshot.contentFingerprint, foldState.collapsedRegionIDs.count, gutterState.currentLine, gutterState.breakpoints.count)

            // 更新 overlay
            updateGutterOverlay(gutterProjection: gutterProjection, foldingProjection: foldingProjection, textView: textView)
        }

        /// 仅在折叠状态发生变化时重新应用（外部 toggle 驱动）
        func applyFoldingProjectionIfNeeded(to textView: UndoTrackingTextView) {
            guard let docKey = parent.documentKey else { return }
            let foldState = parent.editorStore.foldingState(for: docKey)
            let gutterState = parent.editorStore.gutterState(for: docKey)
            let currentFingerprint = EditorSyntaxFingerprint.compute(textView.string)
            let currentCacheKey = (currentFingerprint, foldState.collapsedRegionIDs.count, gutterState.currentLine, gutterState.breakpoints.count)

            if let last = lastGutterCacheKey,
               last.0 == currentCacheKey.0,
               last.1 == currentCacheKey.1,
               last.2 == currentCacheKey.2,
               last.3 == currentCacheKey.3 {
                return
            }
            applyFoldingProjection(to: textView)
        }

        /// 仅刷新 gutter 显示（当前行/断点变化但文本和折叠不变时）
        func updateGutterOverlayIfNeeded(textView: UndoTrackingTextView) {
            guard let docKey = parent.documentKey,
                  let snapshot = lastStructureSnapshot else { return }

            let foldState = parent.editorStore.foldingState(for: docKey)
            let foldingProjection = EditorCodeFoldingProjection.make(snapshot: snapshot, state: foldState)
            let gutterState = parent.editorStore.gutterState(for: docKey)
            let gutterProjection = EditorGutterProjectionBuilder.make(
                snapshot: snapshot,
                folding: foldingProjection,
                state: gutterState
            )

            lastGutterCacheKey = (snapshot.contentFingerprint, foldState.collapsedRegionIDs.count, gutterState.currentLine, gutterState.breakpoints.count)
            updateGutterOverlay(gutterProjection: gutterProjection, foldingProjection: foldingProjection, textView: textView)
        }

        /// 更新 gutter overlay 显示
        private func updateGutterOverlay(gutterProjection: EditorGutterProjection, foldingProjection: EditorCodeFoldingProjection, textView: UndoTrackingTextView) {
            guard let overlay = foldOverlay else { return }
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let text = textView.string
            let lines = text.components(separatedBy: "\n")

            // 计算 gutter 宽度：字符宽度 × (行号位数 + 附件槽位) + padding
            let charWidth: CGFloat = 7.8
            let metrics = gutterProjection.layoutMetrics
            let gutterWidth = charWidth * CGFloat(max(metrics.lineNumberDigits, metrics.minimumCharacterColumns) + metrics.leadingAccessorySlots) + 12

            // 动态更新 overlay 宽度约束
            overlay.updateGutterWidth(gutterWidth)
            // 同步更新 textView 左侧 inset 使文本不被 gutter 遮挡
            let newInset = NSSize(width: gutterWidth, height: 4)
            if textView.textContainerInset != newInset {
                textView.textContainerInset = newInset
            }

            // 构建 gutter 行项的 rect 信息
            var lineItemRects: [(item: EditorGutterLineItem, rect: NSRect)] = []
            for item in gutterProjection.lineItems {
                guard item.line < lines.count else { continue }

                let charIndex = charOffset(forLine: item.line, in: text)
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                lineRect.origin.x = 0
                lineRect.origin.y += textView.textContainerInset.height
                lineRect.size.width = gutterWidth

                lineItemRects.append((item, lineRect))
            }

            // 构建缩进导线的 rect 信息
            var guideLines: [(guide: EditorIndentGuideSegment, startY: CGFloat, endY: CGFloat, x: CGFloat)] = []
            for guide in gutterProjection.visibleIndentGuides {
                guard guide.startLine < lines.count, guide.endLine < lines.count else { continue }

                let startCharIndex = charOffset(forLine: guide.startLine, in: text)
                let endCharIndex = charOffset(forLine: guide.endLine, in: text)

                let startGlyph = layoutManager.glyphIndexForCharacter(at: startCharIndex)
                let endGlyph = layoutManager.glyphIndexForCharacter(at: endCharIndex)

                let startRect = layoutManager.lineFragmentRect(forGlyphAt: startGlyph, effectiveRange: nil)
                let endRect = layoutManager.lineFragmentRect(forGlyphAt: endGlyph, effectiveRange: nil)

                let x = CGFloat(guide.column) * charWidth + textView.textContainerInset.width + textView.textContainerOrigin.x
                let startY = startRect.origin.y + textView.textContainerInset.height
                let endY = endRect.maxY + textView.textContainerInset.height

                guideLines.append((guide, startY, endY, x))
            }

            overlay.updateContent(
                lineItems: lineItemRects,
                guides: guideLines,
                isDarkMode: currentTheme() == .systemDark,
                metrics: gutterProjection.layoutMetrics
            )
        }

        /// 计算指定行的字符偏移
        private func charOffset(forLine line: Int, in text: String) -> Int {
            var currentLine = 0
            for (i, ch) in text.enumerated() {
                if currentLine == line { return i }
                if ch == "\n" { currentLine += 1 }
            }
            return text.count
        }

        // MARK: - 括号/引号匹配覆盖层

        /// 刷新括号/引号匹配覆盖层
        func refreshPairMatchOverlay(textView: UndoTrackingTextView) {
            guard let filePath = parent.filePath else {
                clearPairMatchOverlay()
                return
            }
            let text = textView.string
            let selection = textView.selectedRange()
            let theme = currentTheme()
            let fingerprint = EditorSyntaxFingerprint.compute(text)

            // 缓存命中则跳过
            let cacheKey = (fingerprint, selection.location, theme)
            if let last = lastPairMatchCacheKey,
               last.0 == cacheKey.0,
               last.1 == cacheKey.1,
               last.2 == cacheKey.2,
               selection.length == 0 {
                return
            }
            lastPairMatchCacheKey = cacheKey

            let snapshot = EditorPairMatcher.match(
                filePath: filePath,
                text: text,
                selectionLocation: selection.location,
                selectionLength: selection.length
            )

            // 清空旧覆盖层
            clearPairMatchOverlay()

            guard snapshot.state != .inactive, !snapshot.highlights.isEmpty else { return }
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let isDark = theme == .systemDark

            for highlight in snapshot.highlights {
                let range = NSRange(location: highlight.location, length: highlight.length)
                guard range.location + range.length <= (textView.string as NSString).length else { continue }

                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

                // 偏移到 textContainerInset + textContainerOrigin
                let adjustedRect = NSRect(
                    x: rect.origin.x + textView.textContainerInset.width + textView.textContainerOrigin.x,
                    y: rect.origin.y + textView.textContainerInset.height,
                    width: max(rect.width, 7),
                    height: rect.height
                )

                let overlayView = NSView(frame: adjustedRect)
                overlayView.wantsLayer = true

                switch highlight.role {
                case .activeDelimiter, .pairedDelimiter:
                    // 匹配成功：低饱和强调背景
                    overlayView.layer?.backgroundColor = isDark
                        ? NSColor(calibratedRed: 0.4, green: 0.6, blue: 0.8, alpha: 0.25).cgColor
                        : NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.7, alpha: 0.15).cgColor
                    overlayView.layer?.cornerRadius = 2
                case .mismatchDelimiter:
                    // 不匹配：错误描边
                    overlayView.layer?.backgroundColor = NSColor.clear.cgColor
                    overlayView.layer?.borderColor = isDark
                        ? NSColor(calibratedRed: 0.9, green: 0.3, blue: 0.3, alpha: 0.7).cgColor
                        : NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 0.6).cgColor
                    overlayView.layer?.borderWidth = 1
                    overlayView.layer?.cornerRadius = 2
                }

                textView.addSubview(overlayView)
                pairMatchOverlays.append(overlayView)
            }
        }

        /// 清空匹配覆盖层
        func clearPairMatchOverlay() {
            for view in pairMatchOverlays {
                view.removeFromSuperview()
            }
            pairMatchOverlays.removeAll()
            lastPairMatchCacheKey = nil
        }

        // MARK: - 自动补全

        /// 刷新补全状态（由文本变更或选区变更驱动）
        func refreshAutocompleteState(textView: UndoTrackingTextView, triggerKind: EditorAutocompleteTriggerKind) {
            guard let docKey = parent.documentKey,
                  let filePath = parent.filePath else {
                dismissAutocompletePopup()
                return
            }

            // 检查文档加载状态
            let wsKey = "\(docKey.project):\(docKey.workspace)"
            if let session = parent.editorStore.editorDocumentsByWorkspace[wsKey]?[docKey.path],
               session.loadStatus != .ready {
                dismissAutocompletePopup()
                return
            }

            let text = textView.string
            let cursorLocation = textView.selectedRange().location

            let context = EditorAutocompleteContext(
                filePath: filePath,
                text: text,
                cursorLocation: cursorLocation,
                triggerKind: triggerKind
            )

            let previousState = parent.editorStore.autocompleteState(for: docKey)
            let newState = autocompleteEngine.update(context: context, previousState: previousState)
            parent.editorStore.updateAutocompleteState(newState, for: docKey)

            if newState.isVisible && !newState.items.isEmpty {
                showAutocompletePopup(textView: textView, state: newState)
            } else {
                dismissAutocompletePopup()
            }
        }

        /// 手动触发补全（Ctrl-Space）
        func triggerManualAutocomplete(textView: UndoTrackingTextView) {
            refreshAutocompleteState(textView: textView, triggerKind: .manual)
        }

        /// 接受当前选中的候选
        func acceptSelectedAutocomplete(textView: UndoTrackingTextView) {
            guard let docKey = parent.documentKey else { return }
            let state = parent.editorStore.autocompleteState(for: docKey)
            guard state.isVisible, state.selectedIndex < state.items.count else { return }

            let selectedItem = state.items[state.selectedIndex]
            guard let result = parent.editorStore.applyAcceptedAutocomplete(
                selectedItem,
                for: docKey,
                currentText: textView.string
            ) else { return }

            // 作为编辑命令记录到共享历史
            let currentText = textView.string
            let command = EditorEditCommand(
                mutation: EditorTextMutation(
                    rangeLocation: state.replacementRange.location,
                    rangeLength: state.replacementRange.length,
                    replacementText: selectedItem.insertText
                ),
                beforeSelection: EditorSelectionSnapshot(
                    location: textView.selectedRange().location,
                    length: textView.selectedRange().length
                ),
                afterSelection: result.selections.primarySnapshot,
                timestamp: Date(),
                replacedText: (currentText as NSString).substring(with: state.replacementRange)
            )
            _ = parent.editorStore.recordEdit(
                currentText: currentText,
                command: command,
                documentKey: docKey
            )

            // 写回文本和选区
            isProgrammaticTextUpdate = true
            textView.string = result.text
            let primarySel = result.selections.primarySnapshot
            textView.setSelectedRange(NSRange(location: primarySel.location, length: primarySel.length))
            isProgrammaticTextUpdate = false

            parent.text = result.text

            // 关闭补全弹层
            dismissAutocompletePopup()

            // 刷新高亮、折叠、括号匹配、gutter
            applySyntaxHighlighting(to: textView)
            applyFoldingProjection(to: textView)
            refreshPairMatchOverlay(textView: textView)
        }

        /// 候选导航：上移
        func moveAutocompleteSelectionUp() {
            guard let docKey = parent.documentKey else { return }
            var state = parent.editorStore.autocompleteState(for: docKey)
            guard state.isVisible, !state.items.isEmpty else { return }
            state.selectedIndex = (state.selectedIndex - 1 + state.items.count) % state.items.count
            parent.editorStore.updateAutocompleteState(state, for: docKey)
            autocompletePopupView?.updateSelection(state.selectedIndex)
        }

        /// 候选导航：下移
        func moveAutocompleteSelectionDown() {
            guard let docKey = parent.documentKey else { return }
            var state = parent.editorStore.autocompleteState(for: docKey)
            guard state.isVisible, !state.items.isEmpty else { return }
            state.selectedIndex = (state.selectedIndex + 1) % state.items.count
            parent.editorStore.updateAutocompleteState(state, for: docKey)
            autocompletePopupView?.updateSelection(state.selectedIndex)
        }

        /// 显示补全弹层
        private func showAutocompletePopup(textView: UndoTrackingTextView, state: EditorAutocompleteState) {
            if autocompletePopupView == nil {
                let popup = EditorAutocompletePopupView()
                popup.onAccept = { [weak self] index in
                    guard let self = self, let textView = self.textView else { return }
                    guard let docKey = self.parent.documentKey else { return }
                    var s = self.parent.editorStore.autocompleteState(for: docKey)
                    s.selectedIndex = index
                    self.parent.editorStore.updateAutocompleteState(s, for: docKey)
                    self.acceptSelectedAutocomplete(textView: textView)
                }
                textView.addSubview(popup)
                autocompletePopupView = popup
            }

            guard let popup = autocompletePopupView else { return }
            popup.update(items: state.items, selectedIndex: state.selectedIndex)

            // 定位到 caret rect
            let caretRect = caretRectInTextView(textView: textView, at: state.replacementRange.location)
            let popupSize = popup.fittingPopupSize
            var origin = NSPoint(
                x: caretRect.origin.x,
                y: caretRect.maxY + 2
            )

            // 检查是否需要翻转到上方
            if let scrollView = textView.enclosingScrollView {
                let visibleRect = scrollView.documentVisibleRect
                if origin.y + popupSize.height > visibleRect.maxY {
                    origin.y = caretRect.origin.y - popupSize.height - 2
                }
            }

            popup.frame = NSRect(origin: origin, size: popupSize)
            popup.isHidden = false
        }

        /// 关闭补全弹层
        func dismissAutocompletePopup() {
            autocompletePopupView?.isHidden = true
            if let docKey = parent.documentKey {
                parent.editorStore.resetAutocompleteState(for: docKey)
            }
        }

        /// 补全面板是否可见
        var isAutocompleteVisible: Bool {
            guard let docKey = parent.documentKey else { return false }
            return parent.editorStore.autocompleteState(for: docKey).isVisible
        }

        /// 计算 textView 中指定字符偏移处的 caret rect
        private func caretRectInTextView(textView: UndoTrackingTextView, at charOffset: Int) -> NSRect {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return .zero
            }
            let safeOffset = min(charOffset, (textView.string as NSString).length)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: max(safeOffset, 0))
            let rect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 0),
                in: textContainer
            )
            return NSRect(
                x: rect.origin.x + textView.textContainerInset.width + textView.textContainerOrigin.x,
                y: rect.origin.y + textView.textContainerInset.height,
                width: 1,
                height: rect.height
            )
        }
    }
}

/// 支持撤销/重做状态追踪的 NSTextView 子类。
/// 通过 NSUndoManager 通知监听撤销/重做状态变化并回调外部。
class UndoTrackingTextView: NSTextView {
    var onUndoRedoStateDidChange: ((Bool, Bool) -> Void)?
    /// 补全键盘事件转发（由 Coordinator 设置）
    var onAutocompleteKeyDown: ((NSEvent) -> Bool)?
    private var undoObservers: [NSObjectProtocol] = []

    override func keyDown(with event: NSEvent) {
        // 先尝试补全键盘处理
        if let handler = onAutocompleteKeyDown, handler(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Ctrl-Space 手动触发补全
        if event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == " " {
            if let handler = onAutocompleteKeyDown, handler(event) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    func reportUndoRedoState() {
        let canUndo = undoManager?.canUndo ?? false
        let canRedo = undoManager?.canRedo ?? false
        onUndoRedoStateDidChange?(canUndo, canRedo)
    }

    func startObservingUndoManager() {
        stopObservingUndoManager()
        guard let um = undoManager else { return }
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerCheckpoint,
        ]
        for name in names {
            let obs = nc.addObserver(forName: name, object: um, queue: .main) { [weak self] _ in
                self?.reportUndoRedoState()
            }
            undoObservers.append(obs)
        }
    }

    func stopObservingUndoManager() {
        let nc = NotificationCenter.default
        for obs in undoObservers { nc.removeObserver(obs) }
        undoObservers.removeAll()
    }

    deinit {
        stopObservingUndoManager()
    }
}

// MARK: - 编辑器补全候选弹层（macOS）

/// 补全候选弹层视图（NSView 子类，作为 textView 的子视图显示）。
/// 纯展示层，不持有聊天输入或 AI 补全的状态模型。
class EditorAutocompletePopupView: NSView {
    var onAccept: ((Int) -> Void)?
    private var items: [EditorAutocompleteItem] = []
    private var selectedIndex: Int = 0
    private var rowViews: [NSView] = []

    private let rowHeight: CGFloat = 24
    private let maxVisibleRows = 8
    private let popupWidth: CGFloat = 280

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var fittingPopupSize: NSSize {
        let rows = min(items.count, maxVisibleRows)
        return NSSize(width: popupWidth, height: CGFloat(rows) * rowHeight + 4)
    }

    func update(items: [EditorAutocompleteItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = selectedIndex
        rebuildRows()
    }

    func updateSelection(_ index: Int) {
        let oldIndex = selectedIndex
        selectedIndex = index
        if oldIndex < rowViews.count {
            updateRowAppearance(rowViews[oldIndex], isSelected: false)
        }
        if index < rowViews.count {
            updateRowAppearance(rowViews[index], isSelected: true)
            // 滚动到可见
            rowViews[index].scrollToVisible(rowViews[index].bounds)
        }
    }

    private func rebuildRows() {
        for v in rowViews { v.removeFromSuperview() }
        rowViews.removeAll()

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: fittingPopupSize.height))
        scrollView.hasVerticalScroller = items.count > maxVisibleRows
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: CGFloat(items.count) * rowHeight))

        for (i, item) in items.enumerated() {
            let row = makeRow(item: item, index: i, isSelected: i == selectedIndex)
            row.frame = NSRect(x: 0, y: CGFloat(items.count - 1 - i) * rowHeight, width: popupWidth, height: rowHeight)
            documentView.addSubview(row)
            rowViews.append(row)
        }

        scrollView.documentView = documentView
        // 清除旧的 scroll views
        for sub in subviews { sub.removeFromSuperview() }
        addSubview(scrollView)

        // 滚动到选中行
        if selectedIndex < rowViews.count {
            rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
        }
    }

    private func makeRow(item: EditorAutocompleteItem, index: Int, isSelected: Bool) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        updateRowAppearance(row, isSelected: isSelected)

        // 图标区域
        let iconLabel = NSTextField(labelWithString: kindIcon(item.kind))
        iconLabel.font = .systemFont(ofSize: 11)
        iconLabel.frame = NSRect(x: 4, y: 2, width: 20, height: 20)
        iconLabel.alignment = .center
        row.addSubview(iconLabel)

        // 标题
        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = .textColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 26, y: 2, width: popupWidth - 90, height: 20)
        row.addSubview(titleLabel)

        // 类别标签
        if let detail = item.detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 10)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.alignment = .right
            detailLabel.frame = NSRect(x: popupWidth - 64, y: 4, width: 58, height: 16)
            row.addSubview(detailLabel)
        }

        // 点击手势
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
        row.addGestureRecognizer(click)

        return row
    }

    private func updateRowAppearance(_ row: NSView, isSelected: Bool) {
        row.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            : NSColor.clear.cgColor
    }

    private func kindIcon(_ kind: EditorAutocompleteItemKind) -> String {
        switch kind {
        case .documentSymbol: return "𝑥"
        case .languageKeyword: return "K"
        case .languageTemplate: return "T"
        }
    }

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view,
              let index = rowViews.firstIndex(of: view) else { return }
        onAccept?(index)
    }
}

// MARK: - 统一 Gutter 视图（macOS）

/// 编辑器统一 gutter 覆盖层。
/// 作为 NSScrollView 的 contentView 子视图，跟随滚动。
/// 通过共享 gutter 投影渲染行号、当前行高亮、断点圆点、折叠控件和缩进导线。
class EditorFoldOverlayView: NSView {
    /// 折叠/展开按钮点击回调
    var onToggleFold: ((EditorFoldRegionID) -> Void)?
    /// 断点切换回调（0-based 行号）
    var onToggleBreakpoint: ((Int) -> Void)?

    private var lineItemRects: [(item: EditorGutterLineItem, rect: NSRect)] = []
    private var guideLines: [(guide: EditorIndentGuideSegment, startY: CGFloat, endY: CGFloat, x: CGFloat)] = []
    private var isDarkMode: Bool = false
    private var metrics: EditorGutterLayoutMetrics = EditorGutterLayoutMetrics(lineNumberDigits: 1)
    private var widthConstraint: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    /// 更新 gutter 宽度约束
    func updateGutterWidth(_ width: CGFloat) {
        if let wc = widthConstraint {
            if wc.constant != width {
                wc.constant = width
            }
        } else {
            let wc = widthAnchor.constraint(equalToConstant: width)
            wc.isActive = true
            widthConstraint = wc
        }
    }

    func updateContent(
        lineItems: [(item: EditorGutterLineItem, rect: NSRect)],
        guides: [(guide: EditorIndentGuideSegment, startY: CGFloat, endY: CGFloat, x: CGFloat)],
        isDarkMode: Bool,
        metrics: EditorGutterLayoutMetrics
    ) {
        self.lineItemRects = lineItems
        self.guideLines = guides
        self.isDarkMode = isDarkMode
        self.metrics = metrics
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let charWidth: CGFloat = 7.8
        // 断点区域在最左边
        let breakpointAreaWidth: CGFloat = 14
        // 折叠按钮区域紧接断点
        let foldAreaWidth: CGFloat = 14
        let accessoryWidth = breakpointAreaWidth + foldAreaWidth
        // 行号文字起始 x
        let lineNumberX = accessoryWidth + 2

        // 绘制缩进导线
        let guideColor = isDarkMode
            ? NSColor(white: 1.0, alpha: 0.08)
            : NSColor(white: 0.0, alpha: 0.08)
        context.setStrokeColor(guideColor.cgColor)
        context.setLineWidth(1.0)

        for guideLine in guideLines {
            guard guideLine.endY >= dirtyRect.minY, guideLine.startY <= dirtyRect.maxY else { continue }
            context.move(to: CGPoint(x: guideLine.x, y: guideLine.startY))
            context.addLine(to: CGPoint(x: guideLine.x, y: guideLine.endY))
            context.strokePath()
        }

        // 绘制行号、当前行高亮、断点和折叠按钮
        let normalLineNumberColor = isDarkMode
            ? NSColor(white: 1.0, alpha: 0.3)
            : NSColor(white: 0.0, alpha: 0.3)
        let currentLineNumberColor = isDarkMode
            ? NSColor(white: 1.0, alpha: 0.8)
            : NSColor(white: 0.0, alpha: 0.8)
        let currentLineHighlightColor = isDarkMode
            ? NSColor(white: 1.0, alpha: 0.06)
            : NSColor(white: 0.0, alpha: 0.04)
        let breakpointColor = NSColor(red: 0.9, green: 0.25, blue: 0.2, alpha: 0.85)
        let foldButtonColor = isDarkMode
            ? NSColor(white: 1.0, alpha: 0.35)
            : NSColor(white: 0.0, alpha: 0.35)

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        for (item, rect) in lineItemRects {
            guard rect.intersects(dirtyRect) else { continue }

            // 当前行背景高亮
            if item.isCurrentLine {
                context.setFillColor(currentLineHighlightColor.cgColor)
                context.fill(CGRect(x: 0, y: rect.origin.y, width: bounds.width, height: rect.height))
            }

            // 断点圆点
            if item.hasBreakpoint {
                let bpSize: CGFloat = 10
                let bpRect = CGRect(
                    x: (breakpointAreaWidth - bpSize) / 2,
                    y: rect.midY - bpSize / 2,
                    width: bpSize,
                    height: bpSize
                )
                context.setFillColor(breakpointColor.cgColor)
                context.fillEllipse(in: bpRect)
            }

            // 折叠按钮
            if let foldControl = item.foldControl {
                let buttonSize: CGFloat = 10
                let buttonCenterX = breakpointAreaWidth + foldAreaWidth / 2
                let buttonCenterY = rect.midY

                let trianglePath = NSBezierPath()
                if foldControl.isCollapsed {
                    // 右指三角 ▶
                    trianglePath.move(to: NSPoint(x: buttonCenterX - buttonSize / 3, y: buttonCenterY - buttonSize / 2))
                    trianglePath.line(to: NSPoint(x: buttonCenterX + buttonSize / 3, y: buttonCenterY))
                    trianglePath.line(to: NSPoint(x: buttonCenterX - buttonSize / 3, y: buttonCenterY + buttonSize / 2))
                } else {
                    // 下指三角 ▼
                    trianglePath.move(to: NSPoint(x: buttonCenterX - buttonSize / 2, y: buttonCenterY - buttonSize / 3))
                    trianglePath.line(to: NSPoint(x: buttonCenterX + buttonSize / 2, y: buttonCenterY - buttonSize / 3))
                    trianglePath.line(to: NSPoint(x: buttonCenterX, y: buttonCenterY + buttonSize / 3))
                }
                trianglePath.close()
                foldButtonColor.setFill()
                trianglePath.fill()
            }

            // 行号文字（右对齐）
            let textColor = item.isCurrentLine ? currentLineNumberColor : normalLineNumberColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
            ]
            let numStr = item.displayLineNumber as NSString
            let textSize = numStr.size(withAttributes: attributes)
            let maxDigitWidth = charWidth * CGFloat(max(metrics.lineNumberDigits, metrics.minimumCharacterColumns))
            let textX = lineNumberX + maxDigitWidth - textSize.width
            let textY = rect.origin.y + (rect.height - textSize.height) / 2
            numStr.draw(at: NSPoint(x: textX, y: textY), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let breakpointAreaWidth: CGFloat = 14
        let foldAreaWidth: CGFloat = 14

        for (item, rect) in lineItemRects {
            let hitRect = rect.insetBy(dx: -4, dy: -2)
            guard hitRect.contains(location) else { continue }

            // 折叠按钮区域命中检测
            if item.foldControl != nil {
                let foldHitX = breakpointAreaWidth...(breakpointAreaWidth + foldAreaWidth)
                if foldHitX.contains(location.x) {
                    onToggleFold?(item.foldControl!.region.id)
                    return
                }
            }

            // 断点区域命中检测
            if location.x < breakpointAreaWidth + 4 {
                onToggleBreakpoint?(item.line)
                return
            }
        }

        super.mouseDown(with: event)
    }

    override var isFlipped: Bool { true }

    // 使 overlay 对鼠标事件透明（除了折叠按钮和断点区域）
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let breakpointAreaWidth: CGFloat = 14
        let foldAreaWidth: CGFloat = 14

        for (item, rect) in lineItemRects {
            let hitRect = rect.insetBy(dx: -4, dy: -2)
            guard hitRect.contains(local) else { continue }

            // 折叠按钮区域
            if item.foldControl != nil {
                let foldHitX = breakpointAreaWidth...(breakpointAreaWidth + foldAreaWidth)
                if foldHitX.contains(local.x) { return self }
            }

            // 断点区域
            if local.x < breakpointAreaWidth + 4 { return self }
        }
        return nil
    }
}
#endif

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
