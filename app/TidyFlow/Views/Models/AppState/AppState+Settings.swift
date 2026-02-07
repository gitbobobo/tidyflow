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
