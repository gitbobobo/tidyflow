import SwiftUI

// MARK: - VSCode 风格 Git 面板主视图

/// 按照 VSCode 源代码管理面板布局设计的 Git 面板
struct NativeGitPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var showDiscardAllConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Toast 通知
            if let toast = appState.gitOpToast {
                GitOpToast(message: toast, isError: appState.gitOpToastIsError)
            }

            ScrollView {
                VStack(spacing: 0) {
                    // 1. 顶部工具栏（源代码管理）
                    GitPanelHeader()
                        .environmentObject(appState)
                    
                    // 2. 提交消息输入框 + 提交按钮
                    GitCommitInputSection()
                        .environmentObject(appState)
                    
                    // 3. 可折叠的更改区域
                    GitChangesSection(showDiscardAllConfirm: $showDiscardAllConfirm)
                        .environmentObject(appState)
                    
                    // 4. 可折叠的图形/历史区域
                    GitGraphSection()
                        .environmentObject(appState)
                    
                    Spacer(minLength: 20)
                }
            }
        }
        .onAppear {
            loadDataIfNeeded()
        }
        .onChange(of: appState.selectedWorkspaceKey) { _ in
            loadDataIfNeeded()
        }
        .alert("放弃所有更改？", isPresented: $showDiscardAllConfirm) {
            Button("取消", role: .cancel) { }
            Button("放弃", role: .destructive) {
                discardAll()
            }
        } message: {
            Text("这将放弃所有已跟踪文件的本地更改，此操作无法撤销。")
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
}

// MARK: - Toast 通知

struct GitOpToast: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? .red : .green)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .shadow(radius: 2)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - 顶部工具栏

struct GitPanelHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Text("源代码管理")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            
            Spacer()
            
            // 刷新按钮
            Button(action: refreshAll) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("刷新")
            .disabled(isLoading)
            
            // 更多操作（占位）
            Menu {
                Button("查看提交历史") {
                    refreshLog()
                }
                Divider()
                Button("放弃所有更改", role: .destructive) {
                    // 由外部处理
                }
                .disabled(!hasChanges)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var isLoading: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.getGitStatusCache(workspaceKey: ws)?.isLoading == true
    }

    private var hasChanges: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getGitStatusCache(workspaceKey: ws) else { return false }
        return !cache.items.isEmpty
    }

    private func refreshAll() {
        appState.refreshGitStatus()
        appState.refreshGitLog()
    }

    private func refreshLog() {
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
            TextField("消息（⌘Enter 提交）", text: commitMessageBinding, axis: .vertical)
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
                        Text("提交")
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
                    Button("提交") {
                        performCommit()
                    }
                    .disabled(!canCommit)
                    
                    Button("提交并推送") {
                        // 暂不实现
                    }
                    .disabled(true)
                    
                    Button("提交并同步") {
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
            return "请先暂存更改"
        } else if currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入提交消息"
        } else if isCommitInFlight {
            return "正在提交..."
        } else {
            return "提交暂存的更改"
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
            // Header
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

// MARK: - 更改区域

struct GitChangesSection: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded: Bool = true
    @Binding var showDiscardAllConfirm: Bool

    var body: some View {
        CollapsibleSection(
            title: "更改",
            count: changesCount,
            isExpanded: $isExpanded,
            headerActions: {
                AnyView(
                    HStack(spacing: 4) {
                        // Stage All 按钮
                        Button(action: stageAll) {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("暂存所有更改")
                        .disabled(!hasUnstagedChanges || isStageAllInFlight)
                        
                        // Discard All 按钮
                        Button(action: { showDiscardAllConfirm = true }) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("放弃所有更改")
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
                            EmptyRow(text: "非 Git 仓库")
                        } else if cache.items.isEmpty {
                            EmptyRow(text: "没有更改")
                        } else {
                            // 暂存的更改
                            if cache.hasStagedChanges {
                                StagedChangesSubsection(items: stagedItems(cache.items))
                                    .environmentObject(appState)
                            }
                            
                            // 未暂存的更改
                            let unstaged = unstagedItems(cache.items)
                            if !unstaged.isEmpty {
                                UnstagedChangesSubsection(items: unstaged)
                                    .environmentObject(appState)
                            }
                        }
                    } else {
                        LoadingRow()
                    }
                }
                // 未选中 workspace 时不显示任何内容
            }
        }
    }

    private var changesCount: Int {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getGitStatusCache(workspaceKey: ws) else { return 0 }
        return cache.items.count
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

    private func stagedItems(_ items: [GitStatusItem]) -> [GitStatusItem] {
        items.filter { $0.staged == true }
    }

    private func unstagedItems(_ items: [GitStatusItem]) -> [GitStatusItem] {
        items.filter { $0.staged != true }
    }

    private func stageAll() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitStage(workspaceKey: ws, path: nil, scope: "all")
    }
}

// MARK: - 暂存的更改子区域

struct StagedChangesSubsection: View {
    @EnvironmentObject var appState: AppState
    let items: [GitStatusItem]
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // 子标题
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                
                Text("暂存的更改")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text("\(items.count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Unstage All
                Button(action: unstageAll) {
                    Image(systemName: "minus")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("取消暂存所有")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
            
            if isExpanded {
                ForEach(items) { item in
                    GitStatusRow(item: item, isStaged: true)
                        .environmentObject(appState)
                }
            }
        }
    }

    private func unstageAll() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitUnstage(workspaceKey: ws, path: nil, scope: "all")
    }
}

// MARK: - 未暂存的更改子区域

struct UnstagedChangesSubsection: View {
    @EnvironmentObject var appState: AppState
    let items: [GitStatusItem]
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // 子标题
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                
                Text("更改")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text("\(items.count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
            
            if isExpanded {
                ForEach(items) { item in
                    GitStatusRow(item: item, isStaged: false)
                        .environmentObject(appState)
                }
            }
        }
    }
}

// MARK: - 文件状态行

struct GitStatusRow: View {
    @EnvironmentObject var appState: AppState
    let item: GitStatusItem
    let isStaged: Bool
    @State private var isHovered: Bool = false
    @State private var showDiscardConfirm: Bool = false

    var body: some View {
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
                        .help("取消暂存")
                    } else {
                        // 打开文件
                        Button(action: openFile) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("打开文件")
                        
                        // 放弃更改
                        Button(action: { showDiscardConfirm = true }) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("放弃更改")
                        
                        // 暂存
                        Button(action: stageFile) {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                        .help("暂存更改")
                    }
                }
            }
            
            // 状态标识
            Text(item.status)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(statusColor)
                .frame(width: 20, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            openDiff()
        }
        .alert(isUntracked ? "删除文件？" : "放弃更改？", isPresented: $showDiscardConfirm) {
            Button("取消", role: .cancel) { }
            Button(isUntracked ? "删除" : "放弃", role: .destructive) {
                discardFile()
            }
        } message: {
            Text(isUntracked ? "将永久删除此文件" : "将放弃此文件的所有本地更改")
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
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.addEditorTab(workspaceKey: ws, path: item.path)
    }

    private func openDiff() {
        guard let ws = appState.selectedWorkspaceKey else { return }
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
            title: "图形",
            count: nil,
            isExpanded: $isExpanded,
            headerActions: {
                AnyView(
                    HStack(spacing: 4) {
                        // 自动刷新（占位）
                        Text("自动")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        // 刷新按钮
                        Button(action: refreshLog) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("刷新历史")
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
                            EmptyRow(text: "没有提交历史")
                        } else {
                            ForEach(cache.entries) { entry in
                                GitLogRow(entry: entry)
                            }
                        }
                    } else {
                        LoadingRow()
                    }
                }
                // 未选中 workspace 时不显示任何内容
            }
        }
    }

    private func refreshLog() {
        appState.refreshGitLog()
    }
}

// MARK: - 提交历史行

struct GitLogRow: View {
    let entry: GitLogEntry
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // 提交图标
            Circle()
                .fill(isHead ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            
            // 提交信息
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    // 提交消息
                    Text(entry.message)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    // 分支/标签引用
                    ForEach(displayRefs, id: \.self) { ref in
                        Text(ref)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(refColor(for: ref))
                            .cornerRadius(3)
                    }
                }
                
                // 作者和时间
                HStack(spacing: 4) {
                    Text(entry.author)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    Text("·")
                        .foregroundColor(.secondary)
                    
                    Text(entry.relativeDate)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // SHA（悬停显示）
            if isHovered {
                Text(entry.sha)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var isHead: Bool {
        entry.refs.contains { $0.contains("HEAD") }
    }

    private var displayRefs: [String] {
        // 只显示前 2 个引用，简化显示
        let refs = entry.refs.prefix(2).map { ref -> String in
            // 简化引用名
            if ref.starts(with: "HEAD -> ") {
                return String(ref.dropFirst(8))
            } else if ref.starts(with: "origin/") {
                return String(ref.dropFirst(7))
            } else if ref.starts(with: "tag: ") {
                return String(ref.dropFirst(5))
            }
            return ref
        }
        return Array(refs)
    }

    private func refColor(for ref: String) -> Color {
        if ref.contains("main") || ref.contains("master") {
            return .green
        } else if ref.contains("HEAD") {
            return .accentColor
        } else {
            return .orange
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
