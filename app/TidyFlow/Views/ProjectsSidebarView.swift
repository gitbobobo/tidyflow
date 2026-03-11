import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Project Tree Sidebar - Shows Projects > Workspaces hierarchy
/// UX-1: Replaces flat workspace list with collapsible project tree
struct ProjectsSidebarView: View {
    let appState: AppState
    let terminalStore: TerminalStore
    @StateObject private var projectionStore = MacSidebarProjectionStore()

    var body: some View {
        let _ = Self.debugPrintChangesIfNeeded()
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("sidebar.projects".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if projectionStore.projects.isEmpty && appState.projects.isEmpty {
                emptyStateView
            } else {
                projectListView
            }
        }
        .frame(minWidth: 200)
        .onAppear {
            projectionStore.bind(
                appState: appState,
                terminalStore: terminalStore,
                taskStore: appState.taskManager.taskStore
            )
        }
        .tfRenderProbe("ProjectsSidebar", metadata: [
            "selected_workspace": appState.currentGlobalWorkspaceKey ?? "none"
        ])
        .tfHotspotBaseline(
            .macSidebar,
            renderProbeName: "ProjectsSidebar",
            metadata: [
                "selected_workspace": appState.currentGlobalWorkspaceKey ?? "none"
            ]
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    appState.addProjectSheetPresented = true
                }) {
                    Image(systemName: "plus")
                }
                .help("sidebar.addProject".localized)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))
            Text("sidebar.noProjects".localized)
                .font(.headline)
                .foregroundColor(.secondary)
            Text("sidebar.noProjects.hint".localized)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
            Button("sidebar.noProjects.button".localized) {
                appState.addProjectSheetPresented = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Project List

    /// 扁平化的列表行类型
    private enum SidebarRow: Identifiable {
        case project(SidebarProjectProjection)
        case workspace(SidebarWorkspaceProjection, projectId: UUID)

        var id: String {
            switch self {
            case .project(let projection):
                return projection.id
            case .workspace(let projection, _):
                return projection.id
            }
        }
    }

    /// 将项目和工作空间扁平化为单一列表（使用缓存的排序索引）
    /// 项目始终展开，不可折叠
    private var flattenedRows: [SidebarRow] {
        var rows: [SidebarRow] = []
        for project in displayedProjects {
            rows.append(.project(project))
            guard let projectId = project.projectID else { continue }
            for workspace in project.visibleWorkspaces {
                rows.append(.workspace(workspace, projectId: projectId))
            }
        }
        return rows
    }

    private var projectListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(flattenedRows) { row in
                    switch row {
                    case .project(let projection):
                        if let projectId = projection.projectID,
                           let binding = projectBinding(for: projectId) {
                            ProjectRowView(project: binding, projection: projection)
                                .environmentObject(appState)
                        }
                    case .workspace(let projection, let projectId):
                        WorkspaceRowView(projection: projection, projectId: projectId, isSelected: projection.isSelected)
                            .environmentObject(appState)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 4)
        .accessibilityIdentifier("tf.mac.sidebar.workspace-list")
    }

    private var displayedProjects: [SidebarProjectProjection] {
        if !projectionStore.projects.isEmpty {
            return projectionStore.projects
        }
        return SidebarProjectionSemantics.buildMacProjects(
            appState: appState,
            terminalStore: terminalStore,
            unseenCompletionKeys: appState.taskManager.taskStore.unseenCompletionKeys
        )
    }

    private func projectBinding(for projectId: UUID) -> Binding<ProjectModel>? {
        guard let index = appState.projects.firstIndex(where: { $0.id == projectId }) else {
            return nil
        }
        return Binding(
            get: { appState.projects[index] },
            set: { appState.projects[index] = $0 }
        )
    }

    private static func debugPrintChangesIfNeeded() {
        SwiftUIPerformanceDebug.runPrintChangesIfEnabled(
            SwiftUIPerformanceDebug.projectsSidebarPrintChangesEnabled
        ) {
#if DEBUG
            Self._printChanges()
#endif
        }
    }
}

struct ExternalApplicationsMenu: View {
    let path: String
    @EnvironmentObject var appState: AppState

    private let menuIconSize: CGFloat = 16

    private func editorMenuIcon(_ editor: ExternalEditor) -> some View {
        FixedSizeAssetImage(name: editor.assetName, targetSize: menuIconSize)
    }

    @ViewBuilder
    private var finderMenuIcon: some View {
        #if canImport(AppKit)
        if let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            FixedSizeImage(
                image: Image(nsImage: NSWorkspace.shared.icon(forFile: finderURL.path)),
                label: "Finder",
                targetSize: menuIconSize
            )
        } else {
            Image(systemName: "folder")
        }
        #else
        Image(systemName: "folder")
        #endif
    }

    var body: some View {
        Menu {
            Button {
                _ = appState.openPathInFinder(path)
            } label: {
                Label {
                    Text("Finder")
                } icon: {
                    finderMenuIcon
                }
            }

            Divider()

            ForEach(ExternalEditor.allCases, id: \.self) { editor in
                Button {
                    _ = appState.openPathInEditor(path, editor: editor)
                } label: {
                    Label {
                        Text(editor.rawValue)
                    } icon: {
                        editorMenuIcon(editor)
                    }
                }
                .disabled(!editor.isInstalled)
            }
        } label: {
            Label("sidebar.openInEditor".localized, systemImage: "square.and.arrow.up")
        }
    }
}

// MARK: - Project Row (Collapsible)

struct ProjectRowView: View {
    @Binding var project: ProjectModel
    let projection: SidebarProjectProjection
    @EnvironmentObject var appState: AppState
    @State private var showDeleteConfirmation = false
    @State private var showEndWorkConfirmation = false

    /// 项目路径（项目根目录），用于外部应用打开
    private var projectPath: String? { projection.projectPath }
    private var defaultWorkspacePath: String? { projection.defaultWorkspacePath }
    private var defaultGlobalWorkspaceKey: String? { projection.defaultGlobalWorkspaceKey }
    private var shortcutDisplayText: String? { projection.shortcutDisplayText }
    private var terminalCount: Int { projection.terminalCount }
    private var hasOpenTabs: Bool { projection.hasOpenTabs }
    private var isDeleting: Bool { projection.isDeleting }
    private var hasUnseenCompletion: Bool { projection.hasUnseenCompletion }
    private var defaultWorkspaceActivityIndicators: [TreeRowActivityIndicator] {
        projection.activityIndicators.map { TreeRowActivityIndicator(id: $0.id, iconName: $0.iconName) }
    }
    @ViewBuilder
    private var terminalCountBadge: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.85))
            Text("\(terminalCount)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    var body: some View {
        Group {
            if terminalCount > 0 {
                TreeRowView(
                    isExpandable: false,
                    isExpanded: true,
                    iconName: "",
                    iconColor: .clear,
                    title: project.name,
                    depth: 0,
                    isSelected: projection.isSelectedDefaultWorkspace,
                    trailingText: shortcutDisplayText,
                    trailingIcon: hasUnseenCompletion ? "bell.fill" : nil,
                    activityIndicators: defaultWorkspaceActivityIndicators,
                    isLoading: isDeleting,
                    customIconView: terminalCountBadge,
                    onTap: {
                        if !isDeleting {
                            appState.selectProjectDefaultWorkspace(project)
                        }
                    }
                )
            } else {
                TreeRowView(
                    isExpandable: false,
                    isExpanded: true,
                    iconName: "folder.fill",
                    iconColor: .accentColor,
                    title: project.name,
                    depth: 0,
                    isSelected: projection.isSelectedDefaultWorkspace,
                    trailingText: shortcutDisplayText,
                    trailingIcon: hasUnseenCompletion ? "bell.fill" : nil,
                    activityIndicators: defaultWorkspaceActivityIndicators,
                    isLoading: isDeleting,
                    onTap: {
                        if !isDeleting {
                            appState.selectProjectDefaultWorkspace(project)
                        }
                    }
                )
            }
        }
        // 项目右键菜单：路径操作 → 项目操作 → 危险操作
        .contextMenu {
            if !isDeleting {
                if let path = defaultWorkspacePath ?? projectPath {
                    ExternalApplicationsMenu(path: path)
                    Divider()
                }

                if projection.defaultWorkspaceName != nil {
                    Button {
                        triggerAICommit()
                    } label: {
                        Label("git.aiCommit".localized, systemImage: "sparkles")
                    }

                    Button {
                        showEndWorkConfirmation = true
                    } label: {
                        Label("sidebar.endWork".localized, systemImage: "xmark.circle")
                    }
                    .disabled(!hasOpenTabs)

                    Divider()
                }
            }

            // ── 项目操作 ──
            if !isDeleting {
                Button {
                    appState.createWorkspace(projectName: project.name)
                } label: {
                    Label("sidebar.newWorkspace".localized, systemImage: "plus.square.on.square")
                }

                Divider()
            }

            // ── 危险操作 ──
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("sidebar.removeProject".localized, systemImage: "trash")
            }
        }
        .alert("sidebar.removeProject.title".localized, isPresented: $showDeleteConfirmation) {
            Button("common.cancel".localized, role: .cancel) { }
            Button("common.remove".localized, role: .destructive) {
                appState.removeProject(id: project.id)
            }
        } message: {
            Text(String(format: "sidebar.removeProject.message".localized, project.name))
        }
        .alert("sidebar.endWork.confirm.title".localized, isPresented: $showEndWorkConfirmation) {
            Button("common.cancel".localized, role: .cancel) { }
            Button("common.confirm".localized) {
                guard let defaultGlobalWorkspaceKey else { return }
                appState.forceCloseAllTabs(workspaceKey: defaultGlobalWorkspaceKey)
            }
        } message: {
            Text("sidebar.endWork.confirm.message".localized)
        }
    }

    private func triggerAICommit() {
        guard let defaultWorkspaceName = projection.defaultWorkspaceName else { return }
        appState.submitBackgroundTask(
            type: .aiCommit,
            context: .aiCommit(AICommitContext(
                projectName: project.name,
                workspaceKey: defaultWorkspaceName,
                workspacePath: defaultWorkspacePath ?? projection.projectPath ?? "",
                projectPath: projection.projectPath
            ))
        )
    }
}

// MARK: - Workspace Row

struct WorkspaceRowView: View {
    let projection: SidebarWorkspaceProjection
    let projectId: UUID
    let isSelected: Bool
    @EnvironmentObject var appState: AppState
    @State private var showDeleteConfirmation = false
    @State private var showEndWorkConfirmation = false
    @State private var showNoAgentAlert = false

    /// 工作空间路径，用于外部应用打开
    private var workspacePath: String? { projection.workspacePath }

    /// 工作空间全局键，用于获取终端数量
    private var globalWorkspaceKey: String {
        projection.globalWorkspaceKey
    }

    /// 当前工作空间的终端数量
    private var terminalCount: Int {
        projection.terminalCount
    }

    /// 当前工作空间是否有打开的标签页（任意类型）
    private var hasOpenTabs: Bool {
        projection.hasOpenTabs
    }

    /// 终端数量徽章视图
    @ViewBuilder
    private var terminalCountBadge: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.85))
            Text("\(terminalCount)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    /// 当前工作空间是否正在删除中
    private var isDeleting: Bool {
        projection.isDeleting
    }

    /// 该工作空间是否有未读完成的后台任务（侧边栏铃铛提示）
    private var hasUnseenCompletion: Bool {
        projection.hasUnseenCompletion
    }

    /// 右侧活动图标：聊天流式 / 自主进化 / 后台任务（可并存）
    private var workspaceActivityIndicators: [TreeRowActivityIndicator] {
        projection.activityIndicators.map { TreeRowActivityIndicator(id: $0.id, iconName: $0.iconName) }
    }

    var body: some View {
        Group {
            if terminalCount > 0 {
                TreeRowView(
                    isExpandable: false,
                    isExpanded: false,
                    iconName: "",
                    iconColor: .clear,
                    title: projection.workspaceName,
                    depth: 1,
                    isSelected: isSelected,
                    trailingText: projection.shortcutDisplayText,
                    trailingIcon: hasUnseenCompletion ? "bell.fill" : nil,
                    activityIndicators: workspaceActivityIndicators,
                    isLoading: isDeleting,
                    customIconView: terminalCountBadge,
                    onTap: {
                        if !isDeleting {
                            appState.selectWorkspace(projectId: projectId, workspaceName: projection.workspaceName)
                        }
                    }
                )
            } else {
                TreeRowView(
                    isExpandable: false,
                    isExpanded: false,
                    iconName: "square.grid.2x2",
                    iconColor: .secondary,
                    title: projection.workspaceName,
                    depth: 1,
                    isSelected: isSelected,
                    trailingText: projection.shortcutDisplayText,
                    trailingIcon: hasUnseenCompletion ? "bell.fill" : nil,
                    activityIndicators: workspaceActivityIndicators,
                    isLoading: isDeleting,
                    onTap: {
                        if !isDeleting {
                            appState.selectWorkspace(projectId: projectId, workspaceName: projection.workspaceName)
                        }
                    }
                )
            }
        }
        .tag(projection.workspaceName)
        .accessibilityIdentifier("tf.mac.sidebar.workspace.\(projection.workspaceName)")
        // 工作空间右键菜单：删除中时不显示
        .contextMenu {
            if !isDeleting {
                // ── 路径 / 打开 ──
                if let path = workspacePath {
                    ExternalApplicationsMenu(path: path)
                }

                Divider()

                // ── AI 操作 ──
                Button {
                    triggerAICommit()
                } label: {
                    Label("git.aiCommit".localized, systemImage: "sparkles")
                }

                if !projection.isDefault {
                    Button {
                        triggerAIMerge()
                    } label: {
                        Label("sidebar.aiMerge".localized, systemImage: "cpu")
                    }
                    .disabled(appState.clientSettings.mergeAIAgent == nil)
                }

                Divider()

                Button {
                    showEndWorkConfirmation = true
                } label: {
                    Label("sidebar.endWork".localized, systemImage: "xmark.circle")
                }
                .disabled(!hasOpenTabs)

                // ── 危险操作 ──
                if !projection.isDefault {
                    Divider()

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("common.delete".localized, systemImage: "trash")
                    }
                }
            }
        }
        .alert("sidebar.deleteWorkspace".localized, isPresented: $showDeleteConfirmation) {
            Button("common.cancel".localized, role: .cancel) { }
            Button("common.delete".localized, role: .destructive) {
                appState.removeWorkspace(
                    projectName: projection.projectName,
                    workspaceName: projection.workspaceName
                )
            }
        } message: {
            Text(String(format: "sidebar.deleteWorkspace.message".localized, projection.workspaceName))
        }
        .alert("sidebar.endWork.confirm.title".localized, isPresented: $showEndWorkConfirmation) {
            Button("common.cancel".localized, role: .cancel) { }
            Button("common.confirm".localized) {
                appState.forceCloseAllTabs(workspaceKey: globalWorkspaceKey)
            }
        } message: {
            Text("sidebar.endWork.confirm.message".localized)
        }
        .alert("settings.aiAgent.notConfigured".localized, isPresented: $showNoAgentAlert) {
            Button("common.confirm".localized, role: .cancel) { }
        } message: {
            Text("settings.aiAgent.notConfigured.message".localized)
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    /// 触发 AI 合并（后台任务）
    private func triggerAIMerge() {
        guard appState.clientSettings.mergeAIAgent != nil else {
            showNoAgentAlert = true
            return
        }
        appState.submitBackgroundTask(
            type: .aiMerge,
            context: .aiMerge(AIMergeContext(
                projectName: projection.projectName,
                workspaceName: projection.workspaceName
            ))
        )
    }

    /// 触发 AI 智能提交（后台任务）
    private func triggerAICommit() {
        appState.submitBackgroundTask(
            type: .aiCommit,
            context: .aiCommit(AICommitContext(
                projectName: projection.projectName,
                workspaceKey: projection.workspaceName,
                workspacePath: workspacePath ?? projection.projectPath ?? "",
                projectPath: projection.projectPath
            ))
        )
    }
}

// MARK: - AI 合并结果弹窗

struct AIMergeResultSheet: View {
    let result: AIMergeResult
    @Environment(\.dismiss) private var dismiss
    @State private var showRawOutput = false

    var body: some View {
        VStack(spacing: 16) {
            // 标题栏
            HStack {
                Text("sidebar.aiMerge.result".localized)
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
                        Text(result.resultStatus.mergeDisplayText)
                            .font(.system(size: 16, weight: .semibold))
                    }

                    // 消息
                    if !result.message.isEmpty {
                        Text(result.message)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }

                    // 冲突文件列表
                    if !result.conflicts.isEmpty {
                        Divider()
                        Text("sidebar.aiMerge.conflicts".localized)
                            .font(.system(size: 13, weight: .medium))
                        ForEach(result.conflicts, id: \.self) { file in
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                Text(file)
                                    .font(.system(size: 12, design: .monospaced))
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
                                .background(Color.primary.opacity(0.06))
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
        .frame(width: 480, height: 400)
    }
}
