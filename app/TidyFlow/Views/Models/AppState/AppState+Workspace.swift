import Foundation

extension AppState {
    // MARK: - UX-1: Project/Workspace Selection

    /// Select a workspace within a project
    func selectWorkspace(projectId: UUID, workspaceName: String) {
        selectedProjectId = projectId
        selectedWorkspaceKey = workspaceName
        // 选中工作空间时关闭项目配置页面
        selectedProjectForConfig = nil
        // 工作空间发生切换后，丢弃设置页临时拉取上下文，避免后续事件串台。
        clearAISelectorBootstrapContexts()
        
        // Update selectedProjectName for WS protocol
        // 注意：使用原始项目名称，不进行格式转换，因为服务端使用原始名称索引项目
        if let project = projects.first(where: { $0.id == projectId }) {
            selectedProjectName = project.name
        }
        
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

        }

        // 切换到此工作空间后清除侧边栏“任务完成”铃铛提示
        taskManager.clearUnseenCompletion(for: globalKey)
    }
    
    /// 生成全局唯一的工作空间键（包含项目名称）
    /// 用于所有需要区分不同项目同名工作空间的缓存
    func globalWorkspaceKey(projectName: String, workspaceName: String) -> String {
        return "\(projectName):\(workspaceName)"
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

    /// 指定工作空间是否存在流式聊天活动（会话 busy 或当前本地流式态）。
    func hasWorkspaceStreamingChat(projectName: String, workspaceName: String) -> Bool {
        let project = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !workspace.isEmpty else { return false }

        let prefix = "\(project)::\(workspace)::"
        for tool in AIChatTool.allCases {
            if let statuses = aiSessionStatusesByTool[tool],
               statuses.contains(where: { $0.key.hasPrefix(prefix) && $0.value.isBusy }) {
                return true
            }
        }

        if selectedProjectName == project, selectedWorkspaceKey == workspace {
            for tool in AIChatTool.allCases {
                let store = aiStore(for: tool)
                if store.isStreaming || store.awaitingUserEcho {
                    return true
                }
            }
        }
        return false
    }

    /// 指定工作空间是否处于自主进化循环活跃状态。
    func hasWorkspaceActiveEvolutionLoop(projectName: String, workspaceName: String) -> Bool {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspaceName)
        guard let item = evolutionItem(project: projectName, workspace: normalizedWorkspace) else {
            return false
        }
        let status = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["queued", "running", "pending", "in_progress", "processing"].contains(status)
    }

    /// 指定工作空间当前用于侧边栏展示的后台任务图标。
    func workspaceActiveTaskIconName(projectName: String, workspaceName: String) -> String? {
        let key = globalWorkspaceKey(projectName: projectName, workspaceName: workspaceName)
        return taskManager.sidebarActiveTaskIconName(for: key)
    }
}
