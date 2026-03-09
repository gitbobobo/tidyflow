import SwiftUI

/// iOS Git 面板：分支列表、变更管理与提交界面。
struct WorkspaceGitView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    @State private var projectionStore = GitWorkspaceProjectionStore()
    @State private var commitMessage: String = ""
    @State private var showBranchList: Bool = false
    @State private var showDiscardAllConfirm: Bool = false
    @State private var discardTargetPath: String? = nil
    @State private var showDiscardConfirm: Bool = false
    @State private var showConflictWizard: Bool = false

    private var gitState: MobileWorkspaceGitDetailState {
        appState.gitDetailStateForWorkspace(project: project, workspace: workspace)
    }

    private var snapshot: GitPanelSemanticSnapshot {
        gitState.semanticSnapshot
    }

    private var projection: GitWorkspaceProjection {
        let current = projectionStore.projection
        if current.workspaceReady {
            return current
        }
        return GitWorkspaceProjectionSemantics.make(
            workspaceKey: appState.globalWorkspaceKey(project: project, workspace: workspace),
            snapshot: snapshot,
            isStageAllInFlight: false
        )
    }

    /// 检测当前工作区或集成工作树是否有未解决冲突
    private var activeConflictContext: (workspace: String, context: String)? {
        let wsKey = "\(project):\(workspace)"
        if let wiz = appState.conflictWizardCache[wsKey], wiz.hasActiveConflicts {
            return (workspace, "workspace")
        }
        let intKey = "\(project):integration"
        if let wiz = appState.conflictWizardCache[intKey], wiz.hasActiveConflicts {
            return (workspace, "integration")
        }
        return nil
    }

    var body: some View {
        List {
            // MARK: - 冲突横幅（有冲突时优先展示）
            if activeConflictContext != nil {
                conflictBannerSection
            }

            // MARK: - 当前分支
            branchSection

            if !snapshot.isGitRepo {
                Section {
                    Text("当前目录不是 Git 仓库")
                        .foregroundColor(.secondary)
                }
            } else {
                // MARK: - 暂存区
                if projection.hasStagedChanges {
                    stagedSection
                }

                // MARK: - 工作区更改（已跟踪）
                if projection.hasTrackedChanges {
                    trackedUnstagedSection
                }

                // MARK: - 未跟踪文件
                if projection.hasUntrackedChanges {
                    untrackedSection
                }

                if projection.isEmpty && activeConflictContext == nil {
                    Section {
                        Label("工作区干净，无需提交", systemImage: "checkmark.circle")
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: - 提交输入
                if projection.hasStagedChanges {
                    commitSection
                }
            }
        }
        .navigationTitle("Git")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.fetchGitDetailForWorkspace(project: project, workspace: workspace)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showBranchList) {
            MobileBranchListSheet(
                project: project,
                workspace: workspace,
                isPresented: $showBranchList
            )
            .environmentObject(appState)
        }
        .confirmationDialog(
            "确认丢弃所有未暂存更改？此操作不可撤销。",
            isPresented: $showDiscardAllConfirm,
            titleVisibility: .visible
        ) {
            Button("丢弃所有更改", role: .destructive) {
                appState.gitDiscard(project: project, workspace: workspace, path: nil, scope: "all")
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "确认丢弃对 \(discardTargetPath ?? "") 的更改？",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("丢弃更改", role: .destructive) {
                if let path = discardTargetPath {
                    appState.gitDiscard(project: project, workspace: workspace, path: path, scope: "file")
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showConflictWizard) {
            if let (ws, ctx) = activeConflictContext {
                GitConflictWizardSheet(project: project, workspace: ws, context: ctx)
                    .environmentObject(appState)
            }
        }
        .onAppear {
            projectionStore.bind(appState: appState, project: project, workspace: workspace)
            appState.fetchGitDetailForWorkspace(project: project, workspace: workspace)
        }
        .refreshable {
            appState.fetchGitDetailForWorkspace(project: project, workspace: workspace)
        }
    }

    // MARK: - 冲突横幅区域

    private var conflictBannerSection: some View {
        Section {
            Button(action: { showConflictWizard = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("git.conflict.header".localized)
                            .font(.subheadline.bold())
                        if let (_, _) = activeConflictContext,
                           let count = activeConflictCount {
                            Text(String(format: "git.conflict.filesCount".localized, count))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.orange.opacity(0.08))
        } header: {
            Text("git.conflict.sectionHeader".localized)
        }
    }

    private var activeConflictCount: Int? {
        if let (ws, ctx) = activeConflictContext {
            let key = ctx == "integration" ? "\(project):integration" : "\(project):\(ws)"
            return appState.conflictWizardCache[key]?.conflictFileCount
        }
        return nil
    }

    // MARK: - 分支区域

    private var branchSection: some View {
        Section("分支") {
            Button {
                showBranchList = true
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(projection.currentBranchDisplay)
                            .foregroundColor(.primary)
                        Text(projection.branchDivergenceText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - 暂存区

    private var stagedSection: some View {
        Section {
            ForEach(projection.stagedItems) { item in
                GitFileRow(item: item, isStaged: true)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            appState.gitUnstage(project: project, workspace: workspace, path: item.path, scope: "file")
                        } label: {
                            Label("取消暂存", systemImage: "minus.circle")
                        }
                        .tint(.orange)
                    }
            }
        } header: {
            HStack {
                Text("已暂存更改 (\(projection.stagedCount))")
                Spacer()
                Button {
                    appState.gitUnstage(project: project, workspace: workspace, path: nil, scope: "all")
                } label: {
                    Image(systemName: "minus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 已跟踪的未暂存更改

    private var trackedUnstagedSection: some View {
        Section {
            ForEach(projection.trackedUnstagedItems) { item in
                GitFileRow(item: item, isStaged: false)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            appState.gitStage(project: project, workspace: workspace, path: item.path, scope: "file")
                        } label: {
                            Label("暂存", systemImage: "plus.circle")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            discardTargetPath = item.path
                            showDiscardConfirm = true
                        } label: {
                            Label("丢弃更改", systemImage: "arrow.uturn.backward")
                        }
                    }
            }
        } header: {
            HStack {
                Text("未暂存更改 (\(projection.trackedUnstagedCount))")
                Spacer()
                Button {
                    appState.gitStage(project: project, workspace: workspace, path: nil, scope: "all")
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button {
                    showDiscardAllConfirm = true
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 未跟踪文件

    private var untrackedSection: some View {
        Section {
            ForEach(projection.untrackedItems) { item in
                GitFileRow(item: item, isStaged: false)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            appState.gitStage(project: project, workspace: workspace, path: item.path, scope: "file")
                        } label: {
                            Label("暂存", systemImage: "plus.circle")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            discardTargetPath = item.path
                            showDiscardConfirm = true
                        } label: {
                            Label("删除文件", systemImage: "trash")
                        }
                    }
            }
        } header: {
            Text("未跟踪文件 (\(projection.untrackedCount))")
        }
    }

    // MARK: - 提交

    private var commitSection: some View {
        Section("提交") {
            TextField("输入提交信息", text: $commitMessage, axis: .vertical)
                .lineLimit(3...6)

            Button {
                guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                appState.gitCommit(project: project, workspace: workspace, message: commitMessage)
                commitMessage = ""
            } label: {
                HStack {
                    if gitState.isCommitting {
                        ProgressView()
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: "checkmark.circle")
                    }
                    Text("提交到 \(projection.snapshot.currentBranch ?? "当前分支")")
                }
            }
            .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || gitState.isCommitting)

            if let result = gitState.commitResult, !result.isEmpty {
                Text(result)
                    .font(.caption)
                    .foregroundColor(result.contains("成功") ? .green : .red)
            }
        }
    }
}

// MARK: - 文件行视图

private struct GitFileRow: View {
    let item: GitStatusItem
    let isStaged: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(item.status)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(statusColor)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.path)
                    .font(.body)
                    .lineLimit(2)
                if let additions = item.additions, let deletions = item.deletions,
                   (additions > 0 || deletions > 0) {
                    HStack(spacing: 6) {
                        if additions > 0 {
                            Text("+\(additions)")
                                .foregroundColor(.green)
                        }
                        if deletions > 0 {
                            Text("-\(deletions)")
                                .foregroundColor(.red)
                        }
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch item.status {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        case "??": return .secondary
        case "R": return .blue
        default: return .secondary
        }
    }
}

// MARK: - 分支列表 Sheet

private struct MobileBranchListSheet: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String
    @Binding var isPresented: Bool

    @State private var newBranchName: String = ""
    @State private var showNewBranchInput: Bool = false

    private var gitState: MobileWorkspaceGitDetailState {
        appState.gitDetailStateForWorkspace(project: project, workspace: workspace)
    }

    var body: some View {
        NavigationStack {
            List {
                if showNewBranchInput {
                    Section("新建分支") {
                        HStack {
                            TextField("分支名", text: $newBranchName)
                            Button("创建") {
                                let name = newBranchName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                // 通过终端命令创建并切换分支（现有协议暂不支持直接切换，用 AI Commit 通道不适合，故只显示入口）
                                appState.gitStage(project: project, workspace: workspace, path: nil, scope: "all")
                                showNewBranchInput = false
                                newBranchName = ""
                            }
                            .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                Section("分支列表") {
                    ForEach(gitState.branches) { branch in
                        HStack {
                            Image(systemName: branch.name == gitState.currentBranch ? "checkmark.circle.fill" : "arrow.triangle.branch")
                                .foregroundColor(branch.name == gitState.currentBranch ? .accentColor : .secondary)
                            Text(branch.name)
                                .fontWeight(branch.name == gitState.currentBranch ? .semibold : .regular)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if branch.name != gitState.currentBranch {
                                // 通知系统切换分支（目前 iOS WSClient 支持 requestGitBranches 查询；
                                // 切换操作需通过终端执行 git checkout）
                                isPresented = false
                            }
                        }
                    }

                    if gitState.branches.isEmpty {
                        Text("加载中…")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("分支")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewBranchInput.toggle()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                appState.fetchGitDetailForWorkspace(project: project, workspace: workspace)
            }
        }
    }
}
