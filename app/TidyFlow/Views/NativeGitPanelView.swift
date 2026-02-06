import SwiftUI
import AppKit

// MARK: - 不获焦浮动面板（用于显示提交详情）

/// 带鼠标追踪的内容视图，用于检测鼠标进出面板
private class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }
    
    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

/// 使用 NSPanel + nonactivatingPanel 实现的浮动面板，不会抢占焦点
final class FloatingPanelController: NSPanel {
    private var hostingView: TrackingHostingView<AnyView>?
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        
        // 面板配置：浮动、透明背景
        self.isFloatingPanel = true
        self.level = .floating
        // 允许在需要时成为 key（如文字选择），但不会主动抢焦点
        self.becomesKeyOnlyIfNeeded = true
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false // 使用 SwiftUI 阴影
        
        // 继承系统外观（支持暗色模式）
        self.appearance = nil
    }
    
    /// 显示时同步主窗口的外观设置
    func syncAppearance(with window: NSWindow) {
        self.appearance = window.effectiveAppearance
    }
    
    /// 允许成为 key 以支持文字选择，但通过 becomesKeyOnlyIfNeeded 限制只在需要时激活
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    
    /// 更新内容并调整大小
    func updateContent(_ content: AnyView) {
        if hostingView == nil {
            let hosting = TrackingHostingView(rootView: content)
            hosting.onMouseEntered = { [weak self] in self?.onMouseEntered?() }
            hosting.onMouseExited = { [weak self] in self?.onMouseExited?() }
            self.contentView = hosting
            self.hostingView = hosting
        } else {
            hostingView?.rootView = content
        }
        // 自适应大小
        if let hosting = hostingView {
            let size = hosting.fittingSize
            self.setContentSize(size)
        }
    }
    
    /// 显示在指定窗口坐标左侧（windowPoint 是窗口坐标系下的点）
    func showNear(windowPoint: NSPoint, in window: NSWindow) {
        guard let hosting = hostingView else { return }
        
        // 同步外观（支持暗色模式）
        syncAppearance(with: window)
        
        let size = hosting.fittingSize
        self.setContentSize(size)
        
        // 将窗口坐标转换为屏幕坐标
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        // 显示在行的左侧，垂直居中
        let origin = NSPoint(x: screenPoint.x - size.width - 8, y: screenPoint.y - size.height / 2)
        self.setFrameOrigin(origin)
        self.orderFront(nil)
    }
    
    func hidePanel() {
        self.orderOut(nil)
    }
}

/// 全局单例管理提交详情浮动面板
final class CommitDetailPanelManager {
    static let shared = CommitDetailPanelManager()
    
    private var panel: FloatingPanelController?
    /// 鼠标是否在面板内
    private(set) var isMouseInPanel: Bool = false
    /// 隐藏的延迟任务
    private var hideWorkItem: DispatchWorkItem?
    /// 当前显示的 entry id
    private(set) var currentEntryId: String?
    
    /// 面板是否正在显示
    var isVisible: Bool {
        panel?.isVisible == true
    }
    
    private init() {}
    
    func show(entry: GitLogEntry, windowPoint: NSPoint, in window: NSWindow) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        currentEntryId = entry.id
        
        let content = AnyView(
            CommitDetailPanelContent(entry: entry)
        )
        
        if panel == nil {
            panel = FloatingPanelController()
            panel?.onMouseEntered = { [weak self] in
                self?.isMouseInPanel = true
                self?.hideWorkItem?.cancel()
                self?.hideWorkItem = nil
            }
            panel?.onMouseExited = { [weak self] in
                self?.isMouseInPanel = false
                self?.scheduleHide()
            }
        }
        panel?.updateContent(content)
        panel?.showNear(windowPoint: windowPoint, in: window)
    }
    
    /// 请求隐藏（会延迟，给用户时间移入面板）
    func requestHide(entryId: String) {
        // 只处理当前显示的 entry
        guard entryId == currentEntryId else { return }
        scheduleHide()
    }
    
    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isMouseInPanel else { return }
            self.panel?.hidePanel()
            self.currentEntryId = nil
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    
    func forceHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.hidePanel()
        currentEntryId = nil
        isMouseInPanel = false
    }
}

/// 浮动面板内的提交详情内容
private struct CommitDetailPanelContent: View {
    let entry: GitLogEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：SHA + 引用标签
            HStack(spacing: 8) {
                // SHA（可复制）
                Text(String(entry.sha.prefix(8)))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .textSelection(.enabled)
                
                // 引用标签
                if !entry.refs.isEmpty {
                    ForEach(entry.refs, id: \.self) { ref in
                        Text(ref)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(refColor(for: ref))
                            .cornerRadius(4)
                    }
                }
                
                Spacer()
            }
            .padding(.bottom, 10)
            
            // 提交消息（支持多行，可选择）
            Text(entry.message)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.bottom, 12)
            
            // 分隔线
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(height: 1)
                .padding(.bottom, 10)
            
            // 作者和时间
            HStack(spacing: 12) {
                // 作者
                HStack(spacing: 4) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(entry.author)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
                
                // 时间
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(entry.relativeDate)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // 完整 SHA（可复制）
            HStack(spacing: 4) {
                Image(systemName: "number")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(entry.sha)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.top, 6)
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
        .shadow(color: Color(NSColor.shadowColor).opacity(0.3), radius: 16, x: 0, y: 8)
    }
    
    /// 根据引用类型返回不同颜色
    private func refColor(for ref: String) -> Color {
        if ref.contains("HEAD") {
            return .accentColor
        } else if ref.hasPrefix("tag:") {
            return .orange
        } else if ref.contains("origin/") {
            return .purple
        } else {
            return .green
        }
    }
}

// MARK: - VSCode 风格 Git 面板主视图

/// 按照 VSCode 源代码管理面板布局设计的 Git 面板
struct NativeGitPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var showDiscardAllConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // 1. 顶部工具栏（源代码管理）
                    GitPanelHeader()
                        .environmentObject(appState)
                    
                    // 2. 提交消息输入框 + 提交按钮
                    GitCommitInputSection()
                        .environmentObject(appState)
                    
                    // 3. 暂存的更改（顶层，仅在有暂存时显示）
                    if hasStagedChangesInWorkspace {
                        GitStagedChangesSection()
                            .environmentObject(appState)
                    }
                    
                    // 4. 更改（顶层，未暂存）
                    GitChangesSection(showDiscardAllConfirm: $showDiscardAllConfirm)
                        .environmentObject(appState)
                    
                    // 5. 可折叠的图形/历史区域
                    GitGraphSection()
                        .environmentObject(appState)
                    
                    Spacer(minLength: 20)
                }
            }
        }
        .onAppear {
            loadDataIfNeeded()
        }
        .onChange(of: appState.selectedWorkspaceKey) { _, _ in
            loadDataIfNeeded()
        }
        .alert("git.discardAll.title".localized, isPresented: $showDiscardAllConfirm) {
            Button("common.cancel".localized, role: .cancel) { }
            Button("common.discard".localized, role: .destructive) {
                discardAll()
            }
        } message: {
            Text("git.discardAll.message".localized)
        }
    }

    private func loadDataIfNeeded() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        
        // 加载 Git 状态
        if appState.shouldFetchGitStatus(workspaceKey: ws) {
            appState.fetchGitStatus(workspaceKey: ws)
        }
        
        // 加载分支信息
        if appState.getGitBranchCache(workspaceKey: ws) == nil {
            appState.fetchGitBranches(workspaceKey: ws)
        }
        
        // 加载 Git 日志
        if appState.shouldFetchGitLog(workspaceKey: ws) {
            appState.fetchGitLog(workspaceKey: ws)
        }
    }

    private func discardAll() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitDiscard(workspaceKey: ws, path: nil, scope: "all")
    }

    /// 当前工作区是否存在暂存的更改（用于决定是否显示「暂存的更改」顶层区）
    private var hasStagedChangesInWorkspace: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getGitStatusCache(workspaceKey: ws) else { return false }
        return cache.hasStagedChanges
    }
}

// MARK: - 顶部工具栏（使用与文件树一致的 PanelHeaderView）

struct GitPanelHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        PanelHeaderView(
            title: "git.sourceControl".localized,
            onRefresh: refreshAll,
            isRefreshDisabled: isLoading
        )
    }

    private var isLoading: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.getGitStatusCache(workspaceKey: ws)?.isLoading == true
    }

    private func refreshAll() {
        appState.refreshGitStatus()
        appState.refreshGitLog()
    }
}

// MARK: - 提交消息输入区域

struct GitCommitInputSection: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isMessageFocused: Bool
    @State private var showCommitMenu: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            // 提交消息输入框
            TextField("git.commitMessage.placeholder".localized, text: commitMessageBinding, axis: .vertical)
                .font(.system(size: 12))
                .lineLimit(1...10)
                .cornerRadius(2)
                .focused($isMessageFocused)
                .onSubmit {
                    if canCommit {
                        performCommit()
                    }
                }
                .disabled(isCommitInFlight)
            
            // 提交按钮（VSCode 风格：带下拉箭头的蓝色按钮）
            HStack(spacing: 0) {
                Button(action: performCommit) {
                    HStack(spacing: 4) {
                        if isCommitInFlight {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text("git.commit".localized)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .disabled(!canCommit || isCommitInFlight)
                
                Divider()
                    .frame(height: 20)
                    .background(Color.white.opacity(0.3))
                
                // 下拉菜单（占位）
                Menu {
                    Button("git.commit".localized) {
                        performCommit()
                    }
                    .disabled(!canCommit)
                    
                    Button("git.commitAndPush".localized) {
                        // 暂不实现
                    }
                    .disabled(true)
                    
                    Button("git.commitAndSync".localized) {
                        // 暂不实现
                    }
                    .disabled(true)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
            }
            .foregroundColor(canCommit ? .white : .secondary)
            .background(canCommit ? Color.accentColor : Color.gray.opacity(0.3))
            .cornerRadius(4)
            .help(commitButtonHelp)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var commitMessageBinding: Binding<String> {
        Binding(
            get: {
                guard let ws = appState.selectedWorkspaceKey else { return "" }
                return appState.commitMessage[ws] ?? ""
            },
            set: { newValue in
                guard let ws = appState.selectedWorkspaceKey else { return }
                appState.commitMessage[ws] = newValue
            }
        )
    }

    private var currentMessage: String {
        guard let ws = appState.selectedWorkspaceKey else { return "" }
        return appState.commitMessage[ws] ?? ""
    }

    private var hasStagedChanges: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.hasStagedChanges(workspaceKey: ws)
    }

    private var isCommitInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isCommitInFlight(workspaceKey: ws)
    }

    private var canCommit: Bool {
        let trimmedMessage = currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasStagedChanges && !trimmedMessage.isEmpty && !isCommitInFlight
    }

    private var commitButtonHelp: String {
        if !hasStagedChanges {
            return "git.stageFirst".localized
        } else if currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "git.enterMessage".localized
        } else if isCommitInFlight {
            return "git.committing".localized
        } else {
            return "git.commitStaged".localized
        }
    }

    private func performCommit() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitCommit(workspaceKey: ws, message: currentMessage)
    }
}

// MARK: - 可折叠 Section 组件

struct CollapsibleSection<Content: View>: View {
    let title: String
    let count: Int?
    let isExpanded: Binding<Bool>
    let content: () -> Content
    var headerActions: (() -> AnyView)?

    init(
        title: String,
        count: Int? = nil,
        isExpanded: Binding<Bool>,
        headerActions: (() -> AnyView)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.count = count
        self.isExpanded = isExpanded
        self.headerActions = headerActions
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header：整行可点击展开/折叠（含标题与空白区域）
            HStack(spacing: 6) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
                
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                
                if let count = count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor)
                        .cornerRadius(8)
                }
                
                Spacer()
                
                if let actions = headerActions {
                    actions()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            }
            
            // Content
            if isExpanded.wrappedValue {
                content()
            }
        }
    }
}

// MARK: - 暂存的更改（顶层）

struct GitStagedChangesSection: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded: Bool = true

    var body: some View {
        CollapsibleSection(
            title: "git.stagedChanges".localized,
            count: stagedCount,
            isExpanded: $isExpanded,
            headerActions: {
                AnyView(
                    HStack(spacing: 4) {
                        Button(action: unstageAll) {
                            Image(systemName: "minus")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("git.unstageAll".localized)
                    }
                )
            }
        ) {
            VStack(spacing: 0) {
                ForEach(stagedItems) { item in
                    GitStatusRow(item: item, isStaged: true)
                        .environmentObject(appState)
                }
            }
        }
    }

    private var stagedCount: Int {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getGitStatusCache(workspaceKey: ws) else { return 0 }
        return cache.items.filter { $0.staged == true }.count
    }

    private var stagedItems: [GitStatusItem] {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getGitStatusCache(workspaceKey: ws) else { return [] }
        return cache.items.filter { $0.staged == true }
    }

    private func unstageAll() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitUnstage(workspaceKey: ws, path: nil, scope: "all")
    }
}

// MARK: - 更改区域（仅未暂存）

struct GitChangesSection: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded: Bool = true
    @Binding var showDiscardAllConfirm: Bool

    var body: some View {
        CollapsibleSection(
            title: "git.changes".localized,
            count: unstagedCount,
            isExpanded: $isExpanded,
            headerActions: {
                AnyView(
                    HStack(spacing: 4) {
                        Button(action: stageAll) {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("git.stageAll".localized)
                        .disabled(!hasUnstagedChanges || isStageAllInFlight)
                        
                        Button(action: { showDiscardAllConfirm = true }) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("git.discardAll".localized)
                        .disabled(!hasTrackedChanges)
                    }
                )
            }
        ) {
            VStack(spacing: 0) {
                if let ws = appState.selectedWorkspaceKey {
                    if let cache = appState.getGitStatusCache(workspaceKey: ws) {
                        if cache.isLoading && cache.items.isEmpty {
                            LoadingRow()
                        } else if !cache.isGitRepo {
                            EmptyRow(text: "git.notGitRepo".localized)
                        } else {
                            let unstaged = unstagedItems(cache.items)
                            if unstaged.isEmpty {
                                EmptyRow(text: "git.noChanges".localized)
                            } else {
                                ForEach(unstaged) { item in
                                    GitStatusRow(item: item, isStaged: false)
                                        .environmentObject(appState)
                                }
                            }
                        }
                    } else {
                        LoadingRow()
                    }
                }
            }
        }
    }

    private var unstagedCount: Int {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getGitStatusCache(workspaceKey: ws) else { return 0 }
        return cache.items.filter { $0.staged != true }.count
    }

    private var hasUnstagedChanges: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getGitStatusCache(workspaceKey: ws) else { return false }
        return cache.items.contains { $0.status == "??" || $0.status == "M" || $0.status == "A" || $0.status == "D" }
    }

    private var hasTrackedChanges: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getGitStatusCache(workspaceKey: ws) else { return false }
        return cache.items.contains { $0.status != "??" }
    }

    private var isStageAllInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isGitOpInFlight(workspaceKey: ws, path: nil, op: "stage")
    }

    private func unstagedItems(_ items: [GitStatusItem]) -> [GitStatusItem] {
        items.filter { $0.staged != true }
    }

    private func stageAll() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitStage(workspaceKey: ws, path: nil, scope: "all")
    }
}

// MARK: - 文件状态行

struct GitStatusRow: View {
    @EnvironmentObject var appState: AppState
    let item: GitStatusItem
    let isStaged: Bool
    @State private var isHovered: Bool = false
    @State private var showDiscardConfirm: Bool = false

    /// 判断当前文件是否被选中（正在查看 Diff）
    private var isSelected: Bool {
        guard appState.currentGlobalWorkspaceKey != nil,
              let activeTab = appState.getActiveTab(),
              activeTab.kind == .diff,
              activeTab.payload == item.path else {
            return false
        }
        // 精确匹配 diff 模式（暂存/工作区）
        let tabMode = activeTab.diffMode ?? "working"
        return tabMode == (isStaged ? "staged" : "working")
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧选中指示条
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 3)

            HStack(spacing: 8) {
                // 文件图标
                Image(systemName: fileIcon)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 16)
            
            // 文件名
            VStack(alignment: .leading, spacing: 0) {
                Text(fileName)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if let dir = directoryPath {
                    Text(dir)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // 操作按钮（悬停显示）
            if isHovered {
                HStack(spacing: 4) {
                    if isStaged {
                        // 取消暂存
                        Button(action: unstageFile) {
                            Image(systemName: "minus")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("git.unstage".localized)
                    } else {
                        // 打开文件
                        Button(action: openFile) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("git.openFile".localized)
                        
                        // 放弃更改
                        Button(action: { showDiscardConfirm = true }) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("git.discardChanges".localized)
                        
                        // 暂存
                        Button(action: stageFile) {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                        .help("git.stageChanges".localized)
                    }
                }
            }

            // 行数统计（在操作按钮之后、状态标识之前）
            if let add = item.additions, let del = item.deletions, (add > 0 || del > 0) {
                HStack(spacing: 2) {
                    if add > 0 {
                        Text("+\(add)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    if del > 0 {
                        Text("-\(del)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.red)
                    }
                }
            }

            // 状态标识
            Text(item.status)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(statusColor)
                .frame(width: 20, alignment: .trailing)
            }
            .padding(.leading, 17)
            .padding(.trailing, 20)
        }
        .padding(.vertical, 4)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            openDiff()
        }
        .alert(isUntracked ? "git.deleteFile.title".localized : "git.discardChanges.title".localized, isPresented: $showDiscardConfirm) {
            Button("common.cancel".localized, role: .cancel) { }
            Button(isUntracked ? "common.delete".localized : "common.discard".localized, role: .destructive) {
                discardFile()
            }
        } message: {
            Text(isUntracked ? "git.deleteFile.message".localized : "git.discardChanges.message".localized)
        }
    }

    private var fileName: String {
        item.path.split(separator: "/").last.map(String.init) ?? item.path
    }

    private var directoryPath: String? {
        let components = item.path.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    private var fileIcon: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "rs": return "gear"
        case "js", "ts", "jsx", "tsx": return "j.square"
        case "json": return "curlybraces"
        case "md": return "doc.richtext"
        default: return "doc"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        case "??": return .gray
        case "R": return .blue
        case "U": return .purple
        default: return .secondary
        }
    }

    private var isUntracked: Bool {
        item.status == "??"
    }

    private func openFile() {
        guard let ws = appState.currentGlobalWorkspaceKey else { return }
        appState.addEditorTab(workspaceKey: ws, path: item.path)
    }

    private func openDiff() {
        guard let ws = appState.currentGlobalWorkspaceKey else { return }
        appState.addDiffTab(workspaceKey: ws, path: item.path, mode: isStaged ? .staged : .working)
    }

    private func stageFile() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitStage(workspaceKey: ws, path: item.path, scope: "file")
    }

    private func unstageFile() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitUnstage(workspaceKey: ws, path: item.path, scope: "file")
    }

    private func discardFile() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitDiscard(workspaceKey: ws, path: item.path, scope: "file")
    }
}

// MARK: - 图形/历史区域

struct GitGraphSection: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded: Bool = true

    var body: some View {
        CollapsibleSection(
            title: "git.graph".localized,
            count: nil,
            isExpanded: $isExpanded,
            headerActions: {
                AnyView(
                    HStack(spacing: 4) {
                        // 自动刷新（占位）
                        Text("git.auto".localized)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        // 刷新按钮
                        Button(action: refreshLog) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("git.refreshHistory".localized)
                    }
                )
            }
        ) {
            VStack(spacing: 0) {
                if let ws = appState.selectedWorkspaceKey {
                    if let cache = appState.getGitLogCache(workspaceKey: ws) {
                        if cache.isLoading && cache.entries.isEmpty {
                            LoadingRow()
                        } else if cache.entries.isEmpty {
                            EmptyRow(text: "git.noCommitHistory".localized)
                        } else {
                            ForEach(cache.entries) { entry in
                                GitLogRow(entry: entry)
                                    .environmentObject(appState)
                            }
                        }
                    } else {
                        LoadingRow()
                    }
                }
            }
        }
    }

    private func refreshLog() {
        appState.refreshGitLog()
    }
}

// MARK: - 提交历史行（支持折叠展开）

struct GitLogRow: View {
    @EnvironmentObject var appState: AppState
    let entry: GitLogEntry
    @State private var isHovered: Bool = false
    @State private var isExpanded: Bool = false
    @State private var showDetailWorkItem: DispatchWorkItem?
    @State private var isShowingFloatingPanel: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主行：默认只显示一行内容
            GeometryReader { geometry in
                HStack(spacing: 6) {
                    // 展开/折叠指示器
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                    
                    // 提交图标
                    Circle()
                        .fill(isHead ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    
                    // 提交消息（列表只显示一行）
                    Text(entry.message)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // 相对时间
                    Text(entry.relativeDate)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                    // 展开时加载文件列表
                    if isExpanded, let ws = appState.selectedWorkspaceKey {
                        appState.fetchGitShow(workspaceKey: ws, sha: entry.sha)
                    }
                }
                .onHover { hovering in
                    isHovered = hovering
                    handleHover(hovering: hovering, geometry: geometry)
                }
            }
            .frame(height: 26) // 固定行高，避免 GeometryReader 高度为 0
            
            // 展开后显示文件列表
            if isExpanded {
                CommitFilesView(sha: entry.sha)
                    .environmentObject(appState)
            }
        }
    }
    
    private func handleHover(hovering: Bool, geometry: GeometryProxy) {
        showDetailWorkItem?.cancel()
        showDetailWorkItem = nil
        
        if hovering {
            // 获取行的全局坐标 frame
            let globalFrame = geometry.frame(in: .global)
            
            let showPanel = {
                // 获取当前窗口
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
                
                // SwiftUI global 坐标系：原点在窗口内容区域左上角，Y 向下增长
                // NSWindow 坐标系：原点在窗口内容区域左下角，Y 向上增长
                // 需要将 SwiftUI Y 坐标转换为 NSWindow Y 坐标
                let contentHeight = window.contentView?.bounds.height ?? window.frame.height
                let windowPoint = NSPoint(
                    x: globalFrame.minX,
                    y: contentHeight - globalFrame.midY
                )
                
                CommitDetailPanelManager.shared.show(entry: self.entry, windowPoint: windowPoint, in: window)
                self.isShowingFloatingPanel = true
            }
            
            // 如果面板已经显示，直接切换内容，无需等待
            if CommitDetailPanelManager.shared.isVisible {
                showPanel()
            } else {
                // 面板未显示，等待 2 秒后弹出
                let work = DispatchWorkItem {
                    showPanel()
                }
                showDetailWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
            }
        } else {
            if isShowingFloatingPanel {
                // 请求隐藏，会有延迟给用户时间移入面板
                CommitDetailPanelManager.shared.requestHide(entryId: entry.id)
                isShowingFloatingPanel = false
            }
        }
    }

    private var isHead: Bool {
        entry.refs.contains { $0.contains("HEAD") }
    }
}

// MARK: - 提交文件列表视图

struct CommitFilesView: View {
    @EnvironmentObject var appState: AppState
    let sha: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let ws = appState.selectedWorkspaceKey,
               let cache = appState.getGitShowCache(workspaceKey: ws, sha: sha) {
                if cache.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.6)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if let result = cache.result {
                    if result.files.isEmpty {
                        Text("git.noFileChanges".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(result.files) { file in
                            CommitFileRow(file: file)
                        }
                    }
                } else if let error = cache.error {
                    Text(String(format: "git.loadFailed".localized, error))
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 4)
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.6)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }
}

// MARK: - 提交文件行

struct CommitFileRow: View {
    let file: GitShowFileEntry
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // 缩进 + 状态标识
            Text(file.status)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(statusColor)
                .frame(width: 14, alignment: .center)
            
            // 文件图标
            Image(systemName: fileIcon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            
            // 文件名
            Text(fileName)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(1)
            
            // 目录路径
            if let dir = directoryPath {
                Text(dir)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 3)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var fileName: String {
        file.path.split(separator: "/").last.map(String.init) ?? file.path
    }

    private var directoryPath: String? {
        let components = file.path.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    private var fileIcon: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "rs": return "gear"
        case "js", "ts", "jsx", "tsx": return "j.square"
        case "json": return "curlybraces"
        case "md": return "doc.richtext"
        case "toml", "yaml", "yml": return "doc.text"
        default: return "doc"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        case "R": return .blue
        case "C": return .purple
        default: return .secondary
        }
    }
}

// MARK: - 辅助视图

struct LoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.7)
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

struct EmptyRow: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

// MARK: - 预览

#if DEBUG
struct NativeGitPanelView_Previews: PreviewProvider {
    static var previews: some View {
        NativeGitPanelView()
            .environmentObject(AppState())
            .frame(width: 280, height: 600)
    }
}
#endif
