import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Project Tree Sidebar - Shows Projects > Workspaces hierarchy
/// UX-1: Replaces flat workspace list with collapsible project tree
struct ProjectsSidebarView: View {
    @EnvironmentObject var appState: AppState

    /// 缓存排序后的项目索引，避免每次 body 重算都执行 O(n log n) 排序
    @State private var cachedSortedIndices: [Int] = []

    var body: some View {
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

            if appState.projects.isEmpty {
                emptyStateView
            } else {
                projectListView
            }
        }
        .frame(minWidth: 200)
        .onAppear {
            cachedSortedIndices = computeSortedIndices()
        }
        // 项目列表变化（增删、名称修改等）时重新排序
        .onChange(of: appState.projects.map { $0.id }) { _ in
            cachedSortedIndices = computeSortedIndices()
        }
        // 快捷键分配或终端打开时间变化时重新排序
        .onChange(of: appState.workspaceTerminalOpenTime) { _ in
            cachedSortedIndices = computeSortedIndices()
        }
        // 工作空间删除状态变化时重新排序
        .onChange(of: appState.deletingWorkspaces) { _ in
            cachedSortedIndices = computeSortedIndices()
        }
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
        case project(Binding<ProjectModel>)
        case workspace(WorkspaceModel, projectId: UUID, projectName: String)

        var id: String {
            switch self {
            case .project(let binding):
                return "project-\(binding.wrappedValue.id)"
            case .workspace(let ws, let projectId, _):
                return "workspace-\(projectId)-\(ws.id)"
            }
        }
    }

    /// 获取项目中最早的终端创建时间（用于排序）
    private func projectEarliestTerminalTime(_ project: ProjectModel) -> Date? {
        var earliest: Date?
        for workspace in project.workspaces {
            let key = "\(project.name):\(workspace.name)"
            if let time = appState.workspaceTerminalOpenTime[key] {
                if earliest == nil || time < earliest! {
                    earliest = time
                }
            }
        }
        return earliest
    }

    /// 获取项目的最小快捷键编号（用于排序，0视为10以排在最后）
    private func projectMinShortcutKey(_ project: ProjectModel) -> Int {
        var minKey = Int.max
        for workspace in project.workspaces {
            let workspaceKey = workspace.isDefault
                ? "\(project.name)/(default)"
                : "\(project.name)/\(workspace.name)"
            if let shortcutKey = appState.getWorkspaceShortcutKey(workspaceKey: workspaceKey),
               let num = Int(shortcutKey) {
                // 0 视为 10，排在最后
                let sortValue = num == 0 ? 10 : num
                minKey = min(minKey, sortValue)
            }
        }
        return minKey
    }

    /// 计算项目排序索引（纯排序逻辑，不含 Binding）
    private func computeSortedIndices() -> [Int] {
        appState.projects.indices.sorted { i, j in
            let projectA = appState.projects[i]
            let projectB = appState.projects[j]

            let hasShortcutA = projectMinShortcutKey(projectA) < Int.max
            let hasShortcutB = projectMinShortcutKey(projectB) < Int.max

            // 1. 有快捷键的项目排在前面
            if hasShortcutA != hasShortcutB {
                return hasShortcutA
            }

            // 2. 有快捷键的项目之间，按最早终端创建时间排序（早的在前）
            if hasShortcutA && hasShortcutB {
                let timeA = projectEarliestTerminalTime(projectA)
                let timeB = projectEarliestTerminalTime(projectB)
                if let tA = timeA, let tB = timeB, tA != tB {
                    return tA < tB
                }
            }

            // 3. 默认按项目名称字母序，确保启动时排序稳定
            return projectA.name.localizedCaseInsensitiveCompare(projectB.name) == .orderedAscending
        }
    }

    /// 将项目和工作空间扁平化为单一列表（使用缓存的排序索引）
    private var flattenedRows: [SidebarRow] {
        var rows: [SidebarRow] = []
        for index in cachedSortedIndices where index < appState.projects.count {
            let projectBinding = $appState.projects[index]
            let project = projectBinding.wrappedValue
            rows.append(.project(projectBinding))
            if project.isExpanded {
                for workspace in project.workspaces {
                    rows.append(.workspace(workspace, projectId: project.id, projectName: project.name))
                }
            }
        }
        return rows
    }

    /// 使用 ScrollView + LazyVStack 实现无间距列表，与资源管理器面板保持一致
    private var projectListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(flattenedRows) { row in
                    switch row {
                    case .project(let binding):
                        ProjectRowView(project: binding)
                            .environmentObject(appState)
                    case .workspace(let workspace, let projectId, let projectName):
                        WorkspaceRowView(
                            workspace: workspace,
                            projectId: projectId,
                            projectName: projectName,
                            isSelected: appState.selectedProjectId == projectId && appState.selectedWorkspaceKey == workspace.name
                        )
                        .environmentObject(appState)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Project Row (Collapsible)

struct ProjectRowView: View {
    @Binding var project: ProjectModel
    @EnvironmentObject var appState: AppState
    @State private var showDeleteConfirmation = false

    /// 项目路径（项目根目录），用于复制与在编辑器中打开
    private var projectPath: String? { project.path }

    /// 菜单项图标尺寸
    private let menuIconSize: CGFloat = 16

    private func editorMenuIcon(_ editor: ExternalEditor) -> some View {
        FixedSizeAssetImage(name: editor.assetName, targetSize: menuIconSize)
    }

    var body: some View {
        TreeRowView(
            isExpandable: true,
            isExpanded: project.isExpanded,
            iconName: project.isExpanded ? "folder.fill" : "folder",
            iconColor: .accentColor,
            title: project.name,
            depth: 0,
            isSelected: false,
            onTap: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    project.isExpanded.toggle()
                }
            }
        )
        // 项目右键菜单：路径操作 → 项目操作 → 危险操作
        .contextMenu {
            // ── 路径 / 打开 ──
            if let path = projectPath {
                Button {
                    copyPathToPasteboard(path)
                } label: {
                    Label("sidebar.copyPath".localized, systemImage: "doc.on.doc")
                }
                Button {
                    openInFinder(path)
                } label: {
                    Label("sidebar.openInFinder".localized, systemImage: "folder")
                }
                Menu {
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
                Divider()
            }

            // ── 项目操作 ──
            Button {
                appState.createWorkspace(projectName: project.name)
            } label: {
                Label("sidebar.newWorkspace".localized, systemImage: "plus.square.on.square")
            }

            Divider()

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
    }
}

#if canImport(AppKit)
private func copyPathToPasteboard(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
}

private func openInFinder(_ path: String) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
}
#else
private func copyPathToPasteboard(_ path: String) {}
private func openInFinder(_ path: String) {}
#endif

// MARK: - Workspace Row

struct WorkspaceRowView: View {
    let workspace: WorkspaceModel
    let projectId: UUID
    let projectName: String
    let isSelected: Bool
    @EnvironmentObject var appState: AppState
    @State private var showDeleteConfirmation = false
    @State private var showNoAgentAlert = false

    /// 工作空间路径，用于复制与在编辑器中打开
    private var workspacePath: String? { workspace.root }

    /// 当前工作空间绑定的快捷键（基于终端打开时间自动分配）
    private var currentShortcutKey: String? {
        appState.getWorkspaceShortcutKey(workspaceKey: globalWorkspaceKey)
    }

    /// 菜单项图标尺寸
    private let menuIconSize: CGFloat = 16

    private func editorMenuIcon(_ editor: ExternalEditor) -> some View {
        FixedSizeAssetImage(name: editor.assetName, targetSize: menuIconSize)
    }

    /// 快捷键显示文本（如 "⌘1"）
    private var shortcutDisplayText: String? {
        guard let key = currentShortcutKey else { return nil }
        return "⌘\(key)"
    }

    /// 工作空间全局键，用于获取终端数量
    private var globalWorkspaceKey: String {
        return "\(projectName):\(workspace.name)"
    }

    /// 当前工作空间的终端数量
    private var terminalCount: Int {
        appState.workspaceTabs[globalWorkspaceKey]?.filter { $0.kind == .terminal }.count ?? 0
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

    /// 当前工作空间是否有活跃的后台任务
    private var hasActiveTask: Bool {
        appState.taskManager.activeTaskCount(for: globalWorkspaceKey) > 0
    }

    /// 当前工作空间是否正在删除中
    private var isDeleting: Bool {
        appState.deletingWorkspaces.contains(globalWorkspaceKey)
    }

    var body: some View {
        Group {
            if terminalCount > 0 {
                TreeRowView(
                    isExpandable: false,
                    isExpanded: false,
                    iconName: "",
                    iconColor: .clear,
                    title: workspace.name,
                    depth: 1,
                    isSelected: isSelected,
                    trailingText: shortcutDisplayText,
                    isLoading: hasActiveTask || isDeleting,
                    customIconView: terminalCountBadge,
                    onTap: {
                        if !isDeleting {
                            appState.selectWorkspace(projectId: projectId, workspaceName: workspace.name)
                        }
                    }
                )
            } else {
                TreeRowView(
                    isExpandable: false,
                    isExpanded: false,
                    iconName: "square.grid.2x2",
                    iconColor: .secondary,
                    title: workspace.name,
                    depth: 1,
                    isSelected: isSelected,
                    trailingText: shortcutDisplayText,
                    isLoading: hasActiveTask || isDeleting,
                    onTap: {
                        if !isDeleting {
                            appState.selectWorkspace(projectId: projectId, workspaceName: workspace.name)
                        }
                    }
                )
            }
        }
        .tag(workspace.name)
        // 工作空间右键菜单：删除中时不显示
        .contextMenu {
            if !isDeleting {
                // ── 路径 / 打开 ──
                if let path = workspacePath {
                    Button {
                        copyPathToPasteboard(path)
                    } label: {
                        Label("sidebar.copyPath".localized, systemImage: "doc.on.doc")
                    }
                    Button {
                        openInFinder(path)
                    } label: {
                        Label("sidebar.openInFinder".localized, systemImage: "folder")
                    }
                    Menu {
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

                Divider()

                // ── AI 操作 ──
                Button {
                    triggerAICommit()
                } label: {
                    Label("git.aiCommit".localized, systemImage: "sparkles")
                }
                .disabled(appState.clientSettings.commitAIAgent == nil)

                if !workspace.isDefault {
                    Button {
                        triggerAIMerge()
                    } label: {
                        Label("sidebar.aiMerge".localized, systemImage: "cpu")
                    }
                    .disabled(appState.clientSettings.mergeAIAgent == nil)
                }

                // ── 危险操作 ──
                if !workspace.isDefault {
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
                appState.removeWorkspace(projectName: projectName, workspaceName: workspace.name)
            }
        } message: {
            Text(String(format: "sidebar.deleteWorkspace.message".localized, workspace.name))
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
                projectName: projectName,
                workspaceName: workspace.name
            ))
        )
    }

    /// 触发 AI 智能提交（后台任务）
    private func triggerAICommit() {
        guard appState.clientSettings.commitAIAgent != nil else {
            showNoAgentAlert = true
            return
        }
        guard let path = workspacePath else { return }
        let projPath = appState.projects.first(where: { $0.name == projectName })?.path
        appState.submitBackgroundTask(
            type: .aiCommit,
            context: .aiCommit(AICommitContext(
                projectName: projectName,
                workspaceKey: workspace.name,
                workspacePath: path,
                projectPath: projPath
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
        .frame(width: 480, height: 400)
    }
}
