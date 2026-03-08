import Foundation
import TidyFlowShared

// MARK: - 领域消息处理方法（从 setupWSCallbacks 闭包迁移）
// 适配器类转发到此处的实例方法，保持业务逻辑集中。

extension MobileAppState {

    // MARK: - Git

    func handleGitStatusResult(_ result: GitStatusResult) {
        let key = globalWorkspaceKey(project: result.project, workspace: result.workspace)
        var detail = workspaceGitDetailState[key] ?? MobileWorkspaceGitDetailState.empty()
        detail.currentBranch = result.currentBranch
        detail.defaultBranch = result.defaultBranch
        detail.isGitRepo = result.isGitRepo
        detail.aheadBy = result.aheadBy
        detail.behindBy = result.behindBy
        let staged = result.items.filter { $0.staged == true }
        let unstaged = result.items.filter { $0.staged != true }
        detail.stagedItems = staged
        detail.unstagedItems = unstaged
        workspaceGitDetailState[key] = detail
    }

    func handleGitBranchesResult(_ result: GitBranchesResult) {
        let key = globalWorkspaceKey(project: result.project, workspace: result.workspace)
        var detail = workspaceGitDetailState[key] ?? MobileWorkspaceGitDetailState.empty()
        detail.currentBranch = result.current
        detail.branches = result.branches
        workspaceGitDetailState[key] = detail
    }

    func handleGitCommitResult(_ result: GitCommitResult) {
        let key = globalWorkspaceKey(project: result.project, workspace: result.workspace)
        var detail = workspaceGitDetailState[key] ?? MobileWorkspaceGitDetailState.empty()
        detail.isCommitting = false
        detail.commitResult = result.ok ? "提交成功" : (result.message ?? "提交失败")
        if result.ok {
            detail.stagedItems = []
            wsClient.requestGitStatus(project: result.project, workspace: result.workspace)
        }
        workspaceGitDetailState[key] = detail
    }

    func handleGitAIMergeResult(_ result: GitAIMergeResult) {
        let resolvedTaskId =
            aiMergePendingTaskIdByProject.removeValue(forKey: result.project)
            ?? findLatestActiveTaskId(project: result.project, type: .aiMerge)
        if let taskId = resolvedTaskId {
            mutateTask(taskId) { task in
                task.status = result.success ? .completed : .failed
                task.message = result.message
                task.completedAt = Date()
            }
        } else {
            let task = createTask(
                project: result.project,
                workspace: result.workspace,
                type: .aiMerge,
                title: "智能合并",
                icon: "cpu",
                message: result.message
            )
            mutateTask(task.id) { t in
                t.status = result.success ? .completed : .failed
                t.completedAt = Date()
            }
        }
    }

    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult) {
        let resolvedTaskId =
            aiMergePendingTaskIdByProject.removeValue(forKey: result.project)
            ?? findLatestActiveTaskId(project: result.project, type: .aiMerge)
        guard let taskId = resolvedTaskId else { return }
        mutateTask(taskId) { task in
            let success = result.ok && result.state == .completed
            task.status = success ? .completed : .failed
            task.message = result.message ?? (success ? "完成" : "失败")
            task.completedAt = Date()
        }
    }

    func handleGitStatusChanged(_ notification: GitStatusChangedNotification) {
        wsClient.requestGitStatus(project: notification.project, workspace: notification.workspace)
        wsClient.requestGitBranches(project: notification.project, workspace: notification.workspace)
    }

    // MARK: - Project

    func handleProjectsList(_ result: ProjectsListResult) {
        let oldNames = Set(projects.map(\.name))
        let newNames = Set(result.items.map(\.name))
        // 释放已下线项目的缓存，防止残留数据占用内存
        let removedNames = oldNames.subtracting(newNames)
        for projectName in removedNames {
            evictProjectCache(projectName: projectName)
        }

        projects = result.items
        workspacesByProject = workspacesByProject.filter { newNames.contains($0.key) }
        for project in result.items {
            wsClient.requestListWorkspaces(project: project.name)
        }
    }

    func handleWorkspacesList(_ result: WorkspacesListResult) {
        workspacesByProject[result.project] = result.items
        if selectedProjectName == result.project {
            workspaces = result.items
        }
    }

    func handleProjectCommandStarted(project: String, workspace: String, commandId: String, taskId: String) {
        let routeKey = projectCommandRoutingKey(project: project, workspace: workspace, commandId: commandId)
        let localTaskId: String?
        if let mapped = projectCommandTaskIdByRemoteTaskId[taskId] {
            localTaskId = mapped
        } else if var queue = projectCommandPendingTaskIdsByKey[routeKey], !queue.isEmpty {
            let first = queue.removeFirst()
            projectCommandPendingTaskIdsByKey[routeKey] = queue.isEmpty ? nil : queue
            projectCommandTaskIdByRemoteTaskId[taskId] = first
            localTaskId = first
        } else {
            localTaskId = nil
        }
        if let resolvedId = localTaskId {
            mutateTask(resolvedId) { task in
                task.status = .running
                task.startedAt = task.startedAt ?? Date()
                task.message = "运行中..."
                task.remoteTaskId = taskId
            }
        } else {
            let commandName = resolveCommandName(project: project, commandId: commandId)
            let commandIcon = resolveCommandIcon(project: project, commandId: commandId)
            let task = createTask(
                project: project,
                workspace: workspace,
                type: .projectCommand,
                title: commandName,
                icon: commandIcon,
                message: "运行中..."
            )
            mutateTask(task.id) { t in
                t.commandId = commandId
                t.remoteTaskId = taskId
            }
            projectCommandTaskIdByRemoteTaskId[taskId] = task.id
        }
    }

    func handleProjectCommandCompleted(project: String, workspace: String, commandId: String, taskId: String, ok: Bool, message: String?) {
        let routeKey = projectCommandRoutingKey(project: project, workspace: workspace, commandId: commandId)
        let localTaskId = projectCommandTaskIdByRemoteTaskId.removeValue(forKey: taskId)
            ?? projectCommandPendingTaskIdsByKey[routeKey]?.first
        if let localTaskId,
           var queue = projectCommandPendingTaskIdsByKey[routeKey],
           queue.first == localTaskId {
            queue.removeFirst()
            projectCommandPendingTaskIdsByKey[routeKey] = queue.isEmpty ? nil : queue
        }
        guard let resolvedId = localTaskId else { return }
        mutateTask(resolvedId) { task in
            task.status = ok ? .completed : .failed
            task.message = message ?? (ok ? "完成" : "失败")
            task.completedAt = Date()
        }
    }

    func handleProjectCommandOutput(taskId: String, line: String) {
        guard let localTaskId = projectCommandTaskIdByRemoteTaskId[taskId] else { return }
        mutateTask(localTaskId) { task in
            task.lastOutputLine = line
        }
    }

    func handleTemplatesList(_ result: TemplatesListResult) {
        templates = result.items
    }

    func handleTemplateSaved(_ result: TemplateSavedResult) {
        guard result.ok else { return }
        if let idx = templates.firstIndex(where: { $0.id == result.template.id }) {
            templates[idx] = result.template
        } else {
            templates.append(result.template)
        }
    }

    func handleTemplateDeleted(_ result: TemplateDeletedResult) {
        guard result.ok else { return }
        templates.removeAll { $0.id == result.templateId }
    }

    func handleTemplateImported(_ result: TemplateImportedResult) {
        guard result.ok else { return }
        if let idx = templates.firstIndex(where: { $0.id == result.template.id }) {
            templates[idx] = result.template
        } else {
            templates.append(result.template)
        }
    }

    // MARK: - File

    func handleFileReadResult(_ result: FileReadResult) {
        // 计划文档预览分流
        if let pendingPath = pendingPlanDocumentReadPath, pendingPath == result.path {
            pendingPlanDocumentReadPath = nil
            evolutionPlanDocumentLoading = false
            let bytes = Data(result.content)
            if let text = String(data: bytes, encoding: .utf8) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    evolutionPlanDocumentError = "evolution.page.planDocument.empty".localized
                    evolutionPlanDocumentContent = nil
                } else {
                    evolutionPlanDocumentContent = text
                }
            } else {
                evolutionPlanDocumentError = "evolution.page.planDocument.empty".localized
                evolutionPlanDocumentContent = nil
            }
            return
        }

        guard let pending = pendingExplorerPreviewRequest else { return }
        guard pending.project == result.project,
              pending.workspace == result.workspace,
              pending.path == result.path else { return }
        pendingExplorerPreviewRequest = nil
        explorerPreviewLoading = false

        let bytes = Data(result.content)
        if result.size > 256 * 1024 {
            explorerPreviewError = "文件过大，暂不支持预览"
            explorerPreviewContent = ""
            return
        }

        if let text = String(data: bytes, encoding: .utf8) {
            explorerPreviewError = nil
            explorerPreviewContent = text
        } else {
            explorerPreviewError = "二进制文件暂不支持预览"
            explorerPreviewContent = ""
        }
    }

    func handleFileIndexResult(_ result: FileIndexResult) {
        let key = aiContextKey(project: result.project, workspace: result.workspace)
        aiFileIndexCache[key] = FileIndexCache(
            items: result.items,
            truncated: result.truncated,
            updatedAt: Date(),
            isLoading: false,
            error: nil
        )
    }

    func handleFileListResult(_ result: FileListResult) {
        let key = explorerCacheKey(project: result.project, workspace: result.workspace, path: result.path)
        explorerFileListCache[key] = FileListCache(
            items: result.items,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
    }

    func handleFileRenameResult(_ result: FileRenameResult) {
        if result.success {
            refreshExplorer(project: result.project, workspace: result.workspace)
        } else {
            errorMessage = result.message ?? "重命名失败"
        }
    }

    func handleFileDeleteResult(_ result: FileDeleteResult) {
        if result.success {
            refreshExplorer(project: result.project, workspace: result.workspace)
        } else {
            errorMessage = result.message ?? "删除失败"
        }
    }

    func handleFileWriteResult(_ result: FileWriteResult) {
        if result.success {
            refreshExplorer(project: result.project, workspace: result.workspace)
        } else {
            errorMessage = "新建文件失败：\(result.path)"
        }
    }

    // MARK: - Terminal

    func handleTerminalOutput(termId: String?, bytes: [UInt8]) {
        if let termId, currentTermId.isEmpty {
            switchToTerminal(termId: termId)
        }
        guard let termId else { return }
        emitTerminalOutput(bytes, termId: termId, shouldRender: termId == currentTermId)
    }

    func handleTerminalExit(termId: String?, code: Int) {
        // 终端退出，可选择通知用户
    }

    func handleTermCreated(_ result: TermCreatedResult) {
        switchToTerminal(termId: result.termId)
        terminalSessionStore.handleTermCreated(
            result: result,
            pendingCommandIcon: pendingCustomCommandIcon.isEmpty ? nil : pendingCustomCommandIcon,
            pendingCommandName: pendingCustomCommandName.isEmpty ? nil : pendingCustomCommandName,
            pendingCommand: pendingCustomCommand.isEmpty ? nil : pendingCustomCommand,
            makeKey: globalWorkspaceKey(project:workspace:)
        )
        workspaceTerminalOpenTime = terminalSessionStore.workspaceOpenTime

        wsClient.requestTermResize(
            termId: result.termId,
            cols: terminalCols,
            rows: terminalRows
        )
        terminalSink?.focusTerminal()
        wsClient.requestTermList()
        let cmd = pendingCustomCommand
        if !cmd.isEmpty {
            let termId = result.termId
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.wsClient.sendTerminalInput(cmd + "\n", termId: termId)
            }
        }
        pendingCustomCommand = ""
        pendingCustomCommandIcon = ""
        pendingCustomCommandName = ""
    }

    func handleTermAttached(_ result: TermAttachedResult) {
        if let rtt = terminalSessionStore.handleTermAttached(result: result) {
            let costMs = Int(rtt * 1000)
            TFLog.app.info("perf.mobile.terminal.attach.rtt_ms=\(costMs, privacy: .public) term=\(result.termId, privacy: .public)")
        }
        switchToTerminal(termId: result.termId)
        if !result.scrollback.isEmpty {
            emitTerminalOutput(result.scrollback, termId: result.termId, shouldRender: true)
            if !result.termId.isEmpty {
                wsClient.sendTermOutputAck(termId: result.termId, bytes: result.scrollback.count)
                terminalSessionStore.resetUnackedBytes(for: result.termId)
            }
        }
        wsClient.requestTermResize(
            termId: result.termId,
            cols: terminalCols,
            rows: terminalRows
        )
        terminalSink?.focusTerminal()
    }

    func handleTermList(_ result: TermListResult) {
        activeTerminals = result.items
        terminalSessionStore.reconcileTermList(
            items: result.items,
            makeKey: globalWorkspaceKey(project:workspace:)
        )
        workspaceTerminalOpenTime = terminalSessionStore.workspaceOpenTime
    }

    func handleTermClosed(_ termId: String) {
        terminalSessionStore.handleTermClosed(termId: termId)
        if currentTermId == termId {
            currentTermId = ""
        }
        wsClient.requestTermList()
    }

    // MARK: - Evolution

    func handleEvolutionPulse() {
        wsClient.requestEvoSnapshot()
    }

    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2) {
        if evolutionScheduler != snapshot.scheduler {
            evolutionScheduler = snapshot.scheduler
        }
        let items = snapshot.workspaceItems.sorted {
            ($0.project, $0.workspace) < ($1.project, $1.workspace)
        }
        if evolutionWorkspaceItems != items {
            evolutionWorkspaceItems = items
        }
        for item in items where item.status != "interrupted" {
            let key = globalWorkspaceKey(project: item.project, workspace: normalizeEvolutionWorkspaceName(item.workspace))
            evolutionPendingActionByWorkspace.removeValue(forKey: key)
        }
    }

    func handleEvolutionCycleUpdated(_ ev: EvoCycleUpdatedV2) {
        // iOS 端暂未使用，保留接口对齐
    }

    func handleEvolutionStageChatOpened(_ ev: EvolutionStageChatOpenedV2) {
        guard let aiTool = ev.aiTool else {
            evolutionReplayLoading = false
            evolutionReplayError = "不支持的 AI 工具：\(ev.aiToolRaw)"
            return
        }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(ev.workspace)
        evolutionReplayRequest = (
            project: ev.project,
            workspace: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: ev.sessionID,
            cycleId: ev.cycleID,
            stage: ev.stage
        )
        evolutionReplayTitle = "\(normalizedWorkspace) · \(ev.stage) · \(ev.cycleID)"
        evolutionReplayMessages = []
        evolutionReplayError = nil
        evolutionReplayLoading = false

        openAIChat(project: ev.project, workspace: normalizedWorkspace)

        let updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let session = AISessionInfo(
            projectName: ev.project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            id: ev.sessionID,
            title: "\(ev.stage) · \(ev.cycleID)",
            updatedAt: updatedAt,
            origin: .evolutionSystem
        )

        var sessions = aiSessionsByTool[aiTool] ?? []
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        setAISessions(sessions.sorted { $0.updatedAt > $1.updatedAt }, for: aiTool)

        let evoContext = AISessionHistoryCoordinator.Context(
            project: ev.project,
            workspace: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: ev.sessionID
        )
        AISessionHistoryCoordinator.subscribeAndLoadRecent(
            context: evoContext,
            wsClient: wsClient,
            store: aiChatStore
        )
        requestAISessionStatus(
            projectName: ev.project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: ev.sessionID,
            force: true
        )
    }

    func handleEvolutionAgentProfile(_ ev: EvolutionAgentProfileV2) {
        let workspace = normalizeEvolutionWorkspaceName(ev.workspace)
        let key = globalWorkspaceKey(project: ev.project, workspace: workspace)
        if ev.stageProfiles.isEmpty {
            NSLog(
                "[MobileAppState] Evolution profile ignored: empty stage_profiles, project=%@, workspace=%@",
                ev.project,
                workspace
            )
            finishEvolutionProfileReloadTracking(project: ev.project, workspace: workspace)
            return
        }
        evolutionStageProfilesByWorkspace[key] = ev.stageProfiles
        let directionModel = ev.stageProfiles
            .first(where: { $0.stage == "direction" })?
            .model
            .map { "\($0.providerID)/\($0.modelID)" } ?? "default"
        NSLog(
            "[MobileAppState] Evolution profile applied: project=%@, workspace=%@, stages=%d, direction_model=%@",
            ev.project,
            workspace,
            ev.stageProfiles.count,
            directionModel
        )
        finishEvolutionProfileReloadTracking(project: ev.project, workspace: workspace)
    }

    func handleEvolutionBlockingRequired(_ ev: EvolutionBlockingRequiredV2) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(ev.workspace)
        evolutionBlockingRequired = EvolutionBlockingRequiredV2(
            project: ev.project,
            workspace: normalizedWorkspace,
            trigger: ev.trigger,
            cycleID: ev.cycleID,
            stage: ev.stage,
            blockerFilePath: ev.blockerFilePath,
            unresolvedItems: ev.unresolvedItems
        )
        evolutionBlockers = ev.unresolvedItems
    }

    func handleEvolutionBlockersUpdated(_ ev: EvolutionBlockersUpdatedV2) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(ev.workspace)
        evolutionBlockers = ev.unresolvedItems
        if ev.unresolvedCount > 0 {
            evolutionBlockingRequired = EvolutionBlockingRequiredV2(
                project: ev.project,
                workspace: normalizedWorkspace,
                trigger: "updated",
                cycleID: evolutionBlockingRequired?.cycleID,
                stage: evolutionBlockingRequired?.stage,
                blockerFilePath: evolutionBlockingRequired?.blockerFilePath ?? "",
                unresolvedItems: ev.unresolvedItems
            )
            return
        }
        evolutionBlockingRequired = nil
        let key = globalWorkspaceKey(project: ev.project, workspace: normalizedWorkspace)
        guard let pendingAction = evolutionPendingActionByWorkspace.removeValue(forKey: key) else {
            return
        }
        if pendingAction == "start" {
            let profiles = evolutionProfiles(project: ev.project, workspace: normalizedWorkspace)
            let loopRoundLimit = max(
                1,
                evolutionItem(project: ev.project, workspace: normalizedWorkspace)?.loopRoundLimit ?? 1
            )
            startEvolution(
                project: ev.project,
                workspace: normalizedWorkspace,
                loopRoundLimit: loopRoundLimit,
                profiles: profiles
            )
            return
        }
        if pendingAction == "resume" {
            resumeEvolution(project: ev.project, workspace: normalizedWorkspace)
        }
    }

    func handleEvolutionCycleHistory(project: String, workspace: String, cycles: [EvolutionCycleHistoryItemV2]) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(project: project, workspace: normalizedWorkspace)
        evolutionCycleHistories[key] = cycles
    }

    func handleEvolutionAutoCommitResult(_ result: EvoAutoCommitResult) {
        let key = globalWorkspaceKey(project: result.project, workspace: result.workspace)
        let localTaskId = aiCommitPendingTaskIds.first.flatMap { taskId -> String? in
            if taskStore.allTasks(for: key).contains(where: { $0.id == taskId && $0.status.isActive }) {
                return taskId
            }
            return nil
        } ?? aiCommitPendingTaskIds.first

        if let taskId = localTaskId {
            aiCommitPendingTaskIds.removeAll { $0 == taskId }
            mutateTask(taskId) { task in
                task.status = result.success ? .completed : .failed
                task.message = result.message
                task.completedAt = Date()
            }
        } else {
            let task = createTask(
                project: result.project,
                workspace: result.workspace,
                type: .aiCommit,
                title: "一键提交",
                icon: "sparkles",
                message: result.message
            )
            mutateTask(task.id) { t in
                t.status = result.success ? .completed : .failed
                t.completedAt = Date()
            }
        }
    }

    func handleEvolutionError(_ error: CoreError) {
        let message = error.message
        evolutionReplayLoading = false
        evolutionReplayError = message
        evolutionPendingActionByWorkspace.removeAll()
        for key in evidenceLoadingByWorkspace.keys {
            evidenceLoadingByWorkspace[key] = false
            evidenceErrorByWorkspace[key] = message
        }
        let promptCallbacks = evidencePromptCompletionByWorkspace
        evidencePromptCompletionByWorkspace.removeAll()
        for (_, completion) in promptCallbacks {
            completion(nil, message)
        }
        let readRequests = evidenceReadRequestByWorkspace
        evidenceReadRequestByWorkspace.removeAll()
        for (_, request) in readRequests {
            if request.autoContinue {
                request.fullCompletion(nil, message)
            } else {
                request.pageCompletion(nil, message)
            }
        }
    }

    // MARK: - Evidence

    func handleEvidenceSnapshot(_ snapshot: EvidenceSnapshotV2) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(snapshot.workspace)
        let key = globalWorkspaceKey(project: snapshot.project, workspace: normalizedWorkspace)
        evidenceSnapshotsByWorkspace[key] = snapshot
        evidenceLoadingByWorkspace[key] = false
        evidenceErrorByWorkspace[key] = nil
    }

    func handleEvidenceRebuildPrompt(_ prompt: EvidenceRebuildPromptV2) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(prompt.workspace)
        let key = globalWorkspaceKey(project: prompt.project, workspace: normalizedWorkspace)
        if let completion = evidencePromptCompletionByWorkspace.removeValue(forKey: key) {
            completion(prompt, nil)
        }
    }

    func handleEvidenceItemChunk(_ chunk: EvidenceItemChunkV2) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(chunk.workspace)
        let key = globalWorkspaceKey(project: chunk.project, workspace: normalizedWorkspace)
        guard var request = evidenceReadRequestByWorkspace[key] else { return }
        guard request.itemID == chunk.itemID else { return }

        guard chunk.offset == request.expectedOffset else {
            if chunk.offset < request.expectedOffset {
                return
            }
            if request.expectedOffset == 0 {
                return
            }
            evidenceReadRequestByWorkspace.removeValue(forKey: key)
            if request.autoContinue {
                request.fullCompletion(nil, "证据分块偏移不连续，读取已中断")
            } else {
                request.pageCompletion(nil, "证据分块偏移不连续，读取已中断")
            }
            return
        }

        request.totalSizeBytes = chunk.totalSizeBytes
        request.mimeType = chunk.mimeType
        request.expectedOffset = chunk.nextOffset

        if !request.autoContinue {
            evidenceReadRequestByWorkspace.removeValue(forKey: key)
            request.pageCompletion(
                .init(
                    mimeType: chunk.mimeType,
                    content: chunk.content,
                    offset: chunk.offset,
                    nextOffset: chunk.nextOffset,
                    totalSizeBytes: chunk.totalSizeBytes,
                    eof: chunk.eof
                ),
                nil
            )
            return
        }

        request.content.append(contentsOf: chunk.content)

        if chunk.eof {
            evidenceReadRequestByWorkspace.removeValue(forKey: key)
            request.fullCompletion((mimeType: request.mimeType, content: request.content), nil)
            return
        }

        evidenceReadRequestByWorkspace[key] = request
        wsClient.requestEvidenceReadItem(
            project: request.project,
            workspace: request.workspace,
            itemID: request.itemID,
            offset: request.expectedOffset,
            limit: request.limit
        )
    }

    // MARK: - Error

    func handleClientError(_ message: String) {
        errorMessage = message
        aiSessionListPageStates = aiSessionListPageStates.mapValues { state in
            var updated = state
            updated.isLoadingInitial = false
            updated.isLoadingNextPage = false
            return updated
        }
        if !evolutionPendingActionByWorkspace.isEmpty {
            let pendingCount = evolutionPendingActionByWorkspace.count
            evolutionPendingActionByWorkspace.removeAll()
            NSLog(
                "[MobileAppState] Evolution pending actions cleared after client error: count=%d, error=%@",
                pendingCount,
                message
            )
        }
        if pendingExplorerPreviewRequest != nil {
            pendingExplorerPreviewRequest = nil
            explorerPreviewLoading = false
            explorerPreviewError = message
            explorerPreviewContent = ""
        }
        if pendingPlanDocumentReadPath != nil {
            pendingPlanDocumentReadPath = nil
            evolutionPlanDocumentLoading = false
            evolutionPlanDocumentError = message
        }
        if !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty {
            let key = aiContextKey(project: aiActiveProject, workspace: aiActiveWorkspace)
            if var cache = aiFileIndexCache[key], cache.isLoading {
                cache.isLoading = false
                cache.error = message
                aiFileIndexCache[key] = cache
            }
        }
    }

    func handleCoreError(_ error: CoreError) {
        let currentProject = selectedProjectName.isEmpty ? nil : selectedProjectName
        let currentWorkspace = aiActiveWorkspace.isEmpty ? nil : aiActiveWorkspace
        guard error.belongsTo(project: currentProject, workspace: currentWorkspace) else {
            NSLog(
                "[MobileAppState] Ignoring cross-workspace Core error: code=%@ project=%@ workspace=%@",
                error.code.rawValue,
                error.project ?? "nil",
                error.workspace ?? "nil"
            )
            return
        }
        if error.code.isRecoverable {
            return
        }
        errorMessage = error.message
    }
}
