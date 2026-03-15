import SwiftUI

/// iOS Git 面板：分支列表、变更管理与提交界面。
struct WorkspaceGitView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    @State private var projectionStore = GitWorkspaceProjectionStore()
    @StateObject private var perfFixtureRunner = GitPanelPerfFixtureRunner()
    @State private var commitMessage: String = ""
    @State private var showBranchList: Bool = false
    @State private var showDiscardAllConfirm: Bool = false
    @State private var discardTargetPath: String? = nil
    @State private var showDiscardConfirm: Bool = false
    @State private var showConflictWizard: Bool = false
    @State private var showStashDetail: Bool = false
    @State private var showStashSaveForm: Bool = false
    @State private var stashSaveMessage: String = ""
    @State private var stashIncludeUntracked: Bool = false
    @State private var stashKeepIndex: Bool = false

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
            isStageAllInFlight: false,
            hasResolvedStatus: true
        )
    }

    private var perfFixtureScenario: GitPanelPerfFixtureScenario? {
        GitPanelPerfFixtureScenario.current()
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
                // MARK: - Stash
                stashSection

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
        .sheet(isPresented: $showStashDetail) {
            MobileStashDetailSheet(
                project: project,
                workspace: workspace,
                isPresented: $showStashDetail
            )
            .environmentObject(appState)
        }
        .onAppear {
            projectionStore.bind(appState: appState, project: project, workspace: workspace)
            appState.fetchGitDetailForWorkspace(project: project, workspace: workspace)
            appState.fetchStashList(project: project, workspace: workspace)
        }
        .onDisappear {
            perfFixtureRunner.cancel()
        }
        .refreshable {
            appState.fetchGitDetailForWorkspace(project: project, workspace: workspace)
            appState.fetchStashList(project: project, workspace: workspace)
        }
        .accessibilityIdentifier("tf.ios.git.panel")
        .overlay(alignment: .topLeading) {
            if perfFixtureScenario != nil {
                ZStack(alignment: .topLeading) {
                    Text("fixture \(perfFixtureRunner.statusText)")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .accessibilityIdentifier("tf.perf.git.status")
                    if perfFixtureRunner.isCompleted {
                        Text("fixture completed")
                            .font(.caption2)
                            .opacity(0.01)
                            .accessibilityIdentifier("tf.perf.git.completed")
                    }
                }
                .padding(12)
            }
        }
        .task(id: perfFixtureScenario?.id) {
            guard perfFixtureScenario != nil else { return }
            perfFixtureRunner.run(perfReporter: appState.perfReporter)
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
                NavigationLink(value: MobileRoute.workspaceDiff(
                    project: project, workspace: workspace,
                    path: item.path, mode: "staged"
                )) {
                    GitFileRow(item: item, isStaged: true)
                }
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
                NavigationLink(value: MobileRoute.workspaceDiff(
                    project: project, workspace: workspace,
                    path: item.path, mode: "working"
                )) {
                    GitFileRow(item: item, isStaged: false)
                }
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
                    if appState.workspaceGitState[appState.globalWorkspaceKey(project: project, workspace: workspace)]?.commitInFlight == true {
                        ProgressView()
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: "checkmark.circle")
                    }
                    Text("提交到 \(projection.snapshot.currentBranch ?? "当前分支")")
                }
            }
            .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.workspaceGitState[appState.globalWorkspaceKey(project: project, workspace: workspace)]?.commitInFlight == true)

            if let result = appState.workspaceGitState[appState.globalWorkspaceKey(project: project, workspace: workspace)]?.commitResult, !result.isEmpty {
                Text(result)
                    .font(.caption)
                    .foregroundColor(result.contains("成功") ? .green : .red)
            }
        }
    }

    // MARK: - Stash 区域

    private var stashSection: some View {
        let stashList = appState.getStashListCache(project: project, workspace: workspace)
        let cacheKey = appState.stashCacheKey(project: project, workspace: workspace)
        let isOpInFlight = appState.stashOpInFlight[cacheKey] ?? false

        return Section {
            if stashList.isLoading && stashList.entries.isEmpty {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("加载中…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if stashList.entries.isEmpty {
                HStack {
                    Image(systemName: "tray")
                        .foregroundColor(.secondary)
                    Text("没有 stash 记录")
                        .foregroundColor(.secondary)
                }

                Button {
                    showStashSaveForm = true
                } label: {
                    Label("保存当前更改为 Stash", systemImage: "square.and.arrow.down")
                }
            } else {
                // 最新 stash 条目摘要
                ForEach(stashList.entries.prefix(3)) { entry in
                    Button {
                        appState.selectedStashId[cacheKey] = entry.stashId
                        appState.fetchStashShow(project: project, workspace: workspace, stashId: entry.stashId)
                        showStashDetail = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message.isEmpty ? entry.title : entry.message)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(entry.branchName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if entry.fileCount > 0 {
                                        Text("· \(entry.fileCount) 个文件")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if stashList.entries.count > 3 {
                    Button {
                        if let first = stashList.entries.first {
                            appState.selectedStashId[cacheKey] = first.stashId
                            appState.fetchStashShow(project: project, workspace: workspace, stashId: first.stashId)
                        }
                        showStashDetail = true
                    } label: {
                        Text("查看全部 \(stashList.entries.count) 条 Stash")
                            .font(.caption)
                    }
                }
            }

            // 错误提示
            if let error = appState.stashLastError[cacheKey] {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if isOpInFlight {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("操作进行中…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            HStack {
                Text("Stashes (\(stashList.entries.count))")
                Spacer()
                Button {
                    showStashSaveForm = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showStashSaveForm) {
            MobileStashSaveSheet(
                project: project,
                workspace: workspace,
                isPresented: $showStashSaveForm
            )
            .environmentObject(appState)
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

    private var sharedState: GitWorkspaceState {
        appState.workspaceGitState[appState.globalWorkspaceKey(project: project, workspace: workspace)] ?? .empty
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
                                appState.gitCreateBranch(project: project, workspace: workspace, branch: name)
                                showNewBranchInput = false
                                newBranchName = ""
                            }
                            .disabled(
                                newBranchName.trimmingCharacters(in: .whitespaces).isEmpty
                                || sharedState.isBranchCreateInFlight
                            )

                            if sharedState.isBranchCreateInFlight {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
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
                            if sharedState.branchSwitchInFlight == branch.name {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if branch.name != gitState.currentBranch && sharedState.canSwitchBranch {
                                appState.gitSwitchBranch(project: project, workspace: workspace, branch: branch.name)
                            }
                        }
                        .opacity(sharedState.isBranchSwitchInFlight && sharedState.branchSwitchInFlight != branch.name ? 0.5 : 1.0)
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
            // 分支切换/创建成功后自动关闭
            .onChange(of: sharedState.branchCache.current) { _, _ in
                if !sharedState.isBranchSwitchInFlight && !sharedState.isBranchCreateInFlight {
                    isPresented = false
                }
            }
        }
    }
}

// MARK: - Stash 保存 Sheet

private struct MobileStashSaveSheet: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String
    @Binding var isPresented: Bool

    @State private var message: String = ""
    @State private var includeUntracked: Bool = false
    @State private var keepIndex: Bool = false

    private var isOpInFlight: Bool {
        let key = appState.stashCacheKey(project: project, workspace: workspace)
        return appState.stashOpInFlight[key] ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Stash 信息") {
                    TextField("备注（可选）", text: $message, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("选项") {
                    Toggle("包含未跟踪文件", isOn: $includeUntracked)
                    Toggle("保留已暂存内容", isOn: $keepIndex)
                }

                Section {
                    Button {
                        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        appState.stashSave(
                            project: project,
                            workspace: workspace,
                            message: msg.isEmpty ? nil : msg,
                            includeUntracked: includeUntracked,
                            keepIndex: keepIndex
                        )
                        isPresented = false
                    } label: {
                        HStack {
                            if isOpInFlight {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text("保存 Stash")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isOpInFlight)
                }
            }
            .navigationTitle("保存 Stash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
            }
        }
    }
}

// MARK: - Stash 详情 Sheet

private struct MobileStashDetailSheet: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String
    @Binding var isPresented: Bool

    @State private var selectedFilesForRestore: Set<String> = []
    @State private var showConflictWizard: Bool = false

    private var cacheKey: String {
        appState.stashCacheKey(project: project, workspace: workspace)
    }

    private var stashList: GitStashListCache {
        appState.getStashListCache(project: project, workspace: workspace)
    }

    private var selectedId: String? {
        appState.selectedStashId[cacheKey]
    }

    private var isOpInFlight: Bool {
        appState.stashOpInFlight[cacheKey] ?? false
    }

    var body: some View {
        NavigationStack {
            List {
                // Stash 列表
                Section("Stash 列表") {
                    ForEach(stashList.entries) { entry in
                        Button {
                            appState.selectedStashId[cacheKey] = entry.stashId
                            appState.fetchStashShow(project: project, workspace: workspace, stashId: entry.stashId)
                        } label: {
                            HStack {
                                Image(systemName: entry.stashId == selectedId ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(entry.stashId == selectedId ? .accentColor : .secondary)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.message.isEmpty ? entry.title : entry.message)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(entry.branchName)
                                        if entry.fileCount > 0 {
                                            Text("· \(entry.fileCount) 个文件")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                // 选中 stash 的详情
                if let stashId = selectedId {
                    let showCache = appState.getStashShowCache(project: project, workspace: workspace, stashId: stashId)

                    if showCache.isLoading && showCache.entry == nil {
                        Section {
                            HStack {
                                ProgressView()
                                Text("加载详情…")
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else if let entry = showCache.entry {
                        // 元数据
                        Section("详情") {
                            LabeledContent("分支", value: entry.branchName)
                            LabeledContent("文件数", value: "\(showCache.files.count)")
                            if !entry.message.isEmpty {
                                LabeledContent("备注", value: entry.message)
                            }
                        }

                        // 操作按钮
                        Section("操作") {
                            Button {
                                appState.stashApply(project: project, workspace: workspace, stashId: stashId)
                            } label: {
                                Label("Apply（保留 Stash）", systemImage: "arrow.uturn.backward")
                            }
                            .disabled(isOpInFlight)

                            Button {
                                appState.stashPop(project: project, workspace: workspace, stashId: stashId)
                            } label: {
                                Label("Pop（恢复并删除 Stash）", systemImage: "arrow.uturn.backward.circle")
                            }
                            .disabled(isOpInFlight)

                            Button(role: .destructive) {
                                appState.stashDrop(project: project, workspace: workspace, stashId: stashId)
                            } label: {
                                Label("Drop（删除 Stash）", systemImage: "trash")
                            }
                            .disabled(isOpInFlight)

                            if isOpInFlight {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("操作进行中…")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        // 文件列表（支持按文件恢复）
                        Section("文件列表") {
                            ForEach(showCache.files) { file in
                                Button {
                                    if selectedFilesForRestore.contains(file.path) {
                                        selectedFilesForRestore.remove(file.path)
                                    } else {
                                        selectedFilesForRestore.insert(file.path)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: selectedFilesForRestore.contains(file.path) ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(selectedFilesForRestore.contains(file.path) ? .accentColor : .secondary)
                                            .font(.caption)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.path)
                                                .font(.body)
                                                .foregroundColor(.primary)
                                                .lineLimit(2)
                                            HStack(spacing: 6) {
                                                Text(file.status)
                                                    .font(.caption2.monospaced())
                                                    .foregroundColor(fileStatusColor(file.status))
                                                if file.sourceKind == "untracked" {
                                                    Text("未跟踪")
                                                        .font(.caption2)
                                                        .foregroundColor(.gray)
                                                }
                                                if file.additions > 0 {
                                                    Text("+\(file.additions)")
                                                        .font(.caption2)
                                                        .foregroundColor(.green)
                                                }
                                                if file.deletions > 0 {
                                                    Text("-\(file.deletions)")
                                                        .font(.caption2)
                                                        .foregroundColor(.red)
                                                }
                                            }
                                        }
                                        Spacer()
                                    }
                                }
                            }

                            if !selectedFilesForRestore.isEmpty {
                                Button {
                                    appState.stashRestorePaths(
                                        project: project,
                                        workspace: workspace,
                                        stashId: stashId,
                                        paths: Array(selectedFilesForRestore)
                                    )
                                    selectedFilesForRestore.removeAll()
                                } label: {
                                    Label("恢复选中文件（\(selectedFilesForRestore.count) 个）", systemImage: "arrow.uturn.backward.square")
                                }
                                .disabled(isOpInFlight)
                            }
                        }

                        // Diff 预览
                        if !showCache.diffText.isEmpty {
                            Section("Diff 预览") {
                                ScrollView(.horizontal) {
                                    Text(showCache.diffText)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }

                // 错误提示
                if let error = appState.stashLastError[cacheKey] {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text(error)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Stash 管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
            }
            .sheet(isPresented: $showConflictWizard) {
                if let (ws, ctx) = conflictContext {
                    GitConflictWizardSheet(project: project, workspace: ws, context: ctx)
                        .environmentObject(appState)
                }
            }
            .onChange(of: appState.conflictWizardCache) { _, newValue in
                // stash 恢复导致冲突时，自动弹出冲突向导
                let wsKey = "\(project):\(workspace)"
                if let wiz = newValue[wsKey], wiz.hasActiveConflicts {
                    showConflictWizard = true
                }
            }
        }
    }

    private var conflictContext: (workspace: String, context: String)? {
        let wsKey = "\(project):\(workspace)"
        if let wiz = appState.conflictWizardCache[wsKey], wiz.hasActiveConflicts {
            return (workspace, "workspace")
        }
        return nil
    }

    private func fileStatusColor(_ status: String) -> Color {
        switch status {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        default: return .secondary
        }
    }
}
