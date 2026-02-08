import SwiftUI

// MARK: - 暂存的更改（均分区域，内部可滚动）

struct GitStagedChangesSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    @Binding var isExpanded: Bool

    /// 缓存过滤结果，避免 stagedCount 和 stagedItems 分别过滤一次
    private var cachedStagedItems: [GitStatusItem] {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = gitCache.getGitStatusCache(workspaceKey: ws) else { return [] }
        return cache.items.filter { $0.staged == true }
    }

    var body: some View {
        let staged = cachedStagedItems
        VStack(spacing: 0) {
            // 小标题（始终显示）
            SectionHeader(
                title: "git.stagedChanges".localized,
                count: staged.count,
                isExpanded: $isExpanded
            ) {
                Button(action: unstageAll) {
                    Image(systemName: "minus")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("git.unstageAll".localized)
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
    @Binding var isExpanded: Bool
    @Binding var showDiscardAllConfirm: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 小标题（始终显示）
            SectionHeader(
                title: "git.changes".localized,
                count: unstagedCount,
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
                    .disabled(!hasUnstagedChanges || isStageAllInFlight)

                    Button(action: { showDiscardAllConfirm = true }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("git.discardAll".localized)
                    .disabled(!hasTrackedChanges && !hasUntrackedChanges)
                }
            }

            // 展开时显示文件列表（可滚动）
            if isExpanded {
                ScrollView {
                    VStack(spacing: 0) {
                        if let ws = appState.selectedWorkspaceKey {
                            if let cache = gitCache.getGitStatusCache(workspaceKey: ws) {
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
        }
    }

    private var unstagedCount: Int {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = gitCache.getGitStatusCache(workspaceKey: ws) else { return 0 }
        return cache.items.filter { $0.staged != true }.count
    }

    private var hasUnstagedChanges: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = gitCache.getGitStatusCache(workspaceKey: ws) else { return false }
        return cache.items.contains { $0.status == "??" || $0.status == "M" || $0.status == "A" || $0.status == "D" }
    }

    private var hasTrackedChanges: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = gitCache.getGitStatusCache(workspaceKey: ws) else { return false }
        return cache.items.contains { $0.staged != true && $0.status != "??" }
    }

    private var hasUntrackedChanges: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = gitCache.getGitStatusCache(workspaceKey: ws) else { return false }
        return cache.items.contains { $0.staged != true && $0.status == "??" }
    }

    private var isStageAllInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return gitCache.isGitOpInFlight(workspaceKey: ws, path: nil, op: "stage")
    }

    private func unstagedItems(_ items: [GitStatusItem]) -> [GitStatusItem] {
        items.filter { $0.staged != true }
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
