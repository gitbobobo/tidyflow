import Foundation
#if os(macOS)
import CoreGraphics
#endif

#if os(macOS)
/// macOS 工作区壳层布局快照。
/// 仅覆盖工作区外层布局，不包含聊天内部抽屉、搜索词、滚动位置等瞬时态。
struct MacWorkspaceLayoutState: Equatable {
    var rightSidebarCollapsed: Bool
    var activeRightTool: RightTool?
    var tabPanelExpanded: Bool
    var tabPanelHeight: CGFloat
    var tabPanelLastExpandedHeight: CGFloat?

    static let `default` = MacWorkspaceLayoutState(
        rightSidebarCollapsed: false,
        activeRightTool: .explorer,
        tabPanelExpanded: false,
        tabPanelHeight: 0,
        tabPanelLastExpandedHeight: nil
    )
}

extension AppState {
    var activeRightTool: RightTool? {
        get { currentMacWorkspaceLayoutState.activeRightTool }
        set {
            updateCurrentWorkspaceLayout { layout in
                layout.activeRightTool = newValue
            }
        }
    }

    var rightSidebarCollapsed: Bool {
        get { currentMacWorkspaceLayoutState.rightSidebarCollapsed }
        set {
            updateCurrentWorkspaceLayout { layout in
                layout.rightSidebarCollapsed = newValue
            }
        }
    }

    /// Tab 面板是否展开（false 时仅显示底部收起的 Tab 条）。
    var tabPanelExpanded: Bool {
        get { currentMacWorkspaceLayoutState.tabPanelExpanded }
        set {
            updateCurrentWorkspaceLayout { layout in
                layout.tabPanelExpanded = newValue
            }
        }
    }

    /// Tab 面板展开时的高度（会话内记忆，不持久化）。
    var tabPanelHeight: CGFloat {
        get { currentMacWorkspaceLayoutState.tabPanelHeight }
        set {
            updateCurrentWorkspaceLayout { layout in
                layout.tabPanelHeight = newValue
            }
        }
    }

    /// 最近一次有效展开高度，用于收起后恢复。
    var tabPanelLastExpandedHeight: CGFloat? {
        get { currentMacWorkspaceLayoutState.tabPanelLastExpandedHeight }
        set {
            updateCurrentWorkspaceLayout { layout in
                layout.tabPanelLastExpandedHeight = newValue
            }
        }
    }

    var currentMacWorkspaceLayoutState: MacWorkspaceLayoutState {
        macWorkspaceLayout(for: currentGlobalWorkspaceKey)
    }

    func storedMacWorkspaceLayout(for workspaceKey: String) -> MacWorkspaceLayoutState? {
        workspaceLayoutByWorkspace[workspaceKey]
    }

    func saveCurrentWorkspaceLayout(for workspaceKey: String? = nil) {
        let workspaceKey = workspaceKey ?? currentGlobalWorkspaceKey
        guard workspaceKey != nil else { return }
        storeMacWorkspaceLayout(
            currentMacWorkspaceLayoutState,
            for: workspaceKey
        )
    }

    func restoreWorkspaceLayout(for workspaceKey: String) {
        let layout = workspaceLayoutByWorkspace[workspaceKey] ?? .default
        applyMacWorkspaceLayout(layout, for: workspaceKey)
    }

    func applyDefaultWorkspaceLayout() {
        applyMacWorkspaceLayout(.default, for: currentGlobalWorkspaceKey)
    }

    func clearWorkspaceLayout(for workspaceKey: String) {
        workspaceLayoutByWorkspace.removeValue(forKey: workspaceKey)
    }

    func clearProjectWorkspaceLayouts(projectName: String, workspaceNames: [String]) {
        for workspaceName in workspaceNames {
            let globalKey = globalWorkspaceKey(projectName: projectName, workspaceName: workspaceName)
            workspaceLayoutByWorkspace.removeValue(forKey: globalKey)
        }
    }

    private func updateCurrentWorkspaceLayout(
        _ update: (inout MacWorkspaceLayoutState) -> Void
    ) {
        var layout = currentMacWorkspaceLayoutState
        let previous = layout
        update(&layout)
        guard layout != previous else { return }
        objectWillChange.send()
        storeMacWorkspaceLayout(layout, for: currentGlobalWorkspaceKey)
    }

    private func applyMacWorkspaceLayout(
        _ layout: MacWorkspaceLayoutState,
        for workspaceKey: String?
    ) {
        guard macWorkspaceLayout(for: workspaceKey) != layout else { return }
        objectWillChange.send()
        storeMacWorkspaceLayout(layout, for: workspaceKey)
    }

    private func macWorkspaceLayout(for workspaceKey: String?) -> MacWorkspaceLayoutState {
        if let workspaceKey {
            return workspaceLayoutByWorkspace[workspaceKey] ?? .default
        }
        return inactiveWorkspaceLayout
    }

    private func storeMacWorkspaceLayout(
        _ layout: MacWorkspaceLayoutState,
        for workspaceKey: String?
    ) {
        if let workspaceKey {
            workspaceLayoutByWorkspace[workspaceKey] = layout
        } else {
            inactiveWorkspaceLayout = layout
        }
    }
}
#endif

extension AppState {
    // MARK: - UX-1: Project/Workspace Selection

    func defaultWorkspace(for project: ProjectModel) -> WorkspaceModel? {
        WorkspaceSelectionSemantics.defaultWorkspace(project.workspaces, nameExtractor: \.name)
    }

    func sidebarVisibleWorkspaces(for project: ProjectModel) -> [WorkspaceModel] {
        WorkspaceSelectionSemantics.sidebarVisibleWorkspaces(project.workspaces, nameExtractor: \.name)
    }

    func selectProjectDefaultWorkspace(_ project: ProjectModel) {
        guard let workspace = defaultWorkspace(for: project) ?? project.workspaces.first else { return }
        selectWorkspace(projectId: project.id, workspaceName: workspace.name)
    }

    func isSelectedProjectDefaultWorkspace(_ project: ProjectModel) -> Bool {
        guard let workspace = defaultWorkspace(for: project) ?? project.workspaces.first else { return false }
        return selectedProjectId == project.id && selectedWorkspaceKey == workspace.name
    }

    /// 当前选中的工作区身份标识（共享语义层）。
    /// 由 `selectedProjectId`、`selectedProjectName`、`selectedWorkspaceKey` 派生，
    /// 视图层与业务逻辑统一通过此属性获取当前工作区上下文，不再各自拼装。
    var selectedWorkspaceIdentity: WorkspaceIdentity? {
        guard let projectId = selectedProjectId,
              let workspaceName = selectedWorkspaceKey else { return nil }
        return WorkspaceIdentity(
            projectId: projectId,
            projectName: selectedProjectName,
            workspaceName: workspaceName
        )
    }

    /// Select a workspace within a project
    func selectWorkspace(projectId: UUID, workspaceName: String) {
        let previousIdentity = selectedWorkspaceIdentity
        #if os(macOS)
        let previousGlobalKey = previousIdentity.map {
            globalWorkspaceKey(projectName: $0.projectName, workspaceName: $0.workspaceName)
        }
        #endif
        // 性能追踪：工作区切换
        let projectName = WorkspaceSelectionSemantics.resolveProjectName(
            projectId: projectId,
            in: projects,
            fallback: selectedProjectName
        )
        let nextIdentity = WorkspaceIdentity(
            projectId: projectId,
            projectName: projectName,
            workspaceName: workspaceName
        )
        let didChangeWorkspaceIdentity = previousIdentity != nextIdentity
        if projects.first(where: { $0.id == projectId }) == nil {
            TFLog.app.error("selectWorkspace failed: project not found for id=\(projectId.uuidString, privacy: .public)")
        }
        let perfTraceId = performanceTracer.begin(TFPerformanceContext(
            event: .workspaceSwitch,
            project: projectName,
            workspace: workspaceName
        ))

        #if os(macOS)
        if didChangeWorkspaceIdentity, let previousGlobalKey {
            saveCurrentWorkspaceLayout(for: previousGlobalKey)
        }
        #endif

        // 先切项目名，再切工作空间，避免同名 workspace 跨项目切换时上下文短暂错位。
        selectedProjectName = projectName
        selectedProjectId = projectId
        selectedWorkspaceKey = workspaceName

        // 同步更新共享状态机，保证双端状态机语义一致。
        workspaceViewStateMachine.apply(.select(
            projectName: projectName,
            workspaceName: workspaceName,
            projectId: projectId
        ))
        if didChangeWorkspaceIdentity {
            // 工作区真实切换时，重置旧工作区的文件相位，新相位将在 watch_subscribed 事件到达时设置
            if let prevId = previousIdentity {
                let prevKey = globalWorkspaceKey(projectName: prevId.projectName, workspaceName: prevId.workspaceName)
                fileCache.onWatchUnsubscribed(globalKey: prevKey)
            }
            // 工作区真实切换时，强制重置 AI 聊天舞台，防止旧工作区的 active/resuming 投影到新上下文
            forceResetAIChatStage()
            // 工作区真实切换时，清理旧上下文终端生命周期投影，
            // 确保新工作区不会收到旧终端的迟到事件
            terminalSessionStore.forceResetAllLifecycles()
            // 工作空间发生切换后，丢弃设置页临时拉取上下文，避免后续事件串台。
            clearAISelectorBootstrapContexts()
            // 仅在真实切换到其他项目/工作区时清理会话分页，避免重复点击当前项目把右侧列表清空。
            clearAISessionListPageStates()
        }

        // 使用全局工作空间键（包含项目名称）来区分不同项目的同名工作空间
        guard let globalKey = currentGlobalWorkspaceKey else {
            TFLog.app.warning("Could not generate global workspace key")
            return
        }

        // 确保有默认 Tab（使用全局键）
        ensureDefaultTab(for: globalKey)

        #if os(macOS)
        if didChangeWorkspaceIdentity {
            restoreWorkspaceLayout(for: globalKey)
        }
        #endif

        // 连接后请求数据（使用原始 workspaceName，因为 fetchXXX 方法内部会用 selectedProjectName 构建完整键）
        // 切换项目但 workspace 名相同时（如 A-default → B-default）selectedWorkspaceKey 不变，onChange 不触发，
        // Git 面板的 loadDataIfNeeded 不会执行，因此这里一并请求分支与提交历史，保证切换后 Git 面板有数据。
        if connectionState == .connected {
            // 订阅文件监控（切换工作空间时自动切换监控目标）
            subscribeCurrentWorkspace()

            // 每次切换都请求最新数据（保留旧缓存先显示，新数据返回后自动刷新 UI）
            fetchFileList(workspaceKey: workspaceName, path: ".")
            gitCache.fetchGitStatus(workspaceKey: workspaceName)
            gitCache.fetchGitBranches(workspaceKey: workspaceName)
            gitCache.fetchGitLog(workspaceKey: workspaceName)
            // 预热自主进化面板数据，避免首次切换到页面时才开始补拉历史。
            requestEvolutionSnapshot()
            requestEvolutionCycleHistory(project: projectName, workspace: workspaceName)

        }

        // 切换到此工作空间后清除侧边栏“任务完成”铃铛提示
        taskManager.clearUnseenCompletion(for: globalKey)

        // 性能追踪：工作区切换结束
        performanceTracer.end(perfTraceId)
    }

    /// 生成全局唯一的工作空间键（包含项目名称）
    /// 用于所有需要区分不同项目同名工作空间的缓存
    func globalWorkspaceKey(projectName: String, workspaceName: String) -> String {
        return WorkspaceKeySemantics.globalKey(project: projectName, workspace: workspaceName)
    }
    
    /// 获取当前选中的全局工作空间键
    var currentGlobalWorkspaceKey: String? {
        guard let workspaceName = selectedWorkspaceKey else {
            return nil
        }
        return globalWorkspaceKey(projectName: selectedProjectName, workspaceName: workspaceName)
    }

    /// Refresh projects and workspaces from Core
    func refreshProjectsAndWorkspaces() {
        wsClient.requestListProjects()
    }

    /// 获取当前选中工作空间的根目录路径
    var selectedWorkspacePath: String? {
        guard let projectId = selectedProjectId,
              let workspaceKey = selectedWorkspaceKey,
              let project = projects.first(where: { $0.id == projectId }),
              let workspace = project.workspaces.first(where: { $0.name == workspaceKey }) else {
            return nil
        }
        return workspace.root
    }

    /// 防抖刷新指定项目的工作空间列表（由 Rust Core 统一计算侧边栏状态）。
    func scheduleWorkspaceSidebarStatusRefresh(projectName: String, debounce: TimeInterval = 0.15) {
        let normalizedProject = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProject.isEmpty, connectionState == .connected else { return }

        workspaceSidebarStatusRefreshWorkItemByProject[normalizedProject]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.connectionState == .connected else { return }
            self.wsClient.requestListWorkspaces(project: normalizedProject)
            self.workspaceSidebarStatusRefreshWorkItemByProject.removeValue(forKey: normalizedProject)
        }
        workspaceSidebarStatusRefreshWorkItemByProject[normalizedProject] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: workItem)
    }

    /// 批量防抖刷新多个项目的工作空间侧边栏状态。
    func scheduleWorkspaceSidebarStatusRefresh<S: Sequence>(projectNames: S, debounce: TimeInterval = 0.15)
    where S.Element == String {
        let uniqueProjects = Set(projectNames.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        for project in uniqueProjects {
            scheduleWorkspaceSidebarStatusRefresh(projectName: project, debounce: debounce)
        }
    }

    func hasWorkspaceStreamingChat(project: String, workspace: String) -> Bool {
        let prefix = "\(project)::\(workspace)::"
        for tool in AIChatTool.allCases {
            if let statuses = aiSessionStatusesByTool[tool],
               statuses.contains(where: { $0.key.hasPrefix(prefix) && $0.value.isActive }) {
                return true
            }
        }
        return false
    }

    func workspaceAIStatus(project: String, workspace: String) -> AISessionStatusSnapshot? {
        let prefix = "\(project)::\(workspace)::"
        var snapshots: [AISessionStatusSnapshot] = []
        for tool in AIChatTool.allCases {
            if let statuses = aiSessionStatusesByTool[tool] {
                snapshots.append(contentsOf: statuses
                    .filter { $0.key.hasPrefix(prefix) }
                    .map(\.value))
            }
        }
        guard !snapshots.isEmpty else { return nil }
        if let active = snapshots.first(where: { $0.isActive }) { return active }
        if let failure = snapshots.first(where: { $0.isError }) { return failure }
        if let success = snapshots.first(where: { $0.normalizedStatus == "success" }) { return success }
        if let cancelled = snapshots.first(where: { $0.normalizedStatus == "cancelled" }) { return cancelled }
        return snapshots.first
    }

    func hasWorkspaceActiveEvolutionLoop(project: String, workspace: String) -> Bool {
        guard let item = evolutionItem(project: project, workspace: workspace) else { return false }
        let status = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["queued", "running", "pending", "in_progress", "processing"].contains(status)
    }

    func activeTaskIconForWorkspace(project: String, workspace: String) -> String? {
        let key = globalWorkspaceKey(projectName: project, workspaceName: workspace)
        return taskManager.taskStore.sidebarActiveIconName(for: key)
    }
}
