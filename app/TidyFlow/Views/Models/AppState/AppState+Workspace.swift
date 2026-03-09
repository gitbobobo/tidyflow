import Foundation

extension AppState {
    // MARK: - UX-1: Project/Workspace Selection

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
        // 性能追踪：工作区切换
        let projectName = WorkspaceSelectionSemantics.resolveProjectName(
            projectId: projectId,
            in: projects,
            fallback: selectedProjectName
        )
        if projects.first(where: { $0.id == projectId }) == nil {
            TFLog.app.error("selectWorkspace failed: project not found for id=\(projectId.uuidString, privacy: .public)")
        }
        let perfTraceId = performanceTracer.begin(TFPerformanceContext(
            event: .workspaceSwitch,
            project: projectName,
            workspace: workspaceName
        ))

        // 先切项目名，再切工作空间，避免同名 workspace 跨项目切换时上下文短暂错位。
        selectedProjectName = projectName
        selectedProjectId = projectId
        selectedWorkspaceKey = workspaceName
        // 选中工作空间时关闭项目配置页面
        selectedProjectForConfig = nil
        // 工作空间发生切换后，丢弃设置页临时拉取上下文，避免后续事件串台。
        clearAISelectorBootstrapContexts()
        // 切换工作空间时清理会话列表分页状态，避免旧请求残留导致界面串页。
        clearAISessionListPageStates()

        // 使用全局工作空间键（包含项目名称）来区分不同项目的同名工作空间
        guard let globalKey = currentGlobalWorkspaceKey else {
            TFLog.app.warning("Could not generate global workspace key")
            return
        }

        // 确保有默认 Tab（使用全局键）
        ensureDefaultTab(for: globalKey)

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
            requestEvolutionSnapshot(project: projectName, workspace: workspaceName)
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
}
