import Foundation

extension AppState {
    // MARK: - 设置页面

    /// 从服务端加载客户端设置
    func loadClientSettings() {
        wsClient.requestGetClientSettings()
    }

    /// 保存客户端设置到服务端
    func saveClientSettings() {
        wsClient.requestSaveClientSettings(settings: clientSettings)
    }

    /// 添加自定义命令
    func addCustomCommand(_ command: CustomCommand) {
        clientSettings.customCommands.append(command)
        saveClientSettings()
    }

    /// 更新自定义命令
    func updateCustomCommand(_ command: CustomCommand) {
        if let index = clientSettings.customCommands.firstIndex(where: { $0.id == command.id }) {
            clientSettings.customCommands[index] = command
            saveClientSettings()
        }
    }

    /// 删除自定义命令
    func deleteCustomCommand(id: String) {
        clientSettings.customCommands.removeAll { $0.id == id }
        saveClientSettings()
    }

    // MARK: - 项目命令管理

    /// 保存项目命令配置
    func saveProjectCommands(projectName: String) {
        guard let project = projects.first(where: { $0.name == projectName }) else { return }
        wsClient.requestSaveProjectCommands(project: projectName, commands: project.commands)
    }

    /// 添加项目命令
    func addProjectCommand(projectName: String, _ command: ProjectCommand) {
        if let index = projects.firstIndex(where: { $0.name == projectName }) {
            projects[index].commands.append(command)
            saveProjectCommands(projectName: projectName)
        }
    }

    /// 更新项目命令
    func updateProjectCommand(projectName: String, _ command: ProjectCommand) {
        if let pIndex = projects.firstIndex(where: { $0.name == projectName }),
           let cIndex = projects[pIndex].commands.firstIndex(where: { $0.id == command.id }) {
            projects[pIndex].commands[cIndex] = command
            saveProjectCommands(projectName: projectName)
        }
    }

    /// 删除项目命令
    func deleteProjectCommand(projectName: String, commandId: String) {
        if let index = projects.firstIndex(where: { $0.name == projectName }) {
            projects[index].commands.removeAll { $0.id == commandId }
            saveProjectCommands(projectName: projectName)
        }
    }

    /// 执行项目命令（通过 WebSocket 发送到 Core）
    func executeProjectCommand(projectName: String, workspaceName: String, commandId: String, task: BackgroundTask) async -> ProjectCommandResult {
        return await withCheckedContinuation { continuation in
            // 注册实时输出回调：根据 taskId 更新对应 BackgroundTask 的 lastOutputLine
            wsClient.onProjectCommandOutput = { [weak task] taskId, line in
                guard let task = task else { return }
                if task.remoteTaskId == taskId {
                    DispatchQueue.main.async {
                        task.lastOutputLine = line
                    }
                }
            }
            // 注册开始回调：记录 Rust 分配的 remoteTaskId
            // 注意：必须同步设置 remoteTaskId（不走 DispatchQueue.main.async），
            // 否则后续 output 回调在同一线程上检查 remoteTaskId 时会因主线程延迟而匹配失败
            wsClient.onProjectCommandStarted = { [weak task] project, workspace, cmdId, taskId in
                guard let task = task else { return }
                if project == projectName && cmdId == commandId {
                    task.remoteTaskId = taskId
                }
            }
            // 注册完成回调
            wsClient.onProjectCommandCompleted = { project, workspace, cmdId, taskId, ok, message in
                if project == projectName && cmdId == commandId {
                    continuation.resume(returning: ProjectCommandResult(ok: ok, message: message ?? ""))
                }
            }
            wsClient.requestRunProjectCommand(
                project: projectName,
                workspace: workspaceName,
                commandId: commandId
            )
        }
    }

    /// 提交项目命令为后台任务
    func runProjectCommand(projectName: String, workspaceName: String, command: ProjectCommand) {
        submitBackgroundTask(
            type: .projectCommand,
            context: .projectCommand(ProjectCommandContext(
                projectName: projectName,
                workspaceName: workspaceName,
                commandId: command.id,
                commandName: command.name,
                commandIcon: command.icon,
                blocking: command.blocking
            ))
        )
    }
    
    // MARK: - 自动工作空间快捷键

    /// 获取按终端打开时间排序的工作空间快捷键映射
    /// 最早打开终端的工作空间获得 ⌘1，依次类推
    var autoWorkspaceShortcuts: [String: String] {
        let sortedWorkspaces = workspaceTerminalOpenTime
            .sorted { $0.value < $1.value }
            .prefix(9)

        let shortcutKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
        var result: [String: String] = [:]
        for (index, (workspaceKey, _)) in sortedWorkspaces.enumerated() {
            result[shortcutKeys[index]] = workspaceKey
        }
        return result
    }

    /// 获取工作空间的快捷键（基于终端打开时间自动分配）
    /// - Parameter workspaceKey: 工作空间标识
    /// - Returns: 快捷键数字 "1"-"9" 或 "0"，如果没有打开终端则返回 nil
    func getWorkspaceShortcutKey(workspaceKey: String) -> String? {
        // 将 "project/workspace" 格式转换为 "project:workspace"
        let globalKey: String
        if workspaceKey.contains(":") {
            globalKey = workspaceKey
        } else {
            let components = workspaceKey.split(separator: "/", maxSplits: 1)
            if components.count == 2 {
                var wsName = String(components[1])
                if wsName == "(default)" { wsName = "default" }
                globalKey = "\(components[0]):\(wsName)"
            } else {
                globalKey = workspaceKey
            }
        }

        for (shortcutKey, wsKey) in autoWorkspaceShortcuts {
            if wsKey == globalKey {
                return shortcutKey
            }
        }
        return nil
    }

    /// 根据快捷键切换工作空间
    /// - Parameter shortcutKey: 快捷键数字 "1"-"9"
    func switchToWorkspaceByShortcut(shortcutKey: String) {
        guard let workspaceKey = autoWorkspaceShortcuts[shortcutKey] else {
            return
        }

        // workspaceKey 格式为 "projectName:workspaceName"
        let components = workspaceKey.split(separator: ":", maxSplits: 1)
        guard components.count == 2 else { return }

        let projectName = String(components[0])
        let workspaceName = String(components[1])

        guard let project = projects.first(where: { $0.name == projectName }) else {
            return
        }

        selectWorkspace(projectId: project.id, workspaceName: workspaceName)
    }
}
