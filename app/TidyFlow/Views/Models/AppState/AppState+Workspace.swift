import Foundation

extension AppState {
    // MARK: - UX-1: Project/Workspace Selection

    /// Select a workspace within a project
    func selectWorkspace(projectId: UUID, workspaceName: String) {
        selectedProjectId = projectId
        selectedWorkspaceKey = workspaceName
        
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
}
