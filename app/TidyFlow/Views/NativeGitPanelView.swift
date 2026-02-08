import SwiftUI
import AppKit

// 已拆分：
// - FloatingPanelController.swift   浮动面板控制器
// - GitPanelSections.swift          可折叠区、暂存/更改区、文件状态行
// - GitGraphViews.swift             提交历史图、提交行、文件列表、辅助视图

// MARK: - VSCode 风格 Git 面板主视图

/// 按照 VSCode 源代码管理面板布局设计的 Git 面板
/// 布局：顶部固定（标题 + 提交区）→ 中间可滚动（暂存 + 更改）→ 底部固定（图形，可折叠）
struct NativeGitPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    @State private var showDiscardAllConfirm: Bool = false
    @State private var isStagedExpanded: Bool = true
    @State private var isChangesExpanded: Bool = true
    @State private var isGraphExpanded: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // ── 顶部固定区域 ──
            // 1. 顶部工具栏（源代码管理）
            GitPanelHeader()
                .environmentObject(appState)

            // 2. 提交消息输入框 + 提交按钮
            GitCommitInputSection()
                .environmentObject(appState)

            // ── 下方区域：各 Section 均分剩余空间 ──

            // 3. 暂存的更改
            if hasStagedChangesInWorkspace {
                Divider()
                GitStagedChangesSection(isExpanded: $isStagedExpanded)
                    .environmentObject(appState)
                    .modifier(EqualExpandModifier(isExpanded: isStagedExpanded))
            }

            // 4. 更改（未暂存）
            Divider()
            GitChangesSection(isExpanded: $isChangesExpanded, showDiscardAllConfirm: $showDiscardAllConfirm)
                .environmentObject(appState)
                .modifier(EqualExpandModifier(isExpanded: isChangesExpanded))

            // 5. 图形/提交历史
            Divider()
            GitGraphSection(isExpanded: $isGraphExpanded)
                .environmentObject(appState)
                .modifier(EqualExpandModifier(isExpanded: isGraphExpanded))

            // 兜底：全部折叠时把内容顶到上方
            Spacer(minLength: 0)
        }
        .onAppear {
            loadDataIfNeeded()
        }
        .onChange(of: appState.selectedWorkspaceKey) { _, _ in
            loadDataIfNeeded()
        }
        .confirmationDialog("git.discardAll.title".localized, isPresented: $showDiscardAllConfirm, titleVisibility: .visible) {
            if hasTrackedChangesInWorkspace {
                Button("git.discardAll.trackedOnly".localized, role: .destructive) {
                    discardAll(includeUntracked: false)
                }
            }
            if hasUntrackedChangesInWorkspace {
                Button("git.discardAll.includeUntracked".localized, role: .destructive) {
                    discardAll(includeUntracked: true)
                }
            }
            Button("common.cancel".localized, role: .cancel) { }
        } message: {
            Text("git.discardAll.message".localized)
        }
    }

    private func loadDataIfNeeded() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        
        // 加载 Git 状态
        if gitCache.shouldFetchGitStatus(workspaceKey: ws) {
            gitCache.fetchGitStatus(workspaceKey: ws)
        }
        
        // 加载分支信息
        if gitCache.getGitBranchCache(workspaceKey: ws) == nil {
            gitCache.fetchGitBranches(workspaceKey: ws)
        }
        
        // 加载 Git 日志
        if gitCache.shouldFetchGitLog(workspaceKey: ws) {
            gitCache.fetchGitLog(workspaceKey: ws)
        }
    }

    private func discardAll(includeUntracked: Bool) {
        guard let ws = appState.selectedWorkspaceKey else { return }
        gitCache.gitDiscard(workspaceKey: ws, path: nil, scope: "all", includeUntracked: includeUntracked)
    }

    /// 当前工作区是否存在已跟踪文件的更改
    private var hasTrackedChangesInWorkspace: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = gitCache.getGitStatusCache(workspaceKey: ws) else { return false }
        return cache.items.contains { $0.staged != true && $0.status != "??" }
    }

    /// 当前工作区是否存在未跟踪文件
    private var hasUntrackedChangesInWorkspace: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = gitCache.getGitStatusCache(workspaceKey: ws) else { return false }
        return cache.items.contains { $0.staged != true && $0.status == "??" }
    }

    /// 当前工作区是否存在暂存的更改（用于决定是否显示「暂存的更改」顶层区）
    private var hasStagedChangesInWorkspace: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = gitCache.getGitStatusCache(workspaceKey: ws) else { return false }
        return cache.hasStagedChanges
    }
}

// MARK: - 均分展开修饰符

/// 展开时占据均分空间（`.frame(maxHeight: .infinity)`），折叠时仅保留自然高度
/// `layoutPriority(1)` 确保展开区域优先于底部 Spacer 获取空间
private struct EqualExpandModifier: ViewModifier {
    let isExpanded: Bool

    func body(content: Content) -> some View {
        if isExpanded {
            content
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
        } else {
            content
        }
    }
}

// MARK: - 顶部工具栏（使用与文件树一致的 PanelHeaderView）

struct GitPanelHeader: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                title: "git.sourceControl".localized,
                onRefresh: refreshAll,
                isRefreshDisabled: isLoading
            )

            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Text(branchDivergenceText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var isLoading: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return gitCache.getGitStatusCache(workspaceKey: ws)?.isLoading == true
    }

    private func refreshAll() {
        gitCache.refreshGitStatus()
        gitCache.refreshGitLog()
    }

    private var branchDivergenceText: String {
        guard let ws = appState.selectedWorkspaceKey else {
            return "git.branchDivergence.unavailable".localized
        }
        guard let cache = gitCache.getGitStatusCache(workspaceKey: ws) else {
            return "git.branchDivergence.unavailable".localized
        }

        if let base = cache.defaultBranch,
           let ahead = cache.aheadBy,
           let behind = cache.behindBy {
            let branchPair = String(format: "git.branchDivergence.currentVs".localized, base)
            if ahead == 0 && behind == 0 {
                return "\(branchPair) | \("git.branchDivergence.upToDate".localized)"
            }
            let aheadText = String(format: "git.branchDivergence.aheadCount".localized, ahead)
            let behindText = String(format: "git.branchDivergence.behindCount".localized, behind)
            return "\(branchPair) | \(aheadText) | \(behindText)"
        }

        if cache.isLoading {
            return "common.loading".localized
        }

        return "git.branchDivergence.unavailable".localized
    }
}

// MARK: - 提交消息输入区域

struct GitCommitInputSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
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
                return gitCache.commitMessage[ws] ?? ""
            },
            set: { newValue in
                guard let ws = appState.selectedWorkspaceKey else { return }
                gitCache.commitMessage[ws] = newValue
            }
        )
    }

    private var currentMessage: String {
        guard let ws = appState.selectedWorkspaceKey else { return "" }
        return gitCache.commitMessage[ws] ?? ""
    }

    private var hasStagedChanges: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return gitCache.hasStagedChanges(workspaceKey: ws)
    }

    private var isCommitInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return gitCache.isCommitInFlight(workspaceKey: ws)
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
        gitCache.gitCommit(workspaceKey: ws, message: currentMessage)
    }
}

// MARK: - AI 智能提交结果弹窗

struct AICommitResultSheet: View {
    let result: AICommitResult
    @Environment(\.dismiss) private var dismiss
    @State private var showRawOutput = false

    var body: some View {
        VStack(spacing: 16) {
            // 标题栏
            HStack {
                Text("git.aiCommit.result".localized)
                    .font(.headline)
                Spacer()
                Button("common.close".localized) { dismiss() }
            }
            .padding(.horizontal)
            .padding(.top)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 成功/失败/未知状态
                    HStack(spacing: 8) {
                        Image(systemName: result.resultStatus.iconName)
                            .font(.system(size: 24))
                            .foregroundColor(result.resultStatus.iconColor)
                        Text(result.resultStatus.commitDisplayText)
                            .font(.system(size: 16, weight: .semibold))
                    }

                    // 消息
                    if !result.message.isEmpty {
                        Text(result.message)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }

                    // 提交数量
                    if !result.commits.isEmpty {
                        Text(String(format: "git.aiCommit.commitCount".localized, result.commits.count))
                            .font(.system(size: 13, weight: .medium))
                    }

                    // 提交列表
                    ForEach(result.commits) { commit in
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(commit.sha)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.accentColor)
                                Text(commit.message)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(2)
                            }
                            ForEach(commit.files, id: \.self) { file in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Text(file)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.leading, 8)
                            }
                        }
                    }

                    // 原始输出（可折叠）
                    if !result.rawOutput.isEmpty {
                        Divider()
                        DisclosureGroup(
                            isExpanded: $showRawOutput,
                            content: {
                                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                                    Text(result.rawOutput)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 200)
                                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                                .cornerRadius(4)
                            },
                            label: {
                                Text("sidebar.aiMerge.rawOutput".localized)
                                    .font(.system(size: 13, weight: .medium))
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .frame(width: 500, height: 450)
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
