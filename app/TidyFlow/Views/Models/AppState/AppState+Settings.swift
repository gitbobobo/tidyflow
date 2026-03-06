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
    /// 说明：started/output/completed 的回调统一在 setupWSClient 中接线，并在这里通过 task_id 路由执行结果
    func executeProjectCommand(projectName: String, workspaceName: String, commandId: String, task: BackgroundTask) async -> ProjectCommandResult {
        return await withCheckedContinuation { continuation in
            let executionId = registerProjectCommandExecution(
                projectName: projectName,
                workspaceName: workspaceName,
                commandId: commandId,
                task: task
            ) { result in
                continuation.resume(returning: result)
            }

            TFLog.app.info("项目命令已注册执行跟踪: local=\(executionId.uuidString, privacy: .public), command=\(commandId, privacy: .public)")
            wsClient.requestRunProjectCommand(
                project: projectName,
                workspace: workspaceName,
                commandId: commandId
            )
        }
    }

    /// 提交项目命令为后台任务，或以交互式方式在终端中执行
    func runProjectCommand(projectName: String, workspaceName: String, command: ProjectCommand) {
        // 交互式命令：新建终端 Tab 执行（前台任务）
        if command.interactive {
            guard let globalKey = currentGlobalWorkspaceKey else { return }
            let customCmd = CustomCommand(
                id: command.id,
                name: command.name,
                icon: command.icon,
                command: command.command
            )
            addTerminalWithCustomCommand(workspaceKey: globalKey, command: customCmd)
            return
        }

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

    // MARK: - 项目命令事件路由（task_id）

    /// 当前工作空间诊断快照（若无则返回 empty）
    func diagnosticsSnapshot(for workspaceGlobalKey: String?) -> WorkspaceDiagnosticsSnapshot {
        guard let key = workspaceGlobalKey else { return .empty }
        return workspaceDiagnostics[key] ?? .empty
    }

    /// 处理命令 started 事件：绑定远端 task_id
    func handleProjectCommandStarted(project: String, workspace: String, commandId: String, taskId: String) {
        scheduleWorkspaceSidebarStatusRefresh(projectName: project)
        guard let executionId = resolveExecutionId(
            project: project,
            workspace: workspace,
            commandId: commandId,
            taskId: taskId
        ) else {
            // 远程任务：非本地发起，创建远程任务条目
            let key = globalWorkspaceKey(projectName: project, workspaceName: workspace)
            let commandName = resolveCommandName(project: project, commandId: commandId)
            let commandIcon = resolveCommandIcon(project: project, commandId: commandId)
            let task = BackgroundTask(
                type: .projectCommand,
                context: .projectCommand(ProjectCommandContext(
                    projectName: project,
                    workspaceName: workspace,
                    commandId: commandId,
                    commandName: commandName,
                    commandIcon: commandIcon,
                    blocking: false
                )),
                workspaceGlobalKey: key
            )
            task.remoteTaskId = taskId
            taskManager.insertRemoteRunningTask(task)
            remoteProjectCommandTasks[taskId] = task
            TFLog.app.info("远程项目命令 started: \(project, privacy: .public)/\(workspace, privacy: .public)/\(commandId, privacy: .public)")
            return
        }

        if let execution = projectCommandExecutions[executionId] {
            execution.remoteTaskId = taskId
            execution.task?.remoteTaskId = taskId
        }
    }

    /// 处理命令输出事件：仅刷新最后一行
    func handleProjectCommandOutput(taskId: String, line: String) {
        // 本地任务
        if let executionId = projectCommandExecutionIdByRemoteTaskId[taskId],
           let execution = projectCommandExecutions[executionId] {
            execution.task?.lastOutputLine = line
            return
        }
        // 远程任务
        if let task = remoteProjectCommandTasks[taskId] {
            task.lastOutputLine = line
        }
    }

    /// 处理命令完成事件：回传结果并清理路由映射
    func handleProjectCommandCompleted(
        project: String,
        workspace: String,
        commandId: String,
        taskId: String,
        ok: Bool,
        message: String?
    ) {
        scheduleWorkspaceSidebarStatusRefresh(projectName: project)
        // 本地任务
        if let executionId = resolveExecutionId(
            project: project,
            workspace: workspace,
            commandId: commandId,
            taskId: taskId
        ), let execution = projectCommandExecutions[executionId] {
            execution.complete(ProjectCommandResult(ok: ok, message: message ?? ""))
            cleanupProjectCommandExecution(executionId)
            return
        }

        // 远程任务
        if let task = remoteProjectCommandTasks.removeValue(forKey: taskId) {
            let result = BackgroundTaskResult.projectCommand(ProjectCommandResult(ok: ok, message: message ?? ""))
            taskManager.completeRemoteTask(task, result: result, appState: self)
            TFLog.app.info("远程项目命令 completed: \(project, privacy: .public)/\(workspace, privacy: .public)/\(commandId, privacy: .public)")
        }
    }

    /// 处理命令取消事件：用于刷新侧边栏状态。
    func handleProjectCommandCancelled(project: String, workspace _: String, commandId _: String, taskId _: String) {
        scheduleWorkspaceSidebarStatusRefresh(projectName: project)
    }

    private func registerProjectCommandExecution(
        projectName: String,
        workspaceName: String,
        commandId: String,
        task: BackgroundTask,
        onComplete: @escaping (ProjectCommandResult) -> Void
    ) -> UUID {
        let executionId = UUID()
        let globalKey = globalWorkspaceKey(projectName: projectName, workspaceName: workspaceName)
        let key = projectCommandRoutingKey(project: projectName, workspace: workspaceName, commandId: commandId)
        let state = ProjectCommandExecutionState(
            localExecutionId: executionId,
            projectName: projectName,
            workspaceName: workspaceName,
            commandId: commandId,
            workspaceGlobalKey: globalKey,
            task: task,
            onComplete: onComplete
        )

        projectCommandExecutions[executionId] = state
        if pendingProjectCommandExecutionIdsByKey[key] == nil {
            pendingProjectCommandExecutionIdsByKey[key] = []
        }
        pendingProjectCommandExecutionIdsByKey[key]?.append(executionId)
        return executionId
    }

    private func resolveExecutionId(
        project: String,
        workspace: String,
        commandId: String,
        taskId: String
    ) -> UUID? {
        if let mapped = projectCommandExecutionIdByRemoteTaskId[taskId] {
            return mapped
        }

        let key = projectCommandRoutingKey(project: project, workspace: workspace, commandId: commandId)
        guard var queue = pendingProjectCommandExecutionIdsByKey[key], !queue.isEmpty else {
            return nil
        }
        let executionId = queue.removeFirst()
        pendingProjectCommandExecutionIdsByKey[key] = queue.isEmpty ? nil : queue
        projectCommandExecutionIdByRemoteTaskId[taskId] = executionId
        projectCommandExecutions[executionId]?.remoteTaskId = taskId
        projectCommandExecutions[executionId]?.task?.remoteTaskId = taskId
        return executionId
    }

    private func cleanupProjectCommandExecution(_ executionId: UUID) {
        guard let execution = projectCommandExecutions[executionId] else { return }
        let key = projectCommandRoutingKey(
            project: execution.projectName,
            workspace: execution.workspaceName,
            commandId: execution.commandId
        )

        if var queue = pendingProjectCommandExecutionIdsByKey[key] {
            queue.removeAll { $0 == executionId }
            pendingProjectCommandExecutionIdsByKey[key] = queue.isEmpty ? nil : queue
        }

        if let taskId = execution.remoteTaskId {
            projectCommandExecutionIdByRemoteTaskId.removeValue(forKey: taskId)
        }

        projectCommandExecutions.removeValue(forKey: executionId)
    }

    private func projectCommandRoutingKey(project: String, workspace: String, commandId: String) -> String {
        "\(project)|\(workspace)|\(commandId)"
    }

    /// 从项目配置中查找命令名称
    private func resolveCommandName(project: String, commandId: String) -> String {
        projects.first(where: { $0.name == project })?
            .commands.first(where: { $0.id == commandId })?
            .name ?? commandId
    }

    /// 从项目配置中查找命令图标
    private func resolveCommandIcon(project: String, commandId: String) -> String {
        projects.first(where: { $0.name == project })?
            .commands.first(where: { $0.id == commandId })?
            .icon ?? "terminal"
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

// MARK: - Evolution 全局默认配置持久化

extension AppState {
    private static let evolutionDefaultProfilesKeyV2 = "evolution_default_profiles_v2"
    private static let evolutionDefaultProfilesKeyV1 = "evolution_default_profiles_v1"

    private static func evolutionStageOrder() -> [String] {
        [
            "direction",
            "plan",
            "implement_general",
            "implement_visual",
            "implement_advanced",
            "verify",
            "auto_commit",
        ]
    }

    private static func expandLegacyEvolutionStages(_ stage: String) -> [String] {
        let normalized = stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "implement" {
            return ["implement_general", "implement_visual"]
        }
        return [normalized]
    }

    static func normalizedEvolutionEditableProfiles(
        _ profiles: [EvolutionEditableProfile]
    ) -> [EvolutionEditableProfile] {
        if profiles.isEmpty {
            return defaultEvolutionEditableProfiles()
        }

        let validStages = Set(evolutionStageOrder())
        var byStage: [String: EvolutionEditableProfile] = [:]
        for profile in profiles {
            let mappedStages = expandLegacyEvolutionStages(profile.stage)
            for stage in mappedStages where validStages.contains(stage) {
                if byStage[stage] != nil { continue }
                byStage[stage] = EvolutionEditableProfile(
                    id: stage,
                    stage: stage,
                    aiTool: profile.aiTool,
                    mode: profile.mode,
                    providerID: profile.providerID,
                    modelID: profile.modelID,
                    configOptions: profile.configOptions
                )
            }
        }

        return defaultEvolutionEditableProfiles().map { item in
            byStage[item.stage] ?? item
        }
    }

    /// 从 UserDefaults 加载 Evolution 全局默认配置
    func loadEvolutionDefaultProfiles() {
        if let data = UserDefaults.standard.data(forKey: Self.evolutionDefaultProfilesKeyV2),
           let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let loaded = jsonArray.compactMap { dict -> EvolutionEditableProfile? in
                guard let id = dict["id"] as? String,
                      let stage = dict["stage"] as? String,
                      let aiToolRaw = dict["aiTool"] as? String,
                      let aiTool = AIChatTool(rawValue: aiToolRaw) else { return nil }
                let configOptions = dict["configOptions"] as? [String: Any] ?? [:]
                return EvolutionEditableProfile(
                    id: id,
                    stage: stage,
                    aiTool: aiTool,
                    mode: dict["mode"] as? String ?? "",
                    providerID: dict["providerID"] as? String ?? "",
                    modelID: dict["modelID"] as? String ?? "",
                    configOptions: configOptions
                )
            }
            if !loaded.isEmpty {
                evolutionDefaultProfiles = Self.normalizedEvolutionEditableProfiles(loaded)
                return
            }
        }
        // 兼容旧版本 v1：自动迁移并落盘到 v2
        if let data = UserDefaults.standard.data(forKey: Self.evolutionDefaultProfilesKeyV1),
           let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let loaded = jsonArray.compactMap { dict -> EvolutionEditableProfile? in
                guard let id = dict["id"] as? String,
                      let stage = dict["stage"] as? String,
                      let aiToolRaw = dict["aiTool"] as? String,
                      let aiTool = AIChatTool(rawValue: aiToolRaw) else { return nil }
                return EvolutionEditableProfile(
                    id: id,
                    stage: stage,
                    aiTool: aiTool,
                    mode: dict["mode"] as? String ?? "",
                    providerID: dict["providerID"] as? String ?? "",
                    modelID: dict["modelID"] as? String ?? "",
                    configOptions: [:]
                )
            }
            if !loaded.isEmpty {
                let normalized = Self.normalizedEvolutionEditableProfiles(loaded)
                evolutionDefaultProfiles = normalized
                saveEvolutionDefaultProfiles(normalized)
                return
            }
        }
        // 尚未配置：用默认结果初始化
        evolutionDefaultProfiles = AppState.defaultEvolutionEditableProfiles()
    }

    /// 保存 Evolution 全局默认配置到 UserDefaults
    func saveEvolutionDefaultProfiles(_ profiles: [EvolutionEditableProfile]) {
        let normalized = Self.normalizedEvolutionEditableProfiles(profiles)
        evolutionDefaultProfiles = normalized
        let jsonArray: [[String: Any]] = normalized.map { profile in
            [
                "id": profile.id,
                "stage": profile.stage,
                "aiTool": profile.aiTool.rawValue,
                "mode": profile.mode,
                "providerID": profile.providerID,
                "modelID": profile.modelID,
                "configOptions": profile.configOptions
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: jsonArray) {
            UserDefaults.standard.set(data, forKey: Self.evolutionDefaultProfilesKeyV2)
        }
    }

    // MARK: - 工作空间待办

    func workspaceTodos(for workspaceKey: String?) -> [WorkspaceTodoItem] {
        guard let workspaceKey, !workspaceKey.isEmpty else { return [] }
        return WorkspaceTodoStore.items(for: workspaceKey, in: clientSettings.workspaceTodos)
    }

    func pendingTodoCount(for workspaceKey: String?) -> Int {
        guard let workspaceKey, !workspaceKey.isEmpty else { return 0 }
        return WorkspaceTodoStore.pendingCount(for: workspaceKey, in: clientSettings.workspaceTodos)
    }

    @discardableResult
    func addWorkspaceTodo(
        workspaceKey: String,
        title: String,
        note: String?,
        status: WorkspaceTodoStatus = .pending
    ) -> WorkspaceTodoItem? {
        var storage = clientSettings.workspaceTodos
        let created = WorkspaceTodoStore.add(
            workspaceKey: workspaceKey,
            title: title,
            note: note,
            status: status,
            storage: &storage
        )
        guard created != nil else { return nil }
        clientSettings.workspaceTodos = storage
        saveClientSettings()
        return created
    }

    @discardableResult
    func updateWorkspaceTodo(
        workspaceKey: String,
        todoID: String,
        title: String,
        note: String?
    ) -> Bool {
        var storage = clientSettings.workspaceTodos
        let updated = WorkspaceTodoStore.update(
            workspaceKey: workspaceKey,
            todoID: todoID,
            title: title,
            note: note,
            storage: &storage
        )
        guard updated else { return false }
        clientSettings.workspaceTodos = storage
        saveClientSettings()
        return true
    }

    @discardableResult
    func deleteWorkspaceTodo(workspaceKey: String, todoID: String) -> Bool {
        var storage = clientSettings.workspaceTodos
        let removed = WorkspaceTodoStore.remove(
            workspaceKey: workspaceKey,
            todoID: todoID,
            storage: &storage
        )
        guard removed else { return false }
        clientSettings.workspaceTodos = storage
        saveClientSettings()
        return true
    }

    @discardableResult
    func setWorkspaceTodoStatus(
        workspaceKey: String,
        todoID: String,
        status: WorkspaceTodoStatus
    ) -> Bool {
        var storage = clientSettings.workspaceTodos
        let changed = WorkspaceTodoStore.setStatus(
            workspaceKey: workspaceKey,
            todoID: todoID,
            status: status,
            storage: &storage
        )
        guard changed else { return false }
        clientSettings.workspaceTodos = storage
        saveClientSettings()
        return true
    }

    func moveWorkspaceTodos(
        workspaceKey: String,
        status: WorkspaceTodoStatus,
        fromOffsets: IndexSet,
        toOffset: Int
    ) {
        var storage = clientSettings.workspaceTodos
        WorkspaceTodoStore.move(
            workspaceKey: workspaceKey,
            status: status,
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            storage: &storage
        )
        clientSettings.workspaceTodos = storage
        saveClientSettings()
    }

    /// 生成默认的每个 Stage EvolutionEditableProfile
    static func defaultEvolutionEditableProfiles() -> [EvolutionEditableProfile] {
        evolutionStageOrder().map { stage in
            EvolutionEditableProfile(id: stage, stage: stage, aiTool: .codex, mode: "", providerID: "", modelID: "")
        }
    }
}
