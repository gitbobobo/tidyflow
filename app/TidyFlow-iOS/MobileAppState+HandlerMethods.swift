import Foundation
import TidyFlowShared

// MARK: - 领域消息处理方法（从 setupWSCallbacks 闭包迁移）
// 适配器类转发到此处的实例方法，保持业务逻辑集中。

extension MobileAppState {

    // MARK: - Git

    func handleGitStatusResult(_ result: GitStatusResult) {
        applyGitInput(.gitStatusResult(result), project: result.project, workspace: result.workspace)
    }

    func handleGitBranchesResult(_ result: GitBranchesResult) {
        applyGitInput(.gitBranchesResult(result), project: result.project, workspace: result.workspace)
    }

    func handleGitCommitResult(_ result: GitCommitResult) {
        applyGitInput(.gitCommitResult(result), project: result.project, workspace: result.workspace)
    }

    func handleGitOpResult(_ result: GitOpResult) {
        applyGitInput(.gitOpResult(result), project: result.project, workspace: result.workspace)
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
        // 同步更新冲突向导缓存（integration 上下文）
        if result.state == .conflict && !result.conflictFiles.isEmpty {
            let key = "\(result.project):integration"
            var wizard = conflictWizardCache[key] ?? ConflictWizardCache.empty()
            wizard.snapshot = ConflictSnapshot(
                context: "integration",
                files: result.conflictFiles,
                allResolved: result.conflictFiles.isEmpty
            )
            wizard.updatedAt = Date()
            conflictWizardCache[key] = wizard
        }
    }

    func handleGitStatusChanged(_ notification: GitStatusChangedNotification) {
        applyGitInput(.gitStatusChanged, project: notification.project, workspace: notification.workspace)
    }

    // v1.40: 冲突向导 handler（与 macOS GitCacheState+Operations 语义对齐）

    func handleGitConflictDetailResult(_ result: GitConflictDetailResult) {
        let key = result.context == "integration"
            ? "\(result.project):integration"
            : "\(result.project):\(result.workspace)"
        var wizard = conflictWizardCache[key] ?? ConflictWizardCache.empty()
        wizard.currentDetail = GitConflictDetailResultCache(from: result)
        wizard.selectedFilePath = result.path
        wizard.isLoading = false
        wizard.updatedAt = Date()
        conflictWizardCache[key] = wizard
    }

    func handleGitConflictActionResult(_ result: GitConflictActionResult) {
        let key = result.context == "integration"
            ? "\(result.project):integration"
            : "\(result.project):\(result.workspace)"
        var wizard = conflictWizardCache[key] ?? ConflictWizardCache.empty()
        wizard.snapshot = result.snapshot
        wizard.isLoading = false
        wizard.updatedAt = Date()
        if result.ok, result.path == wizard.selectedFilePath {
            wizard.currentDetail = nil
        }
        conflictWizardCache[key] = wizard
    }

    // v1.50: Stash handlers

    func handleGitStashListResult(_ result: GitStashListResult) {
        let key = globalWorkspaceKey(project: result.project, workspace: result.workspace)
        stashListCache[key] = GitStashListCache(
            entries: result.entries,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
        if selectedStashId[key] == nil, let first = result.entries.first {
            selectedStashId[key] = first.stashId
        }
    }

    func handleGitStashShowResult(_ result: GitStashShowResult) {
        let key = "\(globalWorkspaceKey(project: result.project, workspace: result.workspace)):stash:\(result.stashId)"
        stashShowCache[key] = GitStashShowCache(
            stashId: result.stashId,
            entry: result.entry,
            files: result.files,
            diffText: result.diffText,
            isBinarySummaryTruncated: result.isBinarySummaryTruncated,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
    }

    func handleGitStashOpResult(_ result: GitStashOpResult) {
        let key = globalWorkspaceKey(project: result.project, workspace: result.workspace)
        stashOpInFlight[key] = false
        if result.ok {
            stashLastError.removeValue(forKey: key)
        } else {
            stashLastError[key] = result.message ?? "Stash operation failed"
        }
        // 刷新列表和 status
        if result.ok || result.state == "conflict" {
            wsClient.requestGitStashList(project: result.project, workspace: result.workspace, cacheMode: .forceRefresh)
            applyGitInput(.gitStatusChanged, project: result.project, workspace: result.workspace)
        }
        // 冲突桥接到现有冲突向导
        if result.state == "conflict" && !result.conflictFiles.isEmpty {
            let wizardKey = "\(result.project):\(result.workspace)"
            var wizard = conflictWizardCache[wizardKey] ?? ConflictWizardCache.empty()
            wizard.snapshot = ConflictSnapshot(
                context: "workspace",
                files: result.conflictFiles,
                allResolved: false
            )
            wizard.updatedAt = Date()
            conflictWizardCache[wizardKey] = wizard
        }
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
        // 1. 计划文档预览分流
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

        // 2. 编辑器文档读取分流
        let editorKey = EditorRequestKey(project: result.project, workspace: result.workspace, path: result.path)
        if pendingEditorFileReadRequests.contains(editorKey) {
            pendingEditorFileReadRequests.remove(editorKey)
            handleEditorFileReadResult(result)
            return
        }

        // 3. 资源预览读取
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
        // 编辑器文件保存分流
        let editorKey = EditorRequestKey(project: result.project, workspace: result.workspace, path: result.path)
        if pendingEditorFileWriteRequests.contains(editorKey) {
            pendingEditorFileWriteRequests.remove(editorKey)
            handleEditorFileWriteResult(result)
            return
        }

        // 普通文件写入（新建文件等）
        if result.success {
            refreshExplorer(project: result.project, workspace: result.workspace)
        } else {
            errorMessage = "新建文件失败：\(result.path)"
        }
    }

    // MARK: - File (格式化)

    /// 处理 Core 返回的格式化能力查询结果
    func handleFormatCapabilitiesResult(_ result: FileFormatCapabilitiesResult) {
        let globalKey = globalWorkspaceKey(project: result.project, workspace: result.workspace)
        guard var workspaceDocs = editorDocumentsByWorkspace[globalKey],
              var session = workspaceDocs[result.path] else { return }
        session.updateFormattingCapabilities(result.capabilities)
        workspaceDocs[result.path] = session
        editorDocumentsByWorkspace[globalKey] = workspaceDocs
    }

    /// 处理 Core 返回的格式化结果
    func handleFormatResult(_ result: FileFormatResult) {
        let globalKey = globalWorkspaceKey(project: result.project, workspace: result.workspace)
        guard var workspaceDocs = editorDocumentsByWorkspace[globalKey],
              var session = workspaceDocs[result.path] else { return }

        let docKey = session.key
        let formattingResult = result.toFormattingResult()
        let history = editorHistoryStateByDocument[docKey] ?? .empty

        if let applyResult = EditorFormattingResultApplier.applyFormatResult(
            result: formattingResult,
            currentText: session.content,
            currentSelections: session.selectionSet,
            history: history
        ) {
            session.content = applyResult.text
            session.selectionSet = applyResult.selections
            session.isDirty = EditorDocumentSession.contentHash(applyResult.text) != session.baselineContentHash
            session.canUndo = applyResult.canUndo
            session.canRedo = applyResult.canRedo
            editorHistoryStateByDocument[docKey] = applyResult.history
            updateEditorUndoRedoState(canUndo: applyResult.canUndo, canRedo: applyResult.canRedo, documentKey: docKey)
        }

        session.markFormattingCompleted()
        workspaceDocs[result.path] = session
        editorDocumentsByWorkspace[globalKey] = workspaceDocs

        // 通知编辑器视图刷新（格式化结果会改变文本，需要重新渲染）
        onEditorFormatApplied?(docKey)
    }

    /// 处理 Core 返回的格式化错误
    func handleFormatError(_ result: FileFormatErrorResult) {
        let globalKey = globalWorkspaceKey(project: result.project, workspace: result.workspace)
        guard var workspaceDocs = editorDocumentsByWorkspace[globalKey],
              var session = workspaceDocs[result.path] else { return }

        let formattingError = result.toFormattingError()
        session.markFormattingFailed(error: formattingError)
        workspaceDocs[result.path] = session
        editorDocumentsByWorkspace[globalKey] = workspaceDocs
    }

    // MARK: - Terminal

    func handleTerminalOutput(termId: String?, bytes: [UInt8]) {
        if let termId, currentTermId.isEmpty {
            switchToTerminal(termId: termId)
        }
        guard let termId else { return }
        // 只接受处于 active 或 entering 相位的终端输出；
        // 已关闭或处于 idle/resuming 的终端输出被忽略（防止迟到事件污染）
        let phase = terminalSessionStore.lifecyclePhase(for: termId)
        guard phase == .active || phase == .entering else {
            TFLog.app.debug("忽略终端输出: term=\(termId, privacy: .public) phase=\(String(describing: phase), privacy: .public)")
            return
        }
        emitTerminalOutput(bytes, termId: termId, shouldRender: termId == currentTermId)
    }

    func handleTerminalExit(termId: String?, code: Int) {
        // 终端退出，可选择通知用户
    }

    func handleTermCreated(_ result: TermCreatedResult) {
        switchToTerminal(termId: result.termId)
        let launchRequest = pendingTerminalLaunchRequest
        terminalSessionStore.handleTermCreated(
            result: result,
            pendingCommandIcon: launchRequest?.icon,
            pendingCommandName: launchRequest?.title,
            pendingCommand: launchRequest?.command,
            makeKey: globalWorkspaceKey(project:workspace:)
        )
        workspaceTerminalOpenTime = terminalSessionStore.workspaceOpenTime

        // 驱动共享壳层：服务端已创建终端
        let ctx = SharedTerminalShellContext(projectName: result.project, workspaceName: result.workspace)
        feedTerminalShell(.serverTermCreated(termId: result.termId), context: ctx)

        wsClient.requestTermResize(
            termId: result.termId,
            cols: terminalCols,
            rows: terminalRows
        )
        terminalSink?.focusTerminal()
        wsClient.requestTermList()
        let cmd = launchRequest?.command ?? ""
        if !cmd.isEmpty {
            let termId = result.termId
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.wsClient.sendTerminalInput(cmd + "\n", termId: termId)
            }
        }
        pendingTerminalLaunchRequest = nil
    }

    func handleTermAttached(_ result: TermAttachedResult) {
        if let rtt = terminalSessionStore.handleTermAttached(result: result) {
            let costMs = Int(rtt * 1000)
            TFLog.app.info("perf.mobile.terminal.attach.rtt_ms=\(costMs, privacy: .public) term=\(result.termId, privacy: .public)")
        }
        switchToTerminal(termId: result.termId)

        // 驱动共享壳层：服务端已附着终端
        if let info = terminalSessionStore.displayInfo(for: result.termId) {
            let ctx = SharedTerminalShellContext(projectName: info.project, workspaceName: info.workspace)
            feedTerminalShell(.serverTermAttached(termId: result.termId), context: ctx)
        }

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

        // 驱动共享壳层 term_list 同步：按工作区分组，更新壳层的活跃终端列表
        var byWorkspace: [String: [String]] = [:]
        for item in result.items {
            let key = globalWorkspaceKey(project: item.project, workspace: item.workspace)
            byWorkspace[key, default: []].append(item.termId)
        }
        for (key, termIds) in byWorkspace {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let ctx = SharedTerminalShellContext(projectName: parts[0], workspaceName: parts[1])
            feedTerminalShell(.reconcileLiveTerminals(liveTermIds: termIds), context: ctx, liveTermIds: termIds)
        }
        // 也对已消失的工作区进行 reconcile（所有终端已关闭的场景）
        for key in terminalShellState.workspaceStates.keys where byWorkspace[key] == nil {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let ctx = SharedTerminalShellContext(projectName: parts[0], workspaceName: parts[1])
            feedTerminalShell(.reconcileLiveTerminals(liveTermIds: []), context: ctx, liveTermIds: [])
        }
    }

    func handleTermClosed(_ termId: String) {
        terminalSessionStore.handleTermClosed(termId: termId)

        // 驱动共享壳层：终端已关闭
        if let info = terminalSessionStore.displayInfo(for: termId) {
            let ctx = SharedTerminalShellContext(projectName: info.project, workspaceName: info.workspace)
            feedTerminalShell(.serverTermClosed(termId: termId), context: ctx)
        }

        if currentTermId == termId {
            // 选中的终端被关闭：由共享壳层的 fallback 选择决定下一个
            if let info = terminalSessionStore.displayInfo(for: termId) {
                let key = globalWorkspaceKey(project: info.project, workspace: info.workspace)
                let ws = terminalShellState.state(for: key)
                if case .active(let nextId) = ws.selection {
                    switchToTerminal(termId: nextId)
                } else {
                    currentTermId = ""
                }
            } else {
                currentTermId = ""
            }
        }
        wsClient.requestTermList()
    }

    // MARK: - Evolution

    func handleEvolutionPulse() {
        if let selectedWorkspaceIdentity {
            requestEvolutionSnapshot(
                project: selectedWorkspaceIdentity.projectName,
                workspace: selectedWorkspaceIdentity.workspaceName
            )
        } else {
            requestEvolutionSnapshot()
        }
    }

    func handleEvolutionWorkspaceStatusEvent(_ ev: EvolutionWorkspaceStatusEventV2) {
        let workspace = normalizeEvolutionWorkspaceName(ev.workspace)
        let key = globalWorkspaceKey(project: ev.project, workspace: workspace)
        guard let existingIndex = evolutionWorkspaceItems.firstIndex(where: { item in
            globalWorkspaceKey(project: item.project, workspace: normalizeEvolutionWorkspaceName(item.workspace)) == key
        }) else {
            requestEvolutionSnapshot(project: ev.project, workspace: workspace)
            return
        }

        let existing = evolutionWorkspaceItems[existingIndex]
        let shouldFallback: Bool
        switch ev.kind {
        case .started, .resumed:
            shouldFallback = existing.cycleID != ev.cycleID
        case .stageChanged:
            shouldFallback = existing.cycleID != ev.cycleID || (ev.currentStage?.isEmpty ?? true)
        case .stopped:
            shouldFallback = false
        }
        if shouldFallback {
            requestEvolutionSnapshot(project: ev.project, workspace: workspace)
            return
        }

        let updated = EvolutionWorkspaceItemV2(
            project: existing.project,
            workspace: existing.workspace,
            cycleID: ev.cycleID,
            title: existing.title,
            status: ev.status ?? existing.status,
            currentStage: ev.currentStage ?? existing.currentStage,
            globalLoopRound: existing.globalLoopRound,
            loopRoundLimit: existing.loopRoundLimit,
            verifyIteration: ev.verifyIteration ?? existing.verifyIteration,
            verifyIterationLimit: existing.verifyIterationLimit,
            agents: existing.agents,
            executions: existing.executions,
            terminalReasonCode: existing.terminalReasonCode,
            terminalErrorMessage: existing.terminalErrorMessage,
            rateLimitErrorMessage: existing.rateLimitErrorMessage,
            startedAt: existing.startedAt,
            durationMs: existing.durationMs,
            errorCode: existing.errorCode,
            retryable: existing.retryable,
            coordinationState: existing.coordinationState,
            coordinationReason: existing.coordinationReason,
            coordinationScope: existing.coordinationScope,
            coordinationPeerNodeID: existing.coordinationPeerNodeID,
            coordinationPeerNodeName: existing.coordinationPeerNodeName,
            coordinationPeerProject: existing.coordinationPeerProject,
            coordinationPeerWorkspace: existing.coordinationPeerWorkspace,
            coordinationQueueIndex: existing.coordinationQueueIndex
        )
        if evolutionWorkspaceItems[existingIndex] != updated {
            evolutionWorkspaceItems[existingIndex] = updated
        }
        if ev.kind == .stopped {
            // stopped 事件只带轻量状态，终态耗时/执行时间线仍以快照为准。
            requestEvolutionSnapshot(project: ev.project, workspace: workspace)
        }
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
        for item in items {
            let key = globalWorkspaceKey(project: item.project, workspace: normalizeEvolutionWorkspaceName(item.workspace))
            if let pendingAction = evolutionPendingActionByWorkspace[key],
               EvolutionControlCapability.shouldClearPendingAction(pendingAction, currentStatus: item.status) {
                evolutionPendingActionByWorkspace.removeValue(forKey: key)
            }
        }
    }

    func handleEvolutionCycleUpdated(_ ev: EvoCycleUpdatedV2) {
        let workspace = normalizeEvolutionWorkspaceName(ev.workspace)
        let key = globalWorkspaceKey(project: ev.project, workspace: workspace)
        guard let existingIndex = evolutionWorkspaceItems.firstIndex(where: { item in
            globalWorkspaceKey(project: item.project, workspace: normalizeEvolutionWorkspaceName(item.workspace)) == key
        }) else {
            requestEvolutionSnapshot(project: ev.project, workspace: workspace)
            return
        }

        let existing = evolutionWorkspaceItems[existingIndex]
        let updated = EvolutionWorkspaceItemV2(
            project: ev.project,
            workspace: workspace,
            cycleID: ev.cycleID,
            title: ev.title ?? existing.title,
            status: ev.status,
            currentStage: ev.currentStage,
            globalLoopRound: ev.globalLoopRound,
            loopRoundLimit: ev.loopRoundLimit,
            verifyIteration: ev.verifyIteration,
            verifyIterationLimit: ev.verifyIterationLimit,
            agents: ev.agents,
            executions: ev.executions,
            terminalReasonCode: ev.terminalReasonCode,
            terminalErrorMessage: ev.terminalErrorMessage,
            rateLimitErrorMessage: ev.rateLimitErrorMessage,
            startedAt: ev.startedAt ?? existing.startedAt,
            durationMs: ev.durationMs ?? existing.durationMs,
            errorCode: ev.errorCode ?? existing.errorCode,
            retryable: ev.retryable,
            coordinationState: ev.coordinationState ?? existing.coordinationState,
            coordinationReason: ev.coordinationReason ?? existing.coordinationReason,
            coordinationScope: ev.coordinationScope ?? existing.coordinationScope,
            coordinationPeerNodeID: ev.coordinationPeerNodeID ?? existing.coordinationPeerNodeID,
            coordinationPeerNodeName: ev.coordinationPeerNodeName ?? existing.coordinationPeerNodeName,
            coordinationPeerProject: ev.coordinationPeerProject ?? existing.coordinationPeerProject,
            coordinationPeerWorkspace: ev.coordinationPeerWorkspace ?? existing.coordinationPeerWorkspace,
            coordinationQueueIndex: ev.coordinationQueueIndex ?? existing.coordinationQueueIndex
        )
        if evolutionWorkspaceItems[existingIndex] != updated {
            evolutionWorkspaceItems[existingIndex] = updated
        }
        if let pendingAction = evolutionPendingActionByWorkspace[key],
           EvolutionControlCapability.shouldClearPendingAction(pendingAction, currentStatus: ev.status) {
            evolutionPendingActionByWorkspace.removeValue(forKey: key)
        }
    }

    func handleSystemEvolutionWorkspaceSummaries(
        _ summaries: [SystemSnapshotEvolutionWorkspaceSummary]
    ) {
        let existingByKey = Dictionary(
            uniqueKeysWithValues: evolutionWorkspaceItems.map {
                (globalWorkspaceKey(project: $0.project, workspace: normalizeEvolutionWorkspaceName($0.workspace)), $0)
            }
        )
        let items = summaries
            .map { summary in
                let workspace = normalizeEvolutionWorkspaceName(summary.workspace)
                let key = globalWorkspaceKey(project: summary.project, workspace: workspace)
                let normalizedSummary = SystemSnapshotEvolutionWorkspaceSummary(
                    project: summary.project,
                    workspace: workspace,
                    status: summary.status,
                    cycleID: summary.cycleID,
                    title: summary.title,
                    failureReason: summary.failureReason
                )
                return normalizedSummary.toWorkspaceItem(preserving: existingByKey[key])
            }
            .sorted { ($0.project, $0.workspace) < ($1.project, $1.workspace) }
        if evolutionWorkspaceItems != items {
            evolutionWorkspaceItems = items
        }
        for item in items {
            let key = item.workspaceKey
            if let pendingAction = evolutionPendingActionByWorkspace[key],
               EvolutionControlCapability.shouldClearPendingAction(
                pendingAction,
                currentStatus: item.status
            ) {
                evolutionPendingActionByWorkspace.removeValue(forKey: key)
            }
        }
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
        if pendingAction.action == .start {
            let profiles = evolutionProfiles(project: ev.project, workspace: normalizedWorkspace)
            let loopRoundLimit = pendingAction.resolvedLoopRoundLimit(
                fallback: evolutionItem(project: ev.project, workspace: normalizedWorkspace)?.loopRoundLimit ?? 1
            )
            startEvolution(
                project: ev.project,
                workspace: normalizedWorkspace,
                loopRoundLimit: loopRoundLimit,
                profiles: profiles
            )
            return
        }
        if pendingAction.action == .resume {
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
    }

    // MARK: - Error

    func handleClientError(_ message: String) {
        errorMessage = message
        aiSessionListStore.handleClientError()
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
        if error.code == .authenticationFailed || error.code == .authenticationRevoked {
            connectionPhase = .authenticationFailed(reason: error.message)
        }
        errorMessage = error.message
    }
}
