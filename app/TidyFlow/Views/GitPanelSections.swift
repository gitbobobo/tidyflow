import SwiftUI

// MARK: - 暂存的更改（均分区域，内部可滚动）

struct GitStagedChangesSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    let projection: GitWorkspaceProjection
    @Binding var isExpanded: Bool
    var onRequestAIReview: (() -> Void)? = nil

    var body: some View {
        let staged = projection.stagedItems
        VStack(spacing: 0) {
            // 小标题（始终显示）
            SectionHeader(
                title: "git.stagedChanges".localized,
                count: staged.count,
                isExpanded: $isExpanded
            ) {
                HStack(spacing: 4) {
                    // AI 审查按钮
                    if let onRequestAIReview {
                        Button(action: onRequestAIReview) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("git.aiReview".localized)
                        .disabled(staged.isEmpty)
                    }

                    Button(action: unstageAll) {
                        Image(systemName: "minus")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("git.unstageAll".localized)
                }
            }

            // 展开时显示文件列表（可滚动）
            if isExpanded {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(staged) { item in
                            GitStatusRow(item: item, isStaged: true)
                                .environmentObject(appState)
                        }
                    }
                }
            }
        }
    }

    private func unstageAll() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        gitCache.gitUnstage(workspaceKey: ws, path: nil, scope: "all")
    }
}

// MARK: - 更改区域（均分区域，内部可滚动）

struct GitChangesSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    let projection: GitWorkspaceProjection
    @Binding var isExpanded: Bool
    @Binding var showDiscardAllConfirm: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 小标题（始终显示）
            SectionHeader(
                title: "git.changes".localized,
                count: projection.unstagedCount,
                isExpanded: $isExpanded
            ) {
                HStack(spacing: 4) {
                    Button(action: stageAll) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("git.stageAll".localized)
                    .disabled(!projection.canStageAll)

                    Button(action: { showDiscardAllConfirm = true }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("git.discardAll".localized)
                    .disabled(!projection.canDiscardAll)
                }
            }

            // 展开时显示文件列表（可滚动）
            if isExpanded {
                ScrollView {
                    VStack(spacing: 0) {
                        if projection.isLoading && !projection.hasResolvedStatus && projection.unstagedItems.isEmpty {
                            LoadingRow()
                        } else if !projection.isGitRepo {
                            EmptyRow(text: "git.notGitRepo".localized)
                        } else if projection.unstagedItems.isEmpty {
                            EmptyRow(text: "git.noChanges".localized)
                        } else {
                            ForEach(projection.unstagedItems) { item in
                                GitStatusRow(item: item, isStaged: false)
                                    .environmentObject(appState)
                            }
                        }
                    }
                }
            }
        }
    }

    private func stageAll() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        gitCache.gitStage(workspaceKey: ws, path: nil, scope: "all")
    }
}

// MARK: - 通用可折叠区域标题栏

/// 各 Section 通用的标题栏：展开/折叠箭头 + 标题 + 数量徽标 + 操作按钮
struct SectionHeader<Actions: View>: View {
    let title: String
    var count: Int? = nil
    @Binding var isExpanded: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
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

            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
}

// MARK: - 文件状态行

struct GitStatusRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
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
        gitCache.gitStage(workspaceKey: ws, path: item.path, scope: "file")
    }

    private func unstageFile() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        gitCache.gitUnstage(workspaceKey: ws, path: item.path, scope: "file")
    }

    private func discardFile() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        gitCache.gitDiscard(workspaceKey: ws, path: item.path, scope: "file")
    }
}

// MARK: - 冲突横幅区域（Git 面板内嵌，不替换整个面板）

/// 冲突横幅：仅用于在普通 Git 面板中出现少量冲突时的轻量提示。
/// 超过 1 个冲突文件时由 NativeGitPanelView 自动切换到 GitConflictWizardView 全屏向导。
struct GitConflictBannerSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState

    var body: some View {
        EmptyView()
    }
}

// MARK: - v1.50: Stash 区域

/// Stash 可折叠区域，位于变更区和提交历史之间
struct GitStashSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    let project: String
    let workspace: String
    @Binding var isExpanded: Bool
    @State private var showSaveForm: Bool = false
    @State private var saveMessage: String = ""
    @State private var includeUntracked: Bool = false
    @State private var keepIndex: Bool = false

    private var stashListCache: GitStashListCache {
        gitCache.getStashListCache(project: project, workspace: workspace)
    }

    private var cacheKey: String {
        gitCache.stashCacheKey(project: project, workspace: workspace)
    }

    private var selectedStashId: String? {
        gitCache.selectedStashId[cacheKey]
    }

    private var isOpInFlight: Bool {
        gitCache.stashOpInFlight[cacheKey] ?? false
    }

    private var lastError: String? {
        gitCache.stashLastError[cacheKey]
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "Stashes",
                count: stashListCache.entries.count,
                isExpanded: $isExpanded
            ) {
                HStack(spacing: 4) {
                    Button(action: { showSaveForm.toggle() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("git.stash.save".localized)

                    Button(action: refreshStashList) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("git.stash.refresh".localized)
                }
            }

            if isExpanded {
                // 保存表单
                if showSaveForm {
                    stashSaveForm
                    Divider()
                }

                // 错误提示
                if let error = lastError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            gitCache.stashLastError.removeValue(forKey: cacheKey)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }

                if stashListCache.isLoading && stashListCache.entries.isEmpty {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Loading...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if stashListCache.entries.isEmpty {
                    VStack(spacing: 6) {
                        Text("git.stash.empty".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        if !showSaveForm {
                            Button("git.stash.saveNow".localized) {
                                showSaveForm = true
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    // 左右两栏布局
                    HSplitView {
                        // 左侧：stash 列表
                        stashListPanel
                            .frame(minWidth: 140, idealWidth: 180)

                        // 右侧：stash 详情
                        stashDetailPanel
                            .frame(minWidth: 200)
                    }
                }
            }
        }
    }

    // MARK: - 保存表单

    private var stashSaveForm: some View {
        VStack(spacing: 6) {
            TextField("git.stash.messagePlaceholder".localized, text: $saveMessage)
                .font(.system(size: 11))
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Toggle("git.stash.includeUntracked".localized, isOn: $includeUntracked)
                    .font(.system(size: 10))
                Toggle("git.stash.keepIndex".localized, isOn: $keepIndex)
                    .font(.system(size: 10))
                Spacer()
                Button("common.cancel".localized) {
                    showSaveForm = false
                    saveMessage = ""
                }
                .font(.system(size: 11))
                Button("git.stash.save".localized) {
                    performSave()
                }
                .font(.system(size: 11))
                .disabled(isOpInFlight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 列表面板

    private var stashListPanel: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(stashListCache.entries) { entry in
                    StashListRow(
                        entry: entry,
                        isSelected: entry.stashId == selectedStashId
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectStash(entry.stashId)
                    }
                }
            }
        }
    }

    // MARK: - 详情面板

    private var stashDetailPanel: some View {
        Group {
            if let stashId = selectedStashId {
                StashDetailView(
                    project: project,
                    workspace: workspace,
                    stashId: stashId,
                    isOpInFlight: isOpInFlight
                )
                .environmentObject(appState)
                .environmentObject(gitCache)
            } else {
                VStack {
                    Spacer()
                    Text("git.stash.selectToView".localized)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Actions

    private func selectStash(_ stashId: String) {
        gitCache.selectedStashId[cacheKey] = stashId
        gitCache.fetchStashShow(project: project, workspace: workspace, stashId: stashId)
    }

    private func refreshStashList() {
        gitCache.fetchStashList(project: project, workspace: workspace, cacheMode: .forceRefresh)
    }

    private func performSave() {
        let msg = saveMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        gitCache.stashSave(
            project: project,
            workspace: workspace,
            message: msg.isEmpty ? nil : msg,
            includeUntracked: includeUntracked,
            keepIndex: keepIndex
        )
        saveMessage = ""
        showSaveForm = false
    }
}

// MARK: - Stash 列表行

struct StashListRow: View {
    let entry: GitStashEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message.isEmpty ? entry.title : entry.message)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(entry.branchName)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(relativeTime(from: entry.createdAt))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if entry.fileCount > 0 {
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text("\(entry.fileCount) files")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func relativeTime(from dateStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: dateStr) else {
            // 尝试不含毫秒的解析
            let alt = ISO8601DateFormatter()
            alt.formatOptions = [.withInternetDateTime]
            guard let d = alt.date(from: dateStr) else { return dateStr }
            return RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
        }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Stash 详情视图

struct StashDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    let project: String
    let workspace: String
    let stashId: String
    let isOpInFlight: Bool
    @State private var selectedFiles: Set<String> = []

    private var showCache: GitStashShowCache {
        gitCache.getStashShowCache(project: project, workspace: workspace, stashId: stashId)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showCache.isLoading && showCache.entry == nil {
                Spacer()
                ProgressView()
                Spacer()
            } else if let entry = showCache.entry {
                // 元数据
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.message.isEmpty ? entry.title : entry.message)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Label(entry.branchName, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("\(showCache.files.count) files")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                Divider()

                // 操作按钮
                HStack(spacing: 6) {
                    Button("Apply") {
                        gitCache.stashApply(project: project, workspace: workspace, stashId: stashId)
                    }
                    .disabled(isOpInFlight)

                    Button("Pop") {
                        gitCache.stashPop(project: project, workspace: workspace, stashId: stashId)
                    }
                    .disabled(isOpInFlight)

                    Button("Drop") {
                        gitCache.stashDrop(project: project, workspace: workspace, stashId: stashId)
                    }
                    .disabled(isOpInFlight)
                    .foregroundColor(.red)

                    Spacer()

                    if !selectedFiles.isEmpty {
                        Button("Restore Selected (\(selectedFiles.count))") {
                            gitCache.stashRestorePaths(
                                project: project,
                                workspace: workspace,
                                stashId: stashId,
                                paths: Array(selectedFiles)
                            )
                            selectedFiles.removeAll()
                        }
                        .disabled(isOpInFlight)
                    }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                if isOpInFlight {
                    ProgressView()
                        .scaleEffect(0.6)
                        .padding(.vertical, 2)
                }

                Divider()

                // 文件列表
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(showCache.files) { file in
                            StashFileRow(
                                file: file,
                                isSelected: selectedFiles.contains(file.path),
                                onToggle: {
                                    if selectedFiles.contains(file.path) {
                                        selectedFiles.remove(file.path)
                                    } else {
                                        selectedFiles.insert(file.path)
                                    }
                                }
                            )
                        }
                    }
                }

                // Diff 预览
                if !showCache.diffText.isEmpty {
                    Divider()
                    ScrollView {
                        Text(showCache.diffText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(maxHeight: 200)
                }
            } else {
                Spacer()
                Text("git.stash.selectToView".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
}

// MARK: - Stash 文件行

struct StashFileRow: View {
    let file: GitStashFileEntry
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .onTapGesture { onToggle() }

            Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            if file.sourceKind == "untracked" {
                Text("U")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.gray)
            }

            HStack(spacing: 2) {
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.green)
                }
                if file.deletions > 0 {
                    Text("-\(file.deletions)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.red)
                }
            }

            Text(file.status)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(statusColor(file.status))
                .frame(width: 16, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        default: return .secondary
        }
    }
}
