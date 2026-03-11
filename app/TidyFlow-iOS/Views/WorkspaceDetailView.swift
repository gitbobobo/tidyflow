import SwiftUI
import ImageIO
import CoreGraphics

/// 工作空间详情页：终端、后台任务、代码变更汇总与工具栏操作。
struct WorkspaceDetailView: View {
    let appState: MobileAppState
    let project: String
    let workspace: String
    @State private var projectionStore = WorkspaceOverviewProjectionStore()

    var body: some View {
        let _ = Self.debugPrintChangesIfNeeded()
        let projection = projectionStore.projection
        List {
            // 冲突提示行（有冲突时在代码变更区顶部展示）
            if projection.hasActiveConflicts {
                Section {
                    NavigationLink(value: MobileRoute.workspaceGit(project: project, workspace: workspace)) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("git.conflict.header".localized)
                                .font(.subheadline.bold())
                                .foregroundColor(.orange)
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(Color.orange.opacity(0.08))
                }
            }

            Section("代码变更") {
                NavigationLink(value: MobileRoute.workspaceGit(project: project, workspace: workspace)) {
                    HStack(spacing: 16) {
                        Label("+\(projection.gitSnapshot.totalAdditions)", systemImage: "plus")
                            .foregroundColor(.green)
                        Label("-\(projection.gitSnapshot.totalDeletions)", systemImage: "minus")
                            .foregroundColor(.red)
                        Spacer()
                        if let branch = projection.gitSnapshot.defaultBranch, !branch.isEmpty {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.headline)
                    .padding(.vertical, 4)
                }
            }

            Section("资源管理器") {
                NavigationLink(value: MobileRoute.workspaceExplorer(project: project, workspace: workspace)) {
                    Label("浏览项目文件", systemImage: "folder")
                }
                Text("iOS 暂不支持外部改动冲突的重载/覆盖/比较三路处理，请在 macOS 端完成。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section("活跃终端") {
                if projection.terminals.isEmpty {
                    Text("暂无活跃终端")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(projection.terminals) { terminal in
                        NavigationLink(value: MobileRoute.terminalAttach(
                            project: project,
                            workspace: workspace,
                            termId: terminal.termId
                        )) {
                            HStack(spacing: 10) {
                                MobileCommandIconView(
                                    iconName: terminal.iconName,
                                    size: 18
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(terminal.title)
                                        .font(.body)
                                    Text(terminal.shortId)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if terminal.isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if terminal.aiStatus.isVisible {
                                    Spacer()
                                    Image(systemName: terminal.aiStatus.iconName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(terminal.aiStatus.color)
                                        .accessibilityLabel(terminal.aiStatus.hint)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .contextMenu {
                            Button(appState.isTerminalPinned(termId: terminal.termId) ? "取消固定" : "固定") {
                                appState.toggleTerminalPinned(termId: terminal.termId)
                            }
                            Divider()
                            Button("关闭其他") {
                                appState.closeOtherTerminals(
                                    project: project,
                                    workspace: workspace,
                                    keepTermId: terminal.termId
                                )
                            }
                            Button("关闭右侧") {
                                appState.closeTerminalsToRight(
                                    project: project,
                                    workspace: workspace,
                                    termId: terminal.termId
                                )
                            }
                            .disabled(!terminal.hasTerminalsToRight)
                            Divider()
                            Button(role: .destructive) {
                                appState.closeTerminal(termId: terminal.termId)
                            } label: {
                                Label("终止", systemImage: "xmark.circle")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.closeTerminal(termId: terminal.termId)
                            } label: {
                                Label("终止", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }

            Section("后台任务") {
                // 失败任务（高亮红色背景 + 诊断摘要 + 重试入口）
                let wsKey = "\(project):\(workspace)"
                let failedTasks = appState.taskStore.runStatusGroup(for: wsKey)?.failedTasks ?? []
                if !failedTasks.isEmpty {
                    ForEach(failedTasks) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                MobileCommandIconView(iconName: task.iconName, size: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                        .font(.body)
                                    HStack(spacing: 6) {
                                        Text("失败")
                                            .font(.caption2)
                                            .foregroundColor(.red)
                                        if !task.durationText.isEmpty {
                                            Text(task.durationText)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .fontDesign(.monospaced)
                                        }
                                    }
                                }
                                Spacer()
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                            }
                            if let summary = task.failureSummary {
                                Text(summary)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .lineLimit(2)
                                    .padding(.leading, 26)
                            }
                            if let descriptor = task.retryDescriptor {
                                HStack {
                                    Spacer()
                                    Button {
                                        appState.retryTask(descriptor: descriptor)
                                    } label: {
                                        Label("重试", systemImage: "arrow.clockwise")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.orange)
                                }
                                .padding(.leading, 26)
                            }
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(Color.red.opacity(0.04))
                    }
                }

                // 运行中任务
                if projection.runningTasks.isEmpty && failedTasks.isEmpty {
                    Text("当前无进行中的后台任务")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(projection.runningTasks) { task in
                        HStack(spacing: 10) {
                            MobileCommandIconView(iconName: task.iconName, size: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                Text(task.message)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if task.canCancel {
                                Button {
                                    if let source = appState.runningTasksForWorkspace(project: project, workspace: workspace)
                                        .first(where: { $0.id == task.id }) {
                                        appState.cancelTask(source)
                                    }
                                } label: {
                                    Image(systemName: "stop.circle")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            ProgressView()
                                .scaleEffect(0.9)
                        }
                        .padding(.vertical, 2)
                    }
                }

                NavigationLink(value: MobileRoute.workspaceTasks(project: project, workspace: workspace)) {
                    HStack {
                        Text("查看全部任务")
                        Spacer()
                        // 失败计数红色标记
                        if !failedTasks.isEmpty {
                            Text("\(failedTasks.count)")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .clipShape(Capsule())
                        }
                        if projection.completedTaskCount > 0 {
                            Text("\(projection.completedTaskCount)")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.secondary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Section("待办事项") {
                NavigationLink(value: MobileRoute.workspaceTodos(project: project, workspace: workspace)) {
                    HStack {
                        Text("查看待办")
                        Spacer()
                        if projection.pendingTodoCount > 0 {
                            Text("\(projection.pendingTodoCount)")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            // v1.42: 可观测性诊断入口（消费与 macOS 同一套共享观测状态）
            Section("系统诊断") {
                let perf = appState.observabilitySnapshot.perfMetrics
                let logCtx = appState.observabilitySnapshot.logContext
                HStack {
                    Text("WS 延迟")
                        .font(.subheadline)
                    Spacer()
                    Text("decode \(perf.wsDecode.lastMs)ms · dispatch \(perf.wsDispatch.lastMs)ms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("终端回收")
                        .font(.subheadline)
                    Spacer()
                    Text("reclaimed \(perf.terminalReclaimedTotal) · trimmed \(perf.terminalScrollbackTrimTotal)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Perf 日志")
                        .font(.subheadline)
                    Spacer()
                    Text(logCtx.perfLoggingEnabled ? "已启用" : "未启用")
                        .font(.caption)
                        .foregroundColor(logCtx.perfLoggingEnabled ? .green : .secondary)
                }
            }

            // v1.44: 预测与调度优化摘要（通过共享投影消费，不在 View 层推导规则）
            predictionSection
        }
        .navigationTitle(workspace)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("tf.ios.workspace.detail.\(workspace)")
        .tfHotspotBaseline(
            .iosWorkspaceDetail,
            renderProbeName: "WorkspaceDetailView",
            metadata: [
                "project": project,
                "workspace": workspace
            ]
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                evidenceButton
                evolutionButton
                aiChatButton
                moreActionsMenu
            }
        }
        .refreshable {
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
        .onAppear {
            projectionStore.bind(appState: appState, project: project, workspace: workspace)
            appState.selectWorkspaceContext(project: project, workspace: workspace)
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
    }

    // MARK: - v1.44 预测与调度优化

    /// 预测与调度优化摘要 Section。
    /// 通过 WorkspacePredictionProjectionSemantics 统一构建，不在 View 层推导业务规则。
    @ViewBuilder
    private var predictionSection: some View {
        let prediction = appState.predictionProjection(project: project, workspace: workspace)
        if prediction.hasSignals || prediction.healthScore != nil {
            Section("预测与调度") {
                if let score = prediction.healthScore {
                    HStack {
                        Text("健康评分")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.0f%%", score * 100))
                            .font(.caption)
                            .foregroundColor(predictionColor(prediction.pressureColorToken))
                    }
                }
                HStack {
                    Text("资源压力")
                        .font(.subheadline)
                    Spacer()
                    Text(prediction.pressureLabel)
                        .font(.caption)
                        .foregroundColor(predictionColor(prediction.pressureColorToken))
                }
                if prediction.schedulingRecommendationCount > 0 {
                    HStack {
                        Text("调度建议")
                            .font(.subheadline)
                        Spacer()
                        Text("\(prediction.schedulingRecommendationCount) 项")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if let summary = prediction.topRecommendationSummary {
                        Text(summary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                if prediction.predictiveAnomalyCount > 0 {
                    HStack {
                        Text("预测异常")
                            .font(.subheadline)
                        Spacer()
                        Text("\(prediction.predictiveAnomalyCount) 项")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    if let summary = prediction.topAnomalySummary {
                        Text(summary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func predictionColor(_ token: String) -> Color {
        switch token {
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        default: return .secondary
        }
    }

    private var evidenceButton: some View {
        Button {
            appState.navigationPath.append(MobileRoute.evidence(project: project, workspace: workspace))
        } label: {
            Image(systemName: "photo.stack")
        }
    }

    private var evolutionButton: some View {
        Button {
            appState.navigationPath.append(MobileRoute.evolution(project: project, workspace: workspace))
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
    }

    private var aiChatButton: some View {
        Button {
            appState.navigationPath.append(MobileRoute.aiChat(project: project, workspace: workspace))
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
        }
    }

    private var moreActionsMenu: some View {
        Menu {
            Menu("新建终端") {
                Button {
                    appState.navigationPath.append(MobileRoute.terminal(project: project, workspace: workspace))
                } label: {
                    Label("新建终端", systemImage: "terminal")
                }

                if !appState.customCommands.isEmpty {
                    Divider()
                    ForEach(appState.customCommands) { cmd in
                        Button {
                            appState.navigationPath.append(MobileRoute.terminal(
                                project: project,
                                workspace: workspace,
                                command: cmd.command,
                                commandIcon: cmd.icon,
                                commandName: cmd.name
                            ))
                        } label: {
                            Label {
                                Text(cmd.name)
                            } icon: {
                                MobileCommandIconView(iconName: cmd.icon, size: 14)
                            }
                        }
                    }
                }
            }

            Button {
                appState.navigationPath.append(MobileRoute.workspaceExplorer(project: project, workspace: workspace))
            } label: {
                Label("资源管理器", systemImage: "folder")
            }

            Button {
                appState.runAICommit(project: project, workspace: workspace)
            } label: {
                Label("一键提交", systemImage: "sparkles")
            }

            Button {
                appState.runAIMerge(project: project, workspace: workspace)
            } label: {
                Label("智能合并", systemImage: "cpu")
            }

            Menu("执行") {
                if projectionStore.projection.projectCommands.isEmpty {
                    Text("当前项目未配置命令")
                } else {
                    ForEach(projectionStore.projection.projectCommands) { command in
                        Button {
                            appState.runProjectCommand(project: project, workspace: workspace, command: command)
                        } label: {
                            Label {
                                Text(command.name)
                            } icon: {
                                MobileCommandIconView(iconName: command.icon, size: 14)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private static func debugPrintChangesIfNeeded() {
        SwiftUIPerformanceDebug.runPrintChangesIfEnabled(
            SwiftUIPerformanceDebug.workspaceDetailPrintChangesEnabled
        ) {
#if DEBUG
            Self._printChanges()
#endif
        }
    }
}

/// iOS 资源管理器（轻交互）：目录浏览 + 新建/重命名/删除 + 文本预览
struct WorkspaceExplorerView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    private var rootCache: FileListCache? {
        appState.explorerListCache(project: project, workspace: workspace, path: ".")
    }

    var body: some View {
        List {
            if let cache = rootCache {
                if cache.isLoading && cache.items.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("加载中...")
                            .foregroundColor(.secondary)
                    }
                } else if let error = cache.error, cache.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .foregroundColor(.secondary)
                        Button("重试") {
                            appState.fetchExplorerFileList(project: project, workspace: workspace, path: ".")
                        }
                    }
                } else if cache.items.isEmpty {
                    ContentUnavailableView("当前目录为空", systemImage: "folder")
                } else {
                    ForEach(cache.items) { item in
                        ExplorerFileRowView(
                            project: project,
                            workspace: workspace,
                            item: item,
                            depth: 0
                        )
                        .environmentObject(appState)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("加载中...")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("资源管理器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.refreshExplorer(project: project, workspace: workspace)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $appState.explorerPreviewPresented) {
            ExplorerFilePreviewSheet()
                .environmentObject(appState)
        }
        .onAppear {
            appState.prepareExplorer(project: project, workspace: workspace)
        }
    }
}

private struct ExplorerFileRowView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String
    let item: FileEntry
    let depth: Int

    @State private var showRenameDialog = false
    @State private var showDeleteConfirm = false
    @State private var showNewFileDialog = false
    @State private var newName = ""
    @State private var newFileName = ""

    private var isExpanded: Bool {
        appState.isExplorerDirectoryExpanded(project: project, workspace: workspace, path: item.path)
    }

    private var childrenCache: FileListCache? {
        appState.explorerListCache(project: project, workspace: workspace, path: item.path)
    }

    private var indent: CGFloat {
        CGFloat(depth) * 14
    }

    /// 通过共享语义解析器推导条目展示语义（与 macOS 保持行为一致）
    private var presentation: ExplorerItemPresentation {
        let gitIndex = appState.explorerGitStatusIndex(project: project, workspace: workspace)
        return ExplorerSemanticResolver.resolve(
            entry: item,
            gitIndex: gitIndex,
            isExpanded: isExpanded,
            isSelected: false
        )
    }

    var body: some View {
        let p = presentation
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if item.isDir {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }

                if p.hasSpecialIcon {
                    Group {
                        if item.name == "CLAUDE.md" {
                            Image("claude-icon")
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                        } else if item.name == "AGENTS.md" {
                            Image("agents-icon")
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                    .frame(width: 16, height: 16)
                } else {
                    Image(systemName: p.iconName)
                        .foregroundColor(p.iconColor)
                }
                Text(item.name)
                    .lineLimit(1)
                    .foregroundColor(p.titleColor)
                if let trailing = p.trailingIcon {
                    Image(systemName: trailing)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let gitStatus = p.gitStatus {
                    Text(gitStatus)
                        .font(.caption2)
                        .foregroundColor(p.gitStatusColor)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.leading, indent)
            .padding(.vertical, 6)
            .onTapGesture {
                if item.isDir {
                    appState.toggleExplorerDirectory(project: project, workspace: workspace, path: item.path)
                } else {
                    appState.readFileForPreview(project: project, workspace: workspace, path: item.path)
                }
            }
            .contextMenu {
                Button {
                    appState.copyExplorerPath(project: project, workspace: workspace, path: item.path)
                } label: {
                    Label("rightPanel.copyPath".localized, systemImage: "doc.on.doc")
                }

                Button {
                    appState.copyExplorerRelativePath(item.path)
                } label: {
                    Label("rightPanel.copyRelativePath".localized, systemImage: "arrow.turn.down.right")
                }

                Divider()

                if item.isDir {
                    Button {
                        newFileName = ""
                        showNewFileDialog = true
                    } label: {
                        Label("新建文件", systemImage: "doc.badge.plus")
                    }
                }

                Button {
                    newName = item.name
                    showRenameDialog = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .sheet(isPresented: $showNewFileDialog) {
                NewFileDialogView(
                    fileName: $newFileName,
                    onConfirm: {
                        let parentDir = item.path
                        appState.createExplorerFile(
                            project: project,
                            workspace: workspace,
                            parentDir: parentDir,
                            fileName: newFileName
                        )
                        showNewFileDialog = false
                    },
                    onCancel: {
                        showNewFileDialog = false
                    }
                )
            }
            .sheet(isPresented: $showRenameDialog) {
                RenameDialogView(
                    originalName: item.name,
                    newName: $newName,
                    isDir: item.isDir,
                    onConfirm: {
                        appState.renameExplorerFile(
                            project: project,
                            workspace: workspace,
                            path: item.path,
                            newName: newName
                        )
                        showRenameDialog = false
                    },
                    onCancel: {
                        showRenameDialog = false
                    }
                )
            }
            .confirmationDialog(
                "确认删除 \(item.name)？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    appState.deleteExplorerFile(project: project, workspace: workspace, path: item.path)
                }
                Button("取消", role: .cancel) {}
            }

            if item.isDir && isExpanded {
                if let childrenCache {
                    if childrenCache.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.85)
                            Text("加载中...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, indent + 26)
                        .padding(.vertical, 4)
                    } else if let error = childrenCache.error, childrenCache.items.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, indent + 26)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(childrenCache.items) { child in
                            ExplorerFileRowView(
                                project: project,
                                workspace: workspace,
                                item: child,
                                depth: depth + 1
                            )
                            .environmentObject(appState)
                        }
                    }
                }
            }
        }
        .tfRenderProbe("WorkspaceDetailView", metadata: [
            "project": project,
            "workspace": workspace
        ])
    }

    private static func debugPrintChangesIfNeeded() {
        SwiftUIPerformanceDebug.runPrintChangesIfEnabled(
            SwiftUIPerformanceDebug.workspaceDetailPrintChangesEnabled
        ) {
#if DEBUG
            Self._printChanges()
#endif
        }
    }
}

private struct ExplorerFilePreviewSheet: View {
    @EnvironmentObject var appState: MobileAppState

    var body: some View {
        NavigationStack {
            Group {
                if appState.explorerPreviewLoading {
                    ProgressView("正在读取文件...")
                } else if let error = appState.explorerPreviewError {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(error)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    ScrollView {
                        Text(appState.explorerPreviewContent)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .navigationTitle(appState.explorerPreviewPath ?? "文件预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        appState.explorerPreviewPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - Evidence Tab Types (iOS)
// MobileEvidenceTabType 已统一为 EvidenceTabType（定义于 TabContentHostView.swift），两端共享语义。

struct MobileEvidenceView: View {
    let appState: MobileAppState
    let project: String
    let workspace: String

    @State private var projectionStore = EvidenceProjectionStore()
    @State private var selectedTab: EvidenceTabType = .screenshot
    @State private var selectedScreenshotID: String?
    @State private var selectedLogID: String?
    @StateObject private var evidenceViewer = EvidenceViewerStore()
    @State private var itemImage: CGImage?
    @State private var headerHint: String?
    @State private var showingDetailSheet: Bool = false
    @State private var screenshotThumbnails: [String: CGImage] = [:]
    @State private var screenshotThumbnailLoadingIDs: Set<String> = []
    @State private var screenshotThumbnailLoadFailedIDs: Set<String> = []
    @State private var screenshotThumbnailPendingIDs: [String] = []
    @State private var screenshotThumbnailActiveID: String?
    @State private var screenshotThumbnailRequestSequence: UInt64 = 0

    private var projection: EvidenceProjection { projectionStore.projection }
    private var currentTabItems: [EvidenceItemProjection] { projection.currentTabItems }

    var body: some View {
        let _ = Self.debugPrintChangesIfNeeded()
        List {
            Section {
                Button("重建全链路证据") {
                    rebuildEvidence()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appState.isConnected)
                if let headerHint, !headerHint.isEmpty {
                    Text(headerHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                HStack(spacing: 0) {
                    ForEach(EvidenceTabType.allCases) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTab = tab
                            }
                            clearPreview()
                            projectionStore.refresh(
                                appState: appState,
                                project: project,
                                workspace: workspace,
                                selectedTab: tab
                            )
                            stopScreenshotThumbnailPrefetch()
                            processNextScreenshotThumbnailLoadIfNeeded()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: 12))
                                Text("\(tab.displayName)(\(projection.tabCount(for: tab)))")
                                    .font(.system(size: 12))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selectedTab == tab
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                            .contentShape(Rectangle())
                            .animation(.easeInOut(duration: 0.2), value: selectedTab)
                        }
                        .buttonStyle(.plain)

                        if tab != EvidenceTabType.allCases.last {
                            Divider()
                                .frame(height: 20)
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
            }

            if projection.snapshotLoading && !projection.snapshotAvailable {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("读取证据中...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let snapshotError = projection.snapshotError, !projection.snapshotAvailable {
                Section {
                    Text(snapshotError)
                        .foregroundColor(.red)
                    Button("重试") {
                        refreshEvidence()
                    }
                }
            } else if projection.currentTabItemCount == 0 {
                Section {
                    ContentUnavailableView(
                        selectedTab.emptyStateText,
                        systemImage: selectedTab.iconName
                    )
                }
            } else if projection.snapshotAvailable {
                ForEach(projection.deviceSections) { section in
                    deviceSection(section)
                }
            } else {
                Section {
                    Text("暂无证据数据")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("证据")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refreshEvidence()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showingDetailSheet) {
            detailSheet
        }
        .onAppear {
            projectionStore.bind(
                appState: appState,
                project: project,
                workspace: workspace,
                selectedTab: selectedTab
            )
            refreshEvidence()
            syncSelectionIfNeeded()
        }
        .onChange(of: projection.snapshotUpdatedAt) { _, _ in
            syncSelectionIfNeeded()
            pruneScreenshotThumbnailCache()
            processNextScreenshotThumbnailLoadIfNeeded()
        }
        .onChange(of: appState.isConnected) { _, connected in
            guard connected else { return }
            refreshEvidence()
        }
        .onChange(of: showingDetailSheet) { _, showing in
            if showing {
                stopScreenshotThumbnailPrefetch()
            } else {
                processNextScreenshotThumbnailLoadIfNeeded()
            }
        }
    }

    @ViewBuilder
    private func deviceSection(_ section: EvidenceDeviceSectionProjection) -> some View {
        if selectedTab == .screenshot {
            Section("\(section.deviceType) (\(section.items.count)张)") {
                screenshotGrid(items: section.items)
            }
        } else {
            Section(section.deviceType) {
                ForEach(section.items, id: \.itemID) { item in
                    logRow(item: item)
                }
            }
        }
    }

    private func screenshotGrid(items: [EvidenceItemProjection]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 12)
            ],
            spacing: 12
        ) {
            ForEach(items, id: \.itemID) { item in
                screenshotThumbnail(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func screenshotThumbnail(item: EvidenceItemProjection) -> some View {
        let thumbnailHeight: CGFloat = 64
        return Button {
            selectedScreenshotID = item.itemID
            showingDetailSheet = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    if let thumbnail = screenshotThumbnails[item.itemID] {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary.opacity(0.5))
                        if screenshotThumbnailLoadingIDs.contains(item.itemID) {
                            ProgressView()
                                .controlSize(.small)
                                .offset(y: 16)
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

                Text("#\(item.order)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            enqueueScreenshotThumbnailLoad(for: item)
        }
    }

    private func logRow(item: EvidenceItemProjection) -> some View {
        Button {
            selectedLogID = item.itemID
            showingDetailSheet = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("#\(item.order) \(item.title)")
                        .font(.body)
                        .foregroundColor(.primary)

                    if !item.description.isEmpty && item.description != item.title {
                        Text(item.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Text(item.path)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }

                Spacer()

                if item.sizeBytes > 0 {
                    Text(formatByteCount(item.sizeBytes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedLogID == item.itemID ? Color.accentColor.opacity(0.12) : Color.clear
        )
    }

    private func formatByteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var currentSelectedItem: EvidenceItemProjection? {
        let selectedID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        if let id = selectedID {
            return currentTabItems.first { $0.itemID == id }
        }
        return nil
    }

    private var detailSheet: some View {
        NavigationStack {
            Group {
                if let item = currentSelectedItem {
                    detailContent(for: item)
                } else {
                    ContentUnavailableView("无内容", systemImage: "doc")
                }
            }
            .navigationTitle(currentSelectedItem?.title ?? "详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        showingDetailSheet = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detailContent(for item: EvidenceItemProjection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.headline)
                    if !item.description.isEmpty {
                        Text(item.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text(item.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if item.sizeBytes > 0 {
                            Text(formatByteCount(item.sizeBytes))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(.rect(cornerRadius: 10))

                if evidenceViewer.isLoading {
                    ProgressView("加载内容中...")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let itemError = evidenceViewer.errorMessage {
                    ContentUnavailableView(
                        "加载失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(itemError)
                    )
                } else if let itemImage, selectedTab == .screenshot {
                    Image(decorative: itemImage, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: 10))
                } else if !evidenceViewer.textChunks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(evidenceViewer.textChunks) { chunk in
                            Text(chunk.text)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if evidenceViewer.isPaging || evidenceViewer.hasMoreText {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(evidenceViewer.isPaging ? "加载更多中..." : "滚动到底部继续加载")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                            .onAppear {
                                loadNextTextPageIfNeeded(for: item)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .clipShape(.rect(cornerRadius: 10))
                } else {
                    ContentUnavailableView(
                        "无法预览",
                        systemImage: "doc",
                        description: Text("该文件格式暂不支持预览")
                    )
                }
            }
            .padding()
        }
        .onAppear {
            loadItemIfNeeded(item)
        }
        .onChange(of: item.itemID) { _, _ in
            loadItem(item)
        }
    }

    private func loadItemIfNeeded(_ item: EvidenceItemProjection) {
        let currentID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        if currentID != item.itemID {
            if selectedTab == .screenshot {
                selectedScreenshotID = item.itemID
            } else {
                selectedLogID = item.itemID
            }
            loadItem(item)
        } else if evidenceViewer.textChunks.isEmpty && itemImage == nil && !evidenceViewer.isLoading && evidenceViewer.errorMessage == nil {
            loadItem(item)
        }
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
            clearPreview()
        }
    }

    private func clearPreview() {
        evidenceViewer.clear()
        itemImage = nil
    }

    private func stopScreenshotThumbnailPrefetch() {
        screenshotThumbnailPendingIDs.removeAll()
        screenshotThumbnailActiveID = nil
        screenshotThumbnailLoadingIDs.removeAll()
        screenshotThumbnailRequestSequence &+= 1
    }

    private func pruneScreenshotThumbnailCache() {
        guard projection.snapshotAvailable else {
            screenshotThumbnails.removeAll()
            screenshotThumbnailLoadFailedIDs.removeAll()
            stopScreenshotThumbnailPrefetch()
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
        selectedTab == .screenshot && !showingDetailSheet
    }

    private func enqueueScreenshotThumbnailLoad(for item: EvidenceItemProjection) {
        guard canPrefetchScreenshotThumbnails else { return }
        guard screenshotThumbnails[item.itemID] == nil else { return }
        guard !screenshotThumbnailLoadingIDs.contains(item.itemID) else { return }
        guard !screenshotThumbnailLoadFailedIDs.contains(item.itemID) else { return }
        guard !screenshotThumbnailPendingIDs.contains(item.itemID) else { return }
        guard item.isScreenshotLike else { return }
        screenshotThumbnailPendingIDs.append(item.itemID)
        processNextScreenshotThumbnailLoadIfNeeded()
    }

    private func processNextScreenshotThumbnailLoadIfNeeded() {
        guard canPrefetchScreenshotThumbnails else { return }
        guard screenshotThumbnailActiveID == nil else { return }

        while !screenshotThumbnailPendingIDs.isEmpty {
            let itemID = screenshotThumbnailPendingIDs.removeFirst()
            guard screenshotThumbnails[itemID] == nil else { continue }
            guard !screenshotThumbnailLoadFailedIDs.contains(itemID) else { continue }
            guard let item = currentTabItems.first(where: { $0.itemID == itemID }) else { continue }
            guard item.isScreenshotLike else { continue }

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
           let thumbnail = decodeImage(data: Data(payload.content), maxPixelSize: 480) {
            screenshotThumbnails[itemID] = thumbnail
        } else {
            screenshotThumbnailLoadFailedIDs.insert(itemID)
        }

        processNextScreenshotThumbnailLoadIfNeeded()
    }

    private func refreshEvidence() {
        appState.requestEvidenceSnapshot(project: project, workspace: workspace)
    }

    private func rebuildEvidence() {
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
                    headerHint = "已准备证据提示词，正在跳转聊天页..."
                    appState.navigationPath.append(MobileRoute.aiChat(project: project, workspace: workspace))
                } else {
                    let error = errorMessage ?? "未知错误"
                    headerHint = "生成失败：\(error)"
                }
            }
        }
    }

    private func loadItem(_ item: EvidenceItemProjection) {
        evidenceViewer.beginLoading(itemID: item.itemID)
        itemImage = nil

        if item.isScreenshotLike {
            appState.readEvidenceItem(project: project, workspace: workspace, itemID: item.itemID) { payload, errorMessage in
                DispatchQueue.main.async {
                    let currentID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
                    guard currentID == item.itemID else { return }
                    if let payload {
                        if let image = decodeImage(data: Data(payload.content)) {
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
                    guard !reset, payload != nil else { return nil }
                    return self.appState.performanceTracer.begin(TFPerformanceContext(
                        event: .evidencePageAppend,
                        project: self.project,
                        workspace: self.workspace,
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

    private func decodeImage(data: Data, maxPixelSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        if let maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return thumbnail
            }
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func debugPrintChangesIfNeeded() {
#if DEBUG
        guard SwiftUIPerformanceDebug.mobileEvidenceContainerPrintChangesEnabled else { return }
        Self._printChanges()
#endif
    }
}

private struct EvolutionProfileDraft: Identifiable {
    let id: String
    let stage: String
    var aiTool: AIChatTool
    var mode: String
    var providerID: String
    var modelID: String
    var configOptions: [String: Any]
}

struct MobileEvolutionView: View {
    let appState: MobileAppState
    let project: String
    let workspace: String

    @State private var projectionStore = EvolutionPipelineProjectionStore()
    @State private var optionsStore = EvolutionProfileOptionsProjectionStore()
    @State private var loopRoundLimitText: String = "1"
    @State private var profiles: [EvolutionProfileDraft] = []
    @State private var isApplyingRemoteProfiles: Bool = false
    @State private var lastSyncedProfileSignature: String = ""
    @State private var pendingProfileSaveSignature: String?
    @State private var pendingProfileSaveDate: Date?
    @State private var hasPendingUserProfileEdit: Bool = false
    @State private var blockerDrafts: [String: EvolutionBlockerDraft] = [:]
    @State private var isPlanDocumentSheetPresented: Bool = false
    @State private var selectedPlanDocumentCycleID: String?
    @State private var selectedCycleDetail: MobileCycleDetailPayload?

    private struct EvolutionBlockerDraft {
        var selected: Bool
        var selectedOptionID: String
        var answerText: String
    }

    private var projection: EvolutionPipelineProjection { projectionStore.projection }
    private var item: EvolutionWorkspaceItemV2? { projection.currentItem }
    private var scheduler: EvolutionSchedulerInfoV2 { projection.scheduler }
    private var controlState: EvolutionControlProjection { projection.control }
    private var activeBlockingRequest: EvolutionBlockingRequestProjection? { projection.blockingRequest }
    private var cycleHistories: [PipelineCycleHistory] { projection.cycleHistories }
    private var primaryControlShowsStop: Bool {
        controlState.canStop || controlState.isStopPending
    }
    private var canTriggerPrimaryControlAction: Bool {
        controlState.canStart || controlState.canStop
    }
    private var primaryControlButtonTitle: String {
        primaryControlShowsStop
            ? "evolution.page.action.stop".localized
            : "evolution.page.action.startManual".localized
    }
    private var primaryControlButtonSymbol: String {
        if primaryControlShowsStop {
            return controlState.isStopPending ? "clock" : "stop.fill"
        }
        return controlState.isStartPending ? "clock" : "play.fill"
    }
    private var primaryControlButtonTint: Color {
        primaryControlShowsStop ? .red : .green
    }
    var body: some View {
        List {
            Section("evolution.page.scheduler.section".localized) {
                LabeledContent("evolution.page.scheduler.activation".localized) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isSchedulerActive(scheduler.activationState) ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(localizedSchedulerActivationDisplay(scheduler.activationState))
                    }
                }
                LabeledContent("evolution.page.scheduler.maxParallel".localized) {
                    Text("\(scheduler.maxParallelWorkspaces)")
                }
                LabeledContent("evolution.page.scheduler.runningQueued".localized) {
                    Text("\(scheduler.runningCount) / \(scheduler.queuedCount)")
                }
            }

            Section("evolution.page.workspace.section".localized) {
                LabeledContent("evolution.page.workspace.currentWorkspace".localized) {
                    Text("\(project)/\(workspace)")
                }
                if let item {
                    LabeledContent("evolution.page.workspace.status".localized) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(mobileWorkspaceStatusColor(item.status))
                                .frame(width: 8, height: 8)
                            Text(localizedWorkspaceStatusDisplay(item.status))
                        }
                    }
                    LabeledContent("evolution.page.workspace.currentStage".localized) {
                        Text(stageDisplayName(item.currentStage))
                    }
                    LabeledContent("evolution.page.workspace.loopRound".localized) {
                        Text("\(item.globalLoopRound)/\(max(1, item.loopRoundLimit))")
                    }
                    LabeledContent("循环标题") {
                        Text(mobileCycleDisplayTitle(item.title))
                    }
                    LabeledContent("evolution.page.workspace.verifyRound".localized) {
                        Text("\(item.verifyIteration)/\(item.verifyIterationLimit)")
                    }
                    LabeledContent("evolution.page.workspace.activeAgents".localized) {
                        Text(
                            item.activeAgents.isEmpty
                                ? "evolution.page.workspace.noActiveAgents".localized
                                : item.activeAgents.joined(separator: ", ")
                        )
                            .lineLimit(1)
                    }
                    // 终止原因
                    if let reason = trimmedNonEmptyText(item.terminalReasonCode) {
                        LabeledContent("evolution.page.pipeline.terminalReason".localized) {
                            Text(mobileLocalizedTerminalReason(reason))
                                .foregroundColor(.red)
                                .lineLimit(2)
                        }
                    }
                    if let terminalError = trimmedNonEmptyText(item.terminalErrorMessage) {
                        LabeledContent("evolution.page.pipeline.terminalError".localized) {
                            Text(terminalError)
                                .foregroundColor(.red)
                                .lineLimit(4)
                                .font(.caption)
                        }
                    }
                    // 限流错误信息
                    if let rateLimitMsg = trimmedNonEmptyText(item.rateLimitErrorMessage) {
                        LabeledContent("evolution.page.pipeline.rateLimitError".localized) {
                            Text(rateLimitMsg)
                                .foregroundColor(.orange)
                                .lineLimit(3)
                                .font(.caption)
                        }
                    }
                } else {
                    Text("evolution.page.workspace.notStarted".localized)
                        .foregroundColor(.secondary)
                }

                LabeledContent("evolution.page.workspace.loopRoundInput".localized) {
                    HStack(spacing: 6) {
                        TextField("evolution.page.workspace.loopRoundInput".localized, text: $loopRoundLimitText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                            .disabled(!controlState.canStart)
                        // WI-004：运行中支持 +1/-1 快捷调整循环轮次
                        if controlState.canStop {
                            HStack(spacing: 4) {
                                Button {
                                    let current = Int(loopRoundLimitText) ?? 1
                                    let newVal = max(1, current - 1)
                                    loopRoundLimitText = "\(newVal)"
                                    appState.adjustEvolutionLoopRound(project: project, workspace: workspace, loopRoundLimit: newVal)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .disabled((Int(loopRoundLimitText) ?? 1) <= 1)

                                Button {
                                    let current = Int(loopRoundLimitText) ?? 1
                                    let newVal = current + 1
                                    loopRoundLimitText = "\(newVal)"
                                    appState.adjustEvolutionLoopRound(project: project, workspace: workspace, loopRoundLimit: newVal)
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Text("evolution.page.workspace.verifyLoopFixed".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
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
                        appState.resumeEvolution(project: project, workspace: workspace)
                    } label: {
                        if controlState.isResumePending {
                            Label("evolution.page.action.resume".localized, systemImage: "clock")
                        } else {
                            Label("evolution.page.action.resume".localized, systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!controlState.canResume)
                }

                Button {
                    if let item {
                        openPlanDocumentSheet(cycleID: item.cycleID)
                    }
                } label: {
                    Label("evolution.page.action.previewPlanDocument".localized, systemImage: "doc.text")
                }
                .disabled(item == nil)
            }

            Section("evolution.page.agentType.description.section".localized) {
                Text("evolution.page.agentType.description.text".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let blocking = activeBlockingRequest {
                Section("evolution.page.blocker.section".localized) {
                    Text("evolution.page.blocker.pendingHint".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "evolution.page.blocker.triggerOnly".localized, blocking.trigger))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(blocking.unresolvedItems, id: \.blockerID) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(item.title, isOn: bindingSelected(item.blockerID))
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
                            }
                            if item.allowCustomInput || item.options.isEmpty {
                                TextField("evolution.page.blocker.answerInput".localized, text: bindingAnswer(item.blockerID))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button("evolution.page.blocker.submitSelected".localized) {
                        submitBlockers(blocking)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if profiles.isEmpty {
                Section("evolution.page.agentType.section".localized) {
                    Text("evolution.page.agentType.empty".localized)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach($profiles) { $profile in
                    let stage = profile.stage
                    let runtime = runtimeAgent(for: stage)
                    let statusText = runtime?.status ?? "not_started"
                    let aiToolBinding = Binding<AIChatTool>(
                        get: { profile.aiTool },
                        set: { newValue in
                            guard profile.aiTool != newValue else { return }
                            hasPendingUserProfileEdit = true
                            profile.aiTool = newValue
                            profile.configOptions = [:]
                            sanitizeProfileSelection(profileID: profile.id)
                            autoSaveProfilesIfNeeded()
                        }
                    )
                    Section(sectionTitle(for: profile, runtime: runtime)) {
                        if canOpenStageSession(stage: stage) {
                            LabeledContent("evolution.page.agent.status".localized) {
                                Button {
                                    openCurrentStageSession(stage: stage)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(localizedStageStatusDisplay(statusText))
                                            .foregroundColor(stageStatusColor(statusText))
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            LabeledContent("evolution.page.agent.status".localized) {
                                Text(localizedStageStatusDisplay(statusText))
                                    .foregroundColor(stageStatusColor(statusText))
                            }
                        }

                        LabeledContent("settings.evolution.aiTool".localized) {
                            Picker("", selection: aiToolBinding) {
                                ForEach(AIChatTool.allCases) { tool in
                                    Text(tool.displayName).tag(tool)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        LabeledContent("settings.evolution.mode".localized) {
                            Menu {
                                Button("settings.evolution.defaultMode".localized) {
                                    hasPendingUserProfileEdit = true
                                    profile.mode = ""
                                    autoSaveProfilesIfNeeded()
                                }
                                let options = modeOptions(for: profile.aiTool)
                                if options.isEmpty {
                                    Text("settings.evolution.noModes".localized)
                                } else {
                                    ForEach(options, id: \.self) { mode in
                                        Button(mode) {
                                            hasPendingUserProfileEdit = true
                                            profile.mode = mode
                                            applyAgentDefaultModelIfAvailable(
                                                profileID: profile.id,
                                                agentName: mode
                                            )
                                            autoSaveProfilesIfNeeded()
                                        }
                                    }
                                }
                            } label: {
                                Text(profile.mode.isEmpty ? "settings.evolution.defaultMode".localized : profile.mode)
                                    .foregroundColor(.secondary)
                            }
                        }

                        LabeledContent("settings.evolution.model".localized) {
                            Menu {
                                Button("settings.evolution.defaultModel".localized) {
                                    hasPendingUserProfileEdit = true
                                    profile.providerID = ""
                                    profile.modelID = ""
                                    sanitizeModelVariantSelection(profile: &profile)
                                    autoSaveProfilesIfNeeded()
                                }
                                let providers = modelProviders(for: profile.aiTool)
                                if providers.isEmpty {
                                    Text("settings.evolution.noModels".localized)
                                } else if providers.count == 1 {
                                    if let onlyProvider = providers.first {
                                        ForEach(onlyProvider.models) { model in
                                            Button(model.name) {
                                                hasPendingUserProfileEdit = true
                                                profile.providerID = onlyProvider.id
                                                profile.modelID = model.id
                                                sanitizeModelVariantSelection(profile: &profile)
                                                autoSaveProfilesIfNeeded()
                                            }
                                        }
                                    }
                                } else {
                                    ForEach(providers) { provider in
                                        Menu(provider.name) {
                                            ForEach(provider.models) { model in
                                                Button(model.name) {
                                                    hasPendingUserProfileEdit = true
                                                    profile.providerID = provider.id
                                                    profile.modelID = model.id
                                                    sanitizeModelVariantSelection(profile: &profile)
                                                    autoSaveProfilesIfNeeded()
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Text(selectedModelDisplayName(for: profile))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        LabeledContent("模型变体") {
                            Menu {
                                Button("默认") {
                                    hasPendingUserProfileEdit = true
                                    if let optionID = modelVariantOptionID(for: profile.aiTool) {
                                        profile.configOptions.removeValue(forKey: optionID)
                                    }
                                    autoSaveProfilesIfNeeded()
                                }
                                let options = modelVariantOptions(for: profile)
                                if options.isEmpty {
                                    Text("当前模型未提供可用变体")
                                } else {
                                    ForEach(options, id: \.self) { option in
                                        Button(option) {
                                            hasPendingUserProfileEdit = true
                                            if let optionID = modelVariantOptionID(for: profile.aiTool) {
                                                profile.configOptions[optionID] = option
                                            }
                                            autoSaveProfilesIfNeeded()
                                        }
                                    }
                                }
                            } label: {
                                Text(selectedModelVariant(for: profile) ?? "默认")
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            let runtimeOnly = runtimeOnlyAgents()
            if !runtimeOnly.isEmpty {
                Section("evolution.page.agentList.section".localized) {
                    ForEach(Array(runtimeOnly.enumerated()), id: \.offset) { _, runtime in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(stageDisplayName(runtime.stage))
                                .font(.headline)
                            LabeledContent("evolution.page.agent.status".localized) {
                                Text(localizedStageStatusDisplay(runtime.status))
                                    .foregroundColor(stageStatusColor(runtime.status))
                            }
                            Text(String(format: "evolution.page.toolCallCount".localized, runtime.toolCallCount))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            // v1.45: 分析摘要（从 Core 权威输出消费）
            analysisStatusSection
            // 历史循环
            mobileCycleHistorySection
        }
        .navigationTitle("evolution.page.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPlanDocumentSheetPresented) {
            mobilePlanDocumentSheet
        }
        .sheet(item: $selectedCycleDetail) { detail in
            mobileCycleDetailSheet(detail)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("common.refresh".localized) {
                    appState.refreshEvolution(project: project, workspace: workspace)
                    projectionStore.refresh(appState: appState, project: project, workspace: workspace)
                    loadProfiles()
                }
            }
        }
        .onAppear {
            projectionStore.bind(appState: appState, project: project, workspace: workspace)
            optionsStore.bindEvolution(appState: appState, project: project, workspace: workspace)
            appState.openEvolution(project: project, workspace: workspace)
            loadProfiles()
            syncStartOptionsFromItem()
            appState.requestEvolutionCycleHistory(project: project, workspace: workspace)
        }
        .onReceive(appState.$evolutionStageProfilesByWorkspace) { _ in
            loadProfiles()
        }
        .onChange(of: item?.statusStageRoundSignature) { _, _ in
            syncStartOptionsFromItem()
        }
        .onChange(of: activeBlockingRequest) { _, value in
            syncBlockingDrafts(value)
        }
        .onChange(of: appState.isConnected) { _, connected in
            guard connected else { return }
            appState.refreshEvolution(project: project, workspace: workspace)
            projectionStore.refresh(appState: appState, project: project, workspace: workspace)
            loadProfiles()
        }
    }

    private var mobilePlanDocumentSheet: some View {
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
                        Text(LocalizedStringKey(content))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refreshSelectedPlanDocument()
                    } label: {
                        Label("evolution.page.planDocument.refresh".localized, systemImage: "arrow.clockwise")
                    }
                    .disabled(selectedPlanDocumentCycleID == nil && item == nil)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.close".localized) {
                        selectedPlanDocumentCycleID = nil
                        isPlanDocumentSheetPresented = false
                    }
                }
            }
        }
    }

    private func openPlanDocumentSheet(cycleID: String) {
        selectedPlanDocumentCycleID = cycleID
        appState.requestEvolutionPlanDocument(project: project, workspace: workspace, cycleID: cycleID)
        isPlanDocumentSheetPresented = true
    }

    private func refreshSelectedPlanDocument() {
        if let cycleID = selectedPlanDocumentCycleID {
            appState.requestEvolutionPlanDocument(project: project, workspace: workspace, cycleID: cycleID)
            return
        }
        if let item {
            appState.requestEvolutionPlanDocument(project: project, workspace: workspace, cycleID: item.cycleID)
        }
    }

    private func loadProfiles() {
        let values = appState.evolutionProfiles(project: project, workspace: workspace)
        let loadedProfiles = values.map { profile in
            EvolutionProfileDraft(
                id: profile.stage,
                stage: profile.stage,
                aiTool: profile.aiTool,
                mode: profile.mode ?? "",
                providerID: profile.model?.providerID ?? "",
                modelID: profile.model?.modelID ?? "",
                configOptions: profile.configOptions
            )
        }
        let incomingSignature = profileSignature(loadedProfiles)
        if shouldIgnoreIncomingProfiles(signature: incomingSignature) {
            return
        }

        isApplyingRemoteProfiles = true
        profiles = loadedProfiles
        lastSyncedProfileSignature = profileSignature(profiles)
        if pendingProfileSaveSignature == lastSyncedProfileSignature {
            pendingProfileSaveSignature = nil
            pendingProfileSaveDate = nil
        }
        hasPendingUserProfileEdit = false
        DispatchQueue.main.async {
            isApplyingRemoteProfiles = false
        }
    }

    private func modeOptions(for tool: AIChatTool) -> [String] {
        optionsStore.options(for: tool).modeOptions
    }

    private func runtimeAgent(for stage: String) -> EvolutionAgentInfoV2? {
        item?.agents.first { normalizedStageKey($0.stage) == normalizedStageKey(stage) }
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

    private func mobileWorkspaceStatusColor(_ status: String) -> Color {
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
        case "interrupted":
            return .orange
        case "failed_exhausted", "failed_system":
            return .red
        case "completed", "done", "success":
            return .green
        default:
            return .secondary
        }
    }

    private func canOpenStageSession(stage: String) -> Bool {
        item?.latestResolvedExecution(forStage: stage) != nil
    }

    private func openCurrentStageSession(stage: String) {
        guard let currentItem = item,
              let execution = currentItem.latestResolvedExecution(forStage: stage) else { return }
        openExecutionSession(
            sessionID: execution.sessionID,
            aiToolRawValue: execution.aiTool,
            stage: execution.stage,
            cycleID: currentItem.cycleID
        )
    }

    private func normalizedStageStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedStageKey(_ stage: String) -> String {
        EvolutionStageSemantics.profileStageKey(for: stage)
    }

    private func isCompletedStatus(_ status: String) -> Bool {
        status == "completed" ||
            status == "done" ||
            status == "success" ||
            status == "succeeded" ||
            status == "已完成" ||
            status == "完成"
    }

    private func isExecutionCompletedStatus(_ status: String) -> Bool {
        let normalized = normalizedStageStatus(status)
        if normalized.isEmpty {
            return false
        }
        if normalized == "running" ||
            normalized == "pending" ||
            normalized == "queued" ||
            normalized == "in_progress" ||
            normalized == "processing" {
            return false
        }
        return true
    }

    private func stageSortOrder(_ stage: String) -> (Int, Int, Int, String) {
        EvolutionStageSemantics.stageSortOrder(stage)
    }

    private func runtimeOnlyAgents() -> [EvolutionAgentInfoV2] {
        guard let item else { return [] }
        let configuredStages = Set(profiles.map { normalizedStageKey($0.stage) })
        return item.agents
            .filter { !configuredStages.contains(normalizedStageKey($0.stage)) }
            .sorted { lhs, rhs in
                let leftOrder = stageSortOrder(lhs.stage)
                let rightOrder = stageSortOrder(rhs.stage)
                if leftOrder != rightOrder {
                    return leftOrder < rightOrder
                }
                return lhs.stage < rhs.stage
            }
    }

    private func sectionTitle(for profile: EvolutionProfileDraft, runtime: EvolutionAgentInfoV2?) -> String {
        let runtimeAgent = runtime?.agent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !runtimeAgent.isEmpty { return runtimeAgent }
        let configuredMode = profile.mode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredMode.isEmpty { return configuredMode }
        return stageDisplayName(profile.stage)
    }

    private func applyAgentDefaultModelIfAvailable(profileID: String, agentName: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var profile = profiles[index]
        guard let selection = optionsStore.defaultModelSelection(agentName: agentName, for: profile.aiTool) else {
            return
        }

        profile.providerID = selection.providerID
        profile.modelID = selection.modelID
        sanitizeModelVariantSelection(profile: &profile)
        profiles[index] = profile
    }

    private func modelProviders(for tool: AIChatTool) -> [EvolutionProviderOptionProjection] {
        optionsStore.options(for: tool).providers
    }

    private func selectedModelDisplayName(for profile: EvolutionProfileDraft) -> String {
        optionsStore.selectedModelDisplayName(
            providerID: profile.providerID,
            modelID: profile.modelID,
            for: profile.aiTool,
            defaultLabel: "settings.evolution.defaultModel".localized
        )
    }

    private func modelVariantOptionID(for tool: AIChatTool) -> String? {
        optionsStore.modelVariantOptionID(for: tool)
    }

    private func modelVariantOptions(for profile: EvolutionProfileDraft) -> [String] {
        optionsStore.modelVariantOptions(
            for: profile.aiTool,
            providerID: profile.providerID,
            modelID: profile.modelID
        )
    }

    private func selectedModelVariant(for profile: EvolutionProfileDraft) -> String? {
        optionsStore.selectedModelVariant(
            configOptions: profile.configOptions,
            providerID: profile.providerID,
            modelID: profile.modelID,
            for: profile.aiTool
        )
    }

    private func sanitizeProfileSelection(profileID: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var profile = profiles[index]

        if !profile.mode.isEmpty {
            let modes = modeOptions(for: profile.aiTool)
            if !modes.isEmpty, !modes.contains(profile.mode) {
                profile.mode = ""
            }
        }

        if !profile.providerID.isEmpty || !profile.modelID.isEmpty {
            let providers = modelProviders(for: profile.aiTool)
            let modelExists = providers.contains { provider in
                provider.id == profile.providerID &&
                    provider.models.contains(where: { $0.id == profile.modelID })
            }
            if !providers.isEmpty, !modelExists {
                profile.providerID = ""
                profile.modelID = ""
            }
        }

        sanitizeModelVariantSelection(profile: &profile)

        profiles[index] = profile
    }

    private func sanitizeModelVariantSelection(profile: inout EvolutionProfileDraft) {
        guard let optionID = modelVariantOptionID(for: profile.aiTool) else { return }
        guard let raw = profile.configOptions[optionID] else { return }
        let value = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let variants = modelVariantOptions(for: profile)
        if value.isEmpty || (!variants.isEmpty && !variants.contains(value)) {
            profile.configOptions.removeValue(forKey: optionID)
        }
    }

    private func buildStageProfilesForSubmit() -> [EvolutionStageProfileInfoV2] {
        profiles.map { profile in
            var mode: String?
            if !profile.mode.isEmpty {
                let modes = modeOptions(for: profile.aiTool)
                if modes.isEmpty || modes.contains(profile.mode) {
                    mode = profile.mode
                }
            }

            let model: EvolutionModelSelectionV2? = {
                guard !profile.providerID.isEmpty, !profile.modelID.isEmpty else { return nil }
                return EvolutionModelSelectionV2(providerID: profile.providerID, modelID: profile.modelID)
            }()

            let configOptions = profile.configOptions

            return EvolutionStageProfileInfoV2(
                stage: profile.stage,
                aiTool: profile.aiTool,
                mode: mode,
                model: model,
                configOptions: configOptions
            )
        }
    }

    private func saveProfiles() {
        let values = buildStageProfilesForSubmit()
        appState.updateEvolutionAgentProfile(project: project, workspace: workspace, profiles: values)
    }

    private func autoSaveProfilesIfNeeded() {
        guard !isApplyingRemoteProfiles else { return }
        guard hasPendingUserProfileEdit else { return }
        let signature = profileSignature(profiles)
        guard signature != lastSyncedProfileSignature else {
            hasPendingUserProfileEdit = false
            return
        }
        guard signature != pendingProfileSaveSignature else { return }
        pendingProfileSaveSignature = signature
        pendingProfileSaveDate = Date()
        hasPendingUserProfileEdit = false
        saveProfiles()
    }

    private func shouldIgnoreIncomingProfiles(signature: String) -> Bool {
        guard let pending = pendingProfileSaveSignature else { return false }
        guard pending != signature else { return false }

        let timeout: TimeInterval = 3
        if let date = pendingProfileSaveDate, Date().timeIntervalSince(date) < timeout {
            return true
        }

        pendingProfileSaveSignature = nil
        pendingProfileSaveDate = nil
        return false
    }

    private func profileSignature(_ values: [EvolutionProfileDraft]) -> String {
        values
            .sorted { $0.stage < $1.stage }
            .map {
                [
                    $0.stage,
                    $0.aiTool.rawValue,
                    $0.mode,
                    $0.providerID,
                    $0.modelID,
                    configOptionsSignature($0.configOptions)
                ].joined(separator: "::")
            }
            .joined(separator: "||")
    }

    private func configOptionsSignature(_ configOptions: [String: Any]) -> String {
        guard !configOptions.isEmpty else { return "" }
        guard JSONSerialization.isValidJSONObject(configOptions),
              let data = try? JSONSerialization.data(withJSONObject: configOptions, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(NSDictionary(dictionary: configOptions))"
        }
        return text
    }

    private func startEvolution() {
        let loopRoundLimit = max(1, Int(loopRoundLimitText) ?? 1)
        let values = buildStageProfilesForSubmit()
        appState.startEvolution(
            project: project,
            workspace: workspace,
            loopRoundLimit: loopRoundLimit,
            profiles: values
        )
    }

    private func triggerPrimaryControlAction() {
        if controlState.canStop {
            appState.stopEvolution(project: project, workspace: workspace)
            return
        }
        if controlState.canStart {
            startEvolution()
        }
    }

    private func syncStartOptionsFromItem() {
        guard let item else { return }
        loopRoundLimitText = "\(max(1, item.loopRoundLimit))"
    }

    private func trimmedNonEmptyText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func mobileCycleDisplayTitle(_ value: String?) -> String {
        trimmedNonEmptyText(value) ?? "Untitled"
    }

    private func syncBlockingDrafts(_ value: EvolutionBlockingRequestProjection?) {
        guard let value else { return }
        for item in value.unresolvedItems {
            if blockerDrafts[item.blockerID] != nil { continue }
            blockerDrafts[item.blockerID] = EvolutionBlockerDraft(
                selected: true,
                selectedOptionID: item.options.first?.optionID ?? "",
                answerText: ""
            )
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

    private func submitBlockers(_ blocking: EvolutionBlockingRequestProjection) {
        let resolutions = blocking.unresolvedItems.compactMap { item -> EvolutionBlockerResolutionInputV2? in
            let draft = blockerDrafts[item.blockerID] ?? EvolutionBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
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

    private func isSchedulerActive(_ status: String) -> Bool {
        let normalized = normalizedStageStatus(status)
        return normalized == "active" || normalized == "激活"
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
        case "completed", "done", "success", "succeeded", "已完成", "完成":
            return "evolution.status.completed".localized
        case "error", "failed", "失败":
            return "evolution.status.failed".localized
        case "queued":
            return "evolution.status.queued".localized
        case "idle":
            return "evolution.status.idle".localized
        case "stopped":
            return "evolution.status.stopped".localized
        case "not_started", "not started", "未启动", "未运行":
            return "evolution.status.notStarted".localized
        case "skipped", "skip", "已跳过":
            return "evolution.status.skipped".localized
        default:
            return status
        }
    }

    /// 将终止原因码转为本地化描述
    private func mobileLocalizedTerminalReason(_ code: String) -> String {
        let key = "evolution.terminalReason.\(code)"
        let localized = key.localized
        return localized == key ? code : localized
    }

    private func stageDisplayName(_ stage: String) -> String {
        EvolutionStageSemantics.displayName(for: stage)
    }

    // MARK: - 历史循环紧凑条形

    private struct MobileCycleBarEntry: Identifiable {
        let id: String
        let stage: String
        let agent: String
        let aiTool: String
        let startedAt: String?
        let status: String
        let durationMs: UInt64?
    }

    private struct MobileCycleBarSegment: Identifiable {
        let entry: MobileCycleBarEntry
        let ratio: CGFloat
        var id: String { entry.id }
    }

    private struct MobileCycleDetailTimelineEntry: Identifiable {
        let id: String
        let stage: String
        let agent: String
        let aiTool: String
        let startedAt: String?
        let status: String
        let durationMs: UInt64?
        let sessionID: String?
    }

    private struct MobileCycleDetailPayload: Identifiable {
        let id: String
        let cycleID: String
        let title: String
        let round: Int
        let status: String
        let startTimeText: String
        let totalDurationText: String?
        let terminalReasonCode: String?
        let terminalErrorMessage: String?
        let timelineEntries: [MobileCycleDetailTimelineEntry]
        let allowsChatNavigation: Bool
    }

    private func mobileCycleBarEntries(_ cycle: PipelineCycleHistory) -> [MobileCycleBarEntry] {
        cycle.stageEntries.map { entry in
            MobileCycleBarEntry(
                id: entry.id,
                stage: entry.stage,
                agent: entry.agent,
                aiTool: entry.aiToolRawValue ?? entry.aiToolName,
                startedAt: entry.startedAt,
                status: entry.status ?? "unknown",
                durationMs: entry.durationSeconds > 0 ? UInt64(entry.durationSeconds * 1000) : nil
            )
        }
    }

    private func mobileStageColor(_ stage: String) -> Color {
        switch normalizedStageKey(stage) {
        case "direction": return .cyan
        case "plan": return .blue
        case "implement_general": return .orange
        case "implement_visual": return .pink
        case "implement_advanced": return .purple
        case "verify": return .green
        case "judge": return .yellow
        case "auto_commit": return .gray
        default: return .secondary
        }
    }

    // MARK: - 分析状态（v1.45）

    @ViewBuilder
    private var analysisStatusSection: some View {
        if projection.activeBottleneckCount > 0 {
            Section("分析摘要") {
                HStack {
                    Label("瓶颈", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("\(projection.activeBottleneckCount)")
                        .foregroundStyle(.secondary)
                }
                if projection.maxRiskScore > 0.5 {
                    HStack {
                        Label("风险评分", systemImage: "gauge.with.dots.needle.67percent")
                        Spacer()
                        Text(String(format: "%.0f%%", projection.maxRiskScore * 100))
                            .foregroundStyle(projection.maxRiskScore > 0.7 ? .red : .orange)
                    }
                }
                if projection.systemSuggestionCount > 0 {
                    HStack {
                        Label("优化建议", systemImage: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                        Spacer()
                        Text("\(projection.systemSuggestionCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var mobileCycleHistorySection: some View {
        if !cycleHistories.isEmpty {
            Section("evolution.page.pipeline.historyCycles".localized) {
                ForEach(cycleHistories) { cycle in
                    let entries = mobileCycleBarEntries(cycle)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cycle.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Text(String(format: "evolution.page.pipeline.roundLabel".localized, cycle.round))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Label(mobileCycleTimeLabel(cycle.startDate), systemImage: "clock")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                openPlanDocumentSheet(cycleID: cycle.id)
                            } label: {
                                Image(systemName: "doc.text")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                        }

                        // 紧凑彩色条
                        mobileProportionalStageBar(entries: entries, height: 6)

                        // 终止原因
                        if let reason = trimmedNonEmptyText(cycle.terminalReasonCode) {
                            Text(mobileLocalizedTerminalReason(reason))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let terminalError = trimmedNonEmptyText(cycle.terminalErrorMessage) {
                            Text(terminalError)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedCycleDetail = mobileCycleDetailPayload(cycle)
                    }
                }
            }
        }
    }

    private func mobileCycleDetailPayload(_ cycle: PipelineCycleHistory) -> MobileCycleDetailPayload {
        let timelineEntries = cycle.stageEntries.map { entry in
            MobileCycleDetailTimelineEntry(
                id: entry.id,
                stage: entry.stage,
                agent: entry.agent,
                aiTool: entry.aiToolRawValue ?? entry.aiToolName,
                startedAt: entry.startedAt,
                status: entry.status ?? "unknown",
                durationMs: entry.durationSeconds > 0 ? UInt64(entry.durationSeconds * 1000) : nil,
                sessionID: entry.sessionID
            )
        }
        let totalDurationMs = timelineEntries.compactMap(\.durationMs).reduce(0, +)
        return MobileCycleDetailPayload(
            id: cycle.id,
            cycleID: cycle.id,
            title: cycle.displayTitle,
            round: max(1, cycle.round),
            status: cycle.status ?? "unknown",
            startTimeText: mobileCycleDateTimeLabel(cycle.startDate),
            totalDurationText: totalDurationMs > 0 ? mobileStageDuration(TimeInterval(totalDurationMs) / 1000.0) : nil,
            terminalReasonCode: cycle.terminalReasonCode,
            terminalErrorMessage: cycle.terminalErrorMessage,
            timelineEntries: timelineEntries,
            allowsChatNavigation: true
        )
    }

    private func mobileCycleDetailSheet(_ detail: MobileCycleDetailPayload) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(String(format: "evolution.page.pipeline.roundLabel".localized, detail.round))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        Text(detail.title)
                            .font(.headline)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        Spacer()
                        Text(localizedWorkspaceStatusDisplay(detail.status))
                            .font(.caption)
                            .foregroundColor(mobileWorkspaceStatusColor(detail.status))
                            .fixedSize()
                    }

                    HStack(spacing: 10) {
                        Label("\("evolution.page.pipeline.startTimeLabel".localized): \(detail.startTimeText)", systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let totalDurationText = detail.totalDurationText {
                            Label("\("evolution.page.pipeline.durationLabel".localized): \(totalDurationText)", systemImage: "timer")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let reason = trimmedNonEmptyText(detail.terminalReasonCode) {
                        Text(mobileLocalizedTerminalReason(reason))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let terminalError = trimmedNonEmptyText(detail.terminalErrorMessage) {
                        Text(terminalError)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(4)
                    }

                    Divider()

                    Text("evolution.page.pipeline.timelineTitle".localized)
                        .font(.headline)

                    if detail.timelineEntries.isEmpty {
                        Text("evolution.page.pipeline.noTimeline".localized)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(detail.timelineEntries) { entry in
                                mobileCycleDetailTimelineRow(entry, detail: detail)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(String(format: "evolution.page.pipeline.roundLabel".localized, detail.round))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.close".localized) {
                        selectedCycleDetail = nil
                    }
                }
            }
        }
    }

    private func mobileCycleDetailTimelineRow(_ entry: MobileCycleDetailTimelineEntry, detail: MobileCycleDetailPayload) -> some View {
        let canOpenChat = detail.allowsChatNavigation &&
            trimmedNonEmptyText(entry.sessionID) != nil &&
            AIChatTool(rawValue: entry.aiTool) != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(mobileStageColor(entry.stage))
                    .frame(width: 8, height: 8)
                Text(stageDisplayName(entry.stage))
                    .font(.subheadline.weight(.semibold))
                if let agent = trimmedNonEmptyText(entry.agent) {
                    Text(agent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if canOpenChat {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 10) {
                Label("\("evolution.page.pipeline.startTimeLabel".localized): \(mobileTimelineStartTimeText(entry.startedAt))", systemImage: "clock")
                Label("\("evolution.page.pipeline.durationLabel".localized): \(mobileTimelineDurationText(entry))", systemImage: "timer")
                Label("\("evolution.page.pipeline.aiTool".localized): \(trimmedNonEmptyText(entry.aiTool) ?? "-")", systemImage: "sparkles")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(mobileStageColor(entry.stage).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(mobileStageColor(entry.stage).opacity(0.2), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            guard canOpenChat else { return }
            openHistorySessionFromCycleDetail(entry: entry, cycleID: detail.cycleID)
        }
    }

    private func openHistorySessionFromCycleDetail(entry: MobileCycleDetailTimelineEntry, cycleID: String) {
        guard let sessionID = trimmedNonEmptyText(entry.sessionID),
              let aiToolRawValue = trimmedNonEmptyText(entry.aiTool) else { return }

        openExecutionSession(
            sessionID: sessionID,
            aiToolRawValue: aiToolRawValue,
            stage: entry.stage,
            cycleID: cycleID
        )
    }

    private func openExecutionSession(
        sessionID: String,
        aiToolRawValue: String,
        stage: String,
        cycleID: String
    ) {
        guard let aiTool = AIChatTool(rawValue: aiToolRawValue) else { return }

        let cached = appState.cachedAISession(
            projectName: project,
            workspaceName: workspace,
            aiTool: aiTool,
            sessionId: sessionID
        )
        let fallbackTitle = trimmedNonEmptyText(stage)
            ?? cycleID
        let session = AISessionInfo(
            projectName: project,
            workspaceName: workspace,
            aiTool: aiTool,
            id: sessionID,
            title: cached?.title ?? "\(fallbackTitle) · \(cycleID)",
            updatedAt: cached?.updatedAt ?? 0,
            origin: .evolutionSystem
        )

        selectedCycleDetail = nil
        appState.openAIChat(project: project, workspace: workspace)
        appState.upsertAISession(session, for: aiTool)
        appState.loadAISession(session)
        appState.navigationPath.append(MobileRoute.aiChat(project: project, workspace: workspace))
    }

    private func mobileTimelineStartTimeText(_ startedAt: String?) -> String {
        guard let date = mobileParseISODate(startedAt) else { return "-" }
        return mobileCycleDateTimeLabel(date)
    }

    private func mobileTimelineDurationText(_ entry: MobileCycleDetailTimelineEntry) -> String {
        if let durationMs = entry.durationMs, durationMs > 0 {
            return mobileStageDuration(TimeInterval(durationMs) / 1000.0)
        }
        let normalized = normalizedStageStatus(entry.status)
        if normalized == "running" || normalized == "进行中",
           let startDate = mobileParseISODate(entry.startedAt) {
            return mobileStageDuration(max(0, Date().timeIntervalSince(startDate)))
        }
        return "evolution.page.pipeline.durationUnknown".localized
    }

    private func mobileParseISODate(_ isoString: String?) -> Date? {
        guard let isoString = trimmedNonEmptyText(isoString) else { return nil }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        return isoFormatter.date(from: isoString) ?? fallbackFormatter.date(from: isoString)
    }

    private func mobileCycleDateTimeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func mobileCycleTimeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func mobileStageDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else {
            let minutes = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(minutes)m\(String(format: "%02d", secs))s"
        }
    }

    private func mobileTooltipDuration(_ durationMs: UInt64?) -> String {
        guard let durationMs, durationMs > 0 else {
            return "evolution.page.pipeline.durationUnknown".localized
        }
        return mobileStageDuration(TimeInterval(durationMs) / 1000.0)
    }

    private func mobileProportionalStageBar(entries: [MobileCycleBarEntry], height: CGFloat) -> some View {
        let segments = mobileStageBarSegments(entries)
        let segmentSpacing: CGFloat = 2

        return GeometryReader { geo in
            let totalSpacing = segmentSpacing * CGFloat(max(segments.count - 1, 0))
            let drawableWidth = max(geo.size.width - totalSpacing, 0)
            HStack(spacing: segmentSpacing) {
                ForEach(segments) { segment in
                    let durationText = mobileTooltipDuration(segment.entry.durationMs)
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(mobileStageColor(segment.entry.stage))
                        .frame(width: max(0, drawableWidth * segment.ratio), height: height)
                        .overlay {
                            Color.clear
                                .contentShape(Rectangle())
                                .contextMenu {
                                    Text(stageDisplayName(segment.entry.stage))
                                    if !segment.entry.agent.isEmpty {
                                        Text("evolution.page.pipeline.agentLabel".localized + ": \(segment.entry.agent)")
                                    }
                                    if !segment.entry.aiTool.isEmpty {
                                        Text("AI: \(segment.entry.aiTool)")
                                    }
                                    Text("evolution.page.pipeline.durationLabel".localized + ": \(durationText)")
                                }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.3), value: mobileStageBarAnimationToken(segments))
        }
        .frame(height: height)
        .clipShape(Capsule())
    }

    private func mobileStageBarAnimationToken(_ segments: [MobileCycleBarSegment]) -> String {
        segments
            .map { segment in
                "\(segment.id)=\(String(format: "%.6f", Double(segment.ratio)))"
            }
            .joined(separator: "|")
    }

    private func mobileStageBarSegments(_ entries: [MobileCycleBarEntry]) -> [MobileCycleBarSegment] {
        guard !entries.isEmpty else { return [] }

        let rawDurations = entries.map { TimeInterval($0.durationMs ?? 0) / 1000.0 }
        let positiveDurations = rawDurations.filter { $0 > 0 }
        let weights: [TimeInterval]

        if !positiveDurations.isEmpty {
            let averagePositive = positiveDurations.reduce(0, +) / Double(positiveDurations.count)
            let fallbackWeight = max(averagePositive * 0.12, 0.3)
            weights = rawDurations.map { duration in
                duration > 0 ? duration : fallbackWeight
            }
        } else {
            weights = Array(repeating: 1, count: entries.count)
        }

        let totalWeight = max(weights.reduce(0, +), 0.0001)
        return zip(entries, weights).map { entry, weight in
            MobileCycleBarSegment(entry: entry, ratio: CGFloat(weight / totalWeight))
        }
    }
}
