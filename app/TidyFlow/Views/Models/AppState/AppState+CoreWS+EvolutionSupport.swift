import Foundation

extension AppState {
    // MARK: - Evolution

    func requestEvolutionSnapshot(project: String? = nil, workspace: String? = nil) {
        wsClient.requestEvoSnapshot(project: project, workspace: workspace)
    }

    func requestEvolutionAgentProfile(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        finishEvolutionProfileReloadTracking(project: project, workspace: normalizedWorkspace)
        wsClient.requestEvoGetAgentProfile(project: project, workspace: normalizedWorkspace)
    }

    func requestEvolutionCycleHistory(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoListCycleHistory(project: project, workspace: normalizedWorkspace)
    }

    // MARK: - Handoff 预览

    func requestEvolutionHandoff(project: String, workspace: String, cycleID: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        evolutionHandoff = nil
        evolutionHandoffLoading = false
        evolutionHandoffError = nil
        if let item = evolutionItem(project: project, workspace: normalizedWorkspace),
           item.cycleID == cycleID {
            evolutionHandoff = item.handoff
            return
        }
        if let handoff = evolutionCycleHistories[key]?
            .first(where: { $0.cycleID == cycleID })?
            .handoff {
            evolutionHandoff = handoff
        }
    }

    // MARK: - Evidence

    func requestEvidenceSnapshot(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        evidenceLoadingByWorkspace[key] = true
        evidenceErrorByWorkspace[key] = nil
        wsClient.requestEvidenceSnapshot(project: project, workspace: normalizedWorkspace)
    }

    func requestEvidenceRebuildPrompt(
        project: String,
        workspace: String,
        completion: @escaping (_ prompt: EvidenceRebuildPromptV2?, _ errorMessage: String?) -> Void
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        evidencePromptCompletionByWorkspace[key] = completion
        wsClient.requestEvidenceRebuildPrompt(project: project, workspace: normalizedWorkspace)
    }

    func readEvidenceItem(
        project: String,
        workspace: String,
        itemID: String,
        limit: UInt32? = 262_144,
        completion: @escaping (_ payload: (mimeType: String, content: [UInt8])?, _ errorMessage: String?) -> Void
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        if let inFlight = evidenceReadRequestByWorkspace[key],
           inFlight.itemID == itemID,
           inFlight.autoContinue {
            return
        }
        evidenceReadRequestByWorkspace[key] = EvidenceReadRequestState(
            project: project,
            workspace: normalizedWorkspace,
            itemID: itemID,
            limit: limit,
            autoContinue: true,
            expectedOffset: 0,
            totalSizeBytes: nil,
            mimeType: "application/octet-stream",
            content: [],
            fullCompletion: completion,
            pageCompletion: { _, _ in }
        )
        wsClient.requestEvidenceReadItem(
            project: project,
            workspace: normalizedWorkspace,
            itemID: itemID,
            offset: 0,
            limit: limit
        )
    }

    func readEvidenceItemPage(
        project: String,
        workspace: String,
        itemID: String,
        offset: UInt64 = 0,
        limit: UInt32? = 131_072,
        completion: @escaping (_ payload: EvidenceReadRequestState.PagePayload?, _ errorMessage: String?) -> Void
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        if let inFlight = evidenceReadRequestByWorkspace[key],
           inFlight.itemID == itemID,
           !inFlight.autoContinue,
           inFlight.expectedOffset == offset {
            return
        }
        evidenceReadRequestByWorkspace[key] = EvidenceReadRequestState(
            project: project,
            workspace: normalizedWorkspace,
            itemID: itemID,
            limit: limit,
            autoContinue: false,
            expectedOffset: offset,
            totalSizeBytes: nil,
            mimeType: "application/octet-stream",
            content: [],
            fullCompletion: { _, _ in },
            pageCompletion: completion
        )
        wsClient.requestEvidenceReadItem(
            project: project,
            workspace: normalizedWorkspace,
            itemID: itemID,
            offset: offset,
            limit: limit
        )
    }

    func evidenceSnapshot(project: String, workspace: String) -> EvidenceSnapshotV2? {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        return evidenceSnapshotsByWorkspace[key]
    }

    func consumeAIChatOneShotHint(project: String, workspace: String) -> String? {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        let hint = aiChatOneShotHintByWorkspace[key]
        aiChatOneShotHintByWorkspace.removeValue(forKey: key)
        return hint
    }

    func setAIChatOneShotHint(project: String, workspace: String, message: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        aiChatOneShotHintByWorkspace[key] = message
    }

    /// 先拉齐每个 AI 工具的 provider/agent 列表，再拉取 Evolution profile，避免冷启动时读到默认配置。
    func requestEvolutionSelectorResourcesThenProfile(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        beginEvolutionSelectorLoading(project: project, workspace: normalizedWorkspace, requestProfileAfterLoaded: true)
        // 首次进入页面时先立即拉一次 profile，避免连接抖动导致页面长期停留默认值。
        wsClient.requestEvoGetAgentProfile(project: project, workspace: normalizedWorkspace)
        for tool in AIChatTool.allCases {
            wsClient.requestAIProviderList(projectName: project, workspaceName: normalizedWorkspace, aiTool: tool)
            wsClient.requestAIAgentList(projectName: project, workspaceName: normalizedWorkspace, aiTool: tool)
        }
    }

    func updateEvolutionAgentProfile(project: String, workspace: String, profiles: [EvolutionStageProfileInfoV2]) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let normalizedProfiles = Self.normalizedEvolutionProfiles(profiles)
        wsClient.requestEvoUpdateAgentProfile(
            project: project,
            workspace: normalizedWorkspace,
            stageProfiles: normalizedProfiles
        )
    }

    func startEvolution(
        project: String,
        workspace: String,
        loopRoundLimit: Int,
        profiles: [EvolutionStageProfileInfoV2]
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        setEvolutionPendingAction(
            project: project,
            workspace: normalizedWorkspace,
            action: .start,
            requestedLoopRoundLimit: loopRoundLimit
        )
        let normalizedProfiles = Self.normalizedEvolutionProfiles(profiles)
        wsClient.requestEvoStartWorkspace(
            project: project,
            workspace: normalizedWorkspace,
            priority: 0,
            loopRoundLimit: loopRoundLimit,
            stageProfiles: normalizedProfiles
        )
    }

    func stopEvolution(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        setEvolutionPendingAction(
            project: project,
            workspace: normalizedWorkspace,
            action: .stop
        )
        wsClient.requestEvoStopWorkspace(project: project, workspace: normalizedWorkspace)
    }

    func resumeEvolution(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        setEvolutionPendingAction(
            project: project,
            workspace: normalizedWorkspace,
            action: .resume
        )
        wsClient.requestEvoResumeWorkspace(project: project, workspace: normalizedWorkspace)
    }

    func resolveEvolutionBlockers(
        project: String,
        workspace: String,
        resolutions: [EvolutionBlockerResolutionInputV2]
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        wsClient.requestEvoResolveBlockers(
            project: project,
            workspace: normalizedWorkspace,
            resolutions: resolutions
        )
    }

    func openEvolutionStageChat(project: String, workspace: String, cycleId: String, stage: String) {
        if let request = evolutionReplayRequest {
            wsClient.requestAISessionUnsubscribe(
                project: request.project,
                workspace: request.workspace,
                aiTool: request.aiTool.rawValue,
                sessionId: request.sessionId
            )
        }
        evolutionReplayTitle = "\(workspace) · \(stage) · \(cycleId)"
        evolutionReplayLoading = true
        evolutionReplayError = nil
        evolutionReplayRequest = nil
        evolutionReplayStore.clearAll()
        wsClient.requestEvoOpenStageChat(project: project, workspace: workspace, cycleID: cycleId, stage: stage)
    }

    func clearEvolutionReplay() {
        if let request = evolutionReplayRequest {
            wsClient.requestAISessionUnsubscribe(
                project: request.project,
                workspace: request.workspace,
                aiTool: request.aiTool.rawValue,
                sessionId: request.sessionId
            )
        }
        evolutionReplayRequest = nil
        evolutionReplayLoading = false
        evolutionReplayError = nil
        evolutionReplayTitle = ""
        evolutionReplayStore.clearAll()
    }

    func openSubAgentSessionViewer(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String,
        sourceToolName: String?
    ) {
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionId.isEmpty else { return }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        if let request = subAgentViewerRequest {
            wsClient.requestAISessionUnsubscribe(
                project: request.project,
                workspace: request.workspace,
                aiTool: request.aiTool.rawValue,
                sessionId: request.sessionId
            )
        }
        let source = (sourceToolName ?? "task").trimmingCharacters(in: .whitespacesAndNewlines)
        subAgentViewerTitle = source.isEmpty ? "子会话 · \(trimmedSessionId)" : "子会话(\(source)) · \(trimmedSessionId)"
        subAgentViewerLoading = true
        subAgentViewerError = nil
        subAgentViewerRequest = (
            project: project,
            workspace: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: trimmedSessionId
        )
        subAgentViewerStore.clearAll()
        subAgentViewerStore.setCurrentSessionId(trimmedSessionId)
        wsClient.requestAISessionSubscribe(
            project: project,
            workspace: normalizedWorkspace,
            aiTool: aiTool.rawValue,
            sessionId: trimmedSessionId
        )
        wsClient.requestAISessionStatus(
            projectName: project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: trimmedSessionId
        )
        wsClient.requestAISessionMessages(
            projectName: project,
            workspaceName: normalizedWorkspace,
            aiTool: aiTool,
            sessionId: trimmedSessionId,
            limit: 50
        )
    }

    func clearSubAgentSessionViewer() {
        if let request = subAgentViewerRequest {
            wsClient.requestAISessionUnsubscribe(
                project: request.project,
                workspace: request.workspace,
                aiTool: request.aiTool.rawValue,
                sessionId: request.sessionId
            )
        }
        subAgentViewerRequest = nil
        subAgentViewerLoading = false
        subAgentViewerError = nil
        subAgentViewerTitle = ""
        subAgentViewerStore.clearAll()
    }

    func evolutionItem(project: String, workspace: String) -> EvolutionWorkspaceItemV2? {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        return evolutionWorkspaceItems.first {
            $0.project == project &&
                normalizeEvolutionWorkspaceName($0.workspace) == normalizedWorkspace
        }
    }

    func evolutionControlCapability(project: String, workspace: String?) -> EvolutionControlCapability {
        guard let workspace else {
            return EvolutionControlCapability.evaluate(
                workspaceReady: false,
                currentStatus: nil,
                pendingAction: nil
            )
        }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        let currentStatus = evolutionItem(project: project, workspace: normalizedWorkspace)?.status
        return EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: currentStatus,
            pendingAction: evolutionPendingActionByWorkspace[key]
        )
    }

    func setEvolutionPendingAction(
        project: String,
        workspace: String,
        action: EvolutionControlAction,
        requestedLoopRoundLimit: Int? = nil
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        evolutionPendingActionByWorkspace[key] = EvolutionPendingActionState(
            action: action,
            requestedLoopRoundLimit: requestedLoopRoundLimit
        )
    }

    func clearEvolutionPendingAction(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        evolutionPendingActionByWorkspace.removeValue(forKey: key)
    }

    func evolutionProfiles(project: String, workspace: String) -> [EvolutionStageProfileInfoV2] {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        if let profiles = evolutionStageProfilesByWorkspace[key], !profiles.isEmpty {
            if let fallback = evolutionProfilesFromClientSettings(project: project, workspace: normalizedWorkspace),
               shouldPreferEvolutionProfiles(candidate: fallback, over: profiles) {
                return Self.normalizedEvolutionProfiles(fallback)
            }
            return Self.normalizedEvolutionProfiles(profiles)
        }
        if let profiles = evolutionProfilesFromClientSettings(project: project, workspace: normalizedWorkspace) {
            return Self.normalizedEvolutionProfiles(profiles)
        }
        if !evolutionDefaultProfiles.isEmpty {
            let defaults = evolutionDefaultProfiles.map { item in
                let model: EvolutionModelSelectionV2? = {
                    guard !item.providerID.isEmpty, !item.modelID.isEmpty else { return nil }
                    return EvolutionModelSelectionV2(
                        providerID: item.providerID,
                        modelID: item.modelID
                    )
                }()
                return EvolutionStageProfileInfoV2(
                    stage: item.stage,
                    aiTool: item.aiTool,
                    mode: item.mode.isEmpty ? nil : item.mode,
                    model: model,
                    configOptions: item.configOptions
                )
            }
            return Self.normalizedEvolutionProfiles(defaults)
        }
        return Self.defaultEvolutionProfiles()
    }

    static func defaultEvolutionProfiles() -> [EvolutionStageProfileInfoV2] {
        [
            "direction",
            "plan",
            "implement_general",
            "implement_visual",
            "implement_advanced",
            "verify",
            "auto_commit",
        ].map {
            EvolutionStageProfileInfoV2(stage: $0, aiTool: .codex, mode: nil, model: nil, configOptions: [:])
        }
    }

    static func normalizedEvolutionProfiles(_ profiles: [EvolutionStageProfileInfoV2]) -> [EvolutionStageProfileInfoV2] {
        if profiles.isEmpty {
            return defaultEvolutionProfiles()
        }

        let validStages = Set(defaultEvolutionProfiles().map { $0.stage })
        var byStage: [String: EvolutionStageProfileInfoV2] = [:]

        // 第一遍：优先处理明确声明的阶段（非 legacy "implement"），确保显式配置不会被 legacy 映射覆盖
        for profile in profiles {
            let stage = profile.stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !stage.isEmpty, stage != "implement" else { continue }
            guard validStages.contains(stage) else { continue }
            if byStage[stage] != nil { continue }
            byStage[stage] = EvolutionStageProfileInfoV2(
                stage: stage,
                aiTool: profile.aiTool,
                mode: profile.mode,
                model: profile.model,
                configOptions: profile.configOptions
            )
        }

        // 第二遍：legacy "implement" 阶段仅填充尚未被显式配置覆盖的 implement_general / implement_visual
        for profile in profiles {
            let stage = profile.stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard stage == "implement" else { continue }
            for mappedStage in ["implement_general", "implement_visual"] where validStages.contains(mappedStage) {
                if byStage[mappedStage] != nil { continue }
                byStage[mappedStage] = EvolutionStageProfileInfoV2(
                    stage: mappedStage,
                    aiTool: profile.aiTool,
                    mode: profile.mode,
                    model: profile.model,
                    configOptions: profile.configOptions
                )
            }
        }

        return defaultEvolutionProfiles().map { item in
            byStage[item.stage] ?? item
        }
    }

    func beginEvolutionSelectorLoading(
        project: String,
        workspace: String,
        requestProfileAfterLoaded: Bool
    ) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        var byTool: [AIChatTool: (providerLoaded: Bool, agentLoaded: Bool)] = [:]
        for tool in AIChatTool.allCases {
            byTool[tool] = (providerLoaded: false, agentLoaded: false)
        }
        evolutionSelectorLoadStateByWorkspace[key] = byTool

        if requestProfileAfterLoaded {
            evolutionPendingProfileReloadWorkspaces.insert(key)
            scheduleEvolutionProfileReloadFallback(project: project, workspace: normalizedWorkspace)
        } else {
            finishEvolutionProfileReloadTracking(project: project, workspace: normalizedWorkspace)
        }
    }

    func normalizeEvolutionWorkspaceName(_ workspace: String) -> String {
        let trimmed = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("(default)") == .orderedSame ||
            trimmed.caseInsensitiveCompare("default") == .orderedSame {
            return "default"
        }
        return trimmed
    }

    func applyEvolutionProfilesFromClientSettings(
        _ profileMap: [String: [EvolutionStageProfileInfoV2]]
    ) {
        guard !profileMap.isEmpty else { return }
        for (storageKey, profiles) in profileMap {
            guard !profiles.isEmpty else { continue }
            guard let parsed = parseEvolutionProfileStorageKey(storageKey) else { continue }
            let workspace = normalizeEvolutionWorkspaceName(parsed.workspace)
            let key = globalWorkspaceKey(projectName: parsed.project, workspaceName: workspace)
            let current = evolutionStageProfilesByWorkspace[key] ?? []
            let normalized = Self.normalizedEvolutionProfiles(profiles)
            if current.isEmpty || shouldPreferEvolutionProfiles(candidate: normalized, over: current) {
                evolutionStageProfilesByWorkspace[key] = normalized
            }
        }
    }

    func evolutionProfilesFromClientSettings(
        project: String,
        workspace: String
    ) -> [EvolutionStageProfileInfoV2]? {
        guard !clientSettings.evolutionAgentProfiles.isEmpty else { return nil }
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let candidateKeys = evolutionProfileStorageKeyCandidates(
            project: project,
            workspace: normalizedWorkspace
        )
        for key in candidateKeys {
            if let profiles = clientSettings.evolutionAgentProfiles[key], !profiles.isEmpty {
                return Self.normalizedEvolutionProfiles(profiles)
            }
        }
        for (storageKey, profiles) in clientSettings.evolutionAgentProfiles {
            guard !profiles.isEmpty else { continue }
            guard let parsed = parseEvolutionProfileStorageKey(storageKey) else { continue }
            let parsedWorkspace = normalizeEvolutionWorkspaceName(parsed.workspace)
            if parsed.project == project && parsedWorkspace == normalizedWorkspace {
                return Self.normalizedEvolutionProfiles(profiles)
            }
        }
        return nil
    }

    func evolutionProfileStorageKeyCandidates(project: String, workspace: String) -> [String] {
        let projectTrimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceTrimmed = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        var keys: [String] = [
            "\(project)/\(workspace)",
            "\(projectTrimmed)/\(workspaceTrimmed)"
        ]
        if workspaceTrimmed.caseInsensitiveCompare("default") == .orderedSame {
            keys.append("\(project)/(default)")
            keys.append("\(projectTrimmed)/(default)")
        }

        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    func parseEvolutionProfileStorageKey(_ key: String) -> (project: String, workspace: String)? {
        let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    func shouldPreferEvolutionProfiles(
        candidate: [EvolutionStageProfileInfoV2],
        over existing: [EvolutionStageProfileInfoV2]
    ) -> Bool {
        if existing.isEmpty { return true }
        // 客户端设置（用户显式配置）始终优先于服务端同步配置，确保 settings 中的工具选择
        // 在不同项目下都能正确反映到 AI 工具图标和运行逻辑中
        return !candidate.isEmpty
    }

    func isDefaultEvolutionProfiles(_ profiles: [EvolutionStageProfileInfoV2]) -> Bool {
        guard profiles.count == Self.defaultEvolutionProfiles().count else { return false }
        for profile in profiles {
            if profile.aiTool != .codex { return false }
            if let mode = profile.mode, !mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            if profile.model != nil { return false }
            if !profile.configOptions.isEmpty { return false }
        }
        return true
    }

    func markEvolutionProviderListLoaded(project: String, workspace: String, aiTool: AIChatTool) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        guard var byTool = evolutionSelectorLoadStateByWorkspace[key] else { return }
        var state = byTool[aiTool] ?? (providerLoaded: false, agentLoaded: false)
        state.providerLoaded = true
        byTool[aiTool] = state
        evolutionSelectorLoadStateByWorkspace[key] = byTool
        maybeRequestEvolutionProfileAfterSelectorsReady(project: project, workspace: normalizedWorkspace)
    }

    func markEvolutionAgentListLoaded(project: String, workspace: String, aiTool: AIChatTool) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        guard var byTool = evolutionSelectorLoadStateByWorkspace[key] else { return }
        var state = byTool[aiTool] ?? (providerLoaded: false, agentLoaded: false)
        state.agentLoaded = true
        byTool[aiTool] = state
        evolutionSelectorLoadStateByWorkspace[key] = byTool
        maybeRequestEvolutionProfileAfterSelectorsReady(project: project, workspace: normalizedWorkspace)
    }

    func maybeRequestEvolutionProfileAfterSelectorsReady(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        guard evolutionPendingProfileReloadWorkspaces.contains(key) else { return }
        guard let byTool = evolutionSelectorLoadStateByWorkspace[key] else { return }
        let allReady = AIChatTool.allCases.allSatisfy { tool in
            let state = byTool[tool]
            return (state?.providerLoaded == true) && (state?.agentLoaded == true)
        }
        guard allReady else { return }
        requestEvolutionProfileIfPending(project: project, workspace: normalizedWorkspace)
    }

    func scheduleEvolutionProfileReloadFallback(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        evolutionProfileReloadFallbackTimers[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.requestEvolutionProfileIfPending(project: project, workspace: normalizedWorkspace)
        }
        evolutionProfileReloadFallbackTimers[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func requestEvolutionProfileIfPending(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        guard evolutionPendingProfileReloadWorkspaces.contains(key) else { return }
        finishEvolutionProfileReloadTracking(project: project, workspace: normalizedWorkspace)
        wsClient.requestEvoGetAgentProfile(project: project, workspace: normalizedWorkspace)
    }

    func finishEvolutionProfileReloadTracking(project: String, workspace: String) {
        let normalizedWorkspace = normalizeEvolutionWorkspaceName(workspace)
        let key = globalWorkspaceKey(projectName: project, workspaceName: normalizedWorkspace)
        evolutionPendingProfileReloadWorkspaces.remove(key)
        if let work = evolutionProfileReloadFallbackTimers[key] {
            work.cancel()
            evolutionProfileReloadFallbackTimers[key] = nil
        }
    }

    func consumeEvolutionReplayMessagesIfNeeded(_ ev: AISessionMessagesV2) -> Bool {
        guard let request = evolutionReplayRequest else { return false }
        guard request.project == ev.projectName,
              normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(ev.workspaceName),
              request.aiTool == ev.aiTool,
              request.sessionId == ev.sessionId else { return false }
        evolutionReplayStore.setCurrentSessionId(ev.sessionId)
        evolutionReplayStore.replaceMessages(ev.toChatMessages())
        evolutionReplayLoading = false
        evolutionReplayError = nil
        return true
    }

    func consumeEvolutionReplayMessagesUpdateIfNeeded(_ ev: AISessionMessagesUpdateV2) -> Bool {
        guard matchesEvolutionReplayContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return false }
        if evolutionReplayStore.currentSessionId != ev.sessionId {
            evolutionReplayStore.setCurrentSessionId(ev.sessionId)
        }
        if evolutionReplayStore.isAbortPending(for: ev.sessionId) { return true }
        guard evolutionReplayStore.shouldApplySessionCacheRevision(
            ev.cacheRevision,
            sessionId: ev.sessionId
        ) else {
            return true
        }

        if let messages = ev.messages {
            evolutionReplayStore.replaceMessagesFromSessionCache(messages, isStreaming: ev.isStreaming)
            let restoredQuestions = Self.rebuildPendingQuestionRequests(
                sessionId: ev.sessionId,
                messages: messages
            )
            evolutionReplayStore.replaceQuestionRequests(restoredQuestions)
        } else if let ops = ev.ops {
            evolutionReplayStore.applySessionCacheOps(ops, isStreaming: ev.isStreaming)
        } else if !ev.isStreaming {
            evolutionReplayStore.applySessionCacheOps([], isStreaming: false)
        }
        evolutionReplayLoading = false
        evolutionReplayError = nil
        return true
    }

    func consumeEvolutionReplayDoneIfNeeded(_ ev: AIChatDoneV2) {
        guard matchesEvolutionReplayContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if evolutionReplayStore.currentSessionId != ev.sessionId {
            evolutionReplayStore.setCurrentSessionId(ev.sessionId)
        }
        evolutionReplayStore.handleChatDone(sessionId: ev.sessionId)
        evolutionReplayLoading = false
    }

    func consumeEvolutionReplayErrorIfNeeded(_ ev: AIChatErrorV2) {
        guard matchesEvolutionReplayContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if evolutionReplayStore.currentSessionId != ev.sessionId {
            evolutionReplayStore.setCurrentSessionId(ev.sessionId)
        }
        evolutionReplayStore.handleChatError(sessionId: ev.sessionId, error: ev.error)
        evolutionReplayLoading = false
    }

    func matchesEvolutionReplayContext(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> Bool {
        guard let request = evolutionReplayRequest else { return false }
        return request.project == project &&
            normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(workspace) &&
            request.aiTool == aiTool &&
            request.sessionId == sessionId
    }

    func consumeSubAgentViewerMessagesIfNeeded(_ ev: AISessionMessagesV2) -> Bool {
        guard let request = subAgentViewerRequest else { return false }
        guard request.project == ev.projectName,
              normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(ev.workspaceName),
              request.aiTool == ev.aiTool,
              request.sessionId == ev.sessionId else { return false }
        subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        subAgentViewerStore.replaceMessages(ev.toChatMessages())
        subAgentViewerLoading = false
        subAgentViewerError = nil
        return true
    }

    func consumeSubAgentViewerMessagesUpdateIfNeeded(_ ev: AISessionMessagesUpdateV2) -> Bool {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return false }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        if subAgentViewerStore.isAbortPending(for: ev.sessionId) { return true }
        guard subAgentViewerStore.shouldApplySessionCacheRevision(
            ev.cacheRevision,
            sessionId: ev.sessionId
        ) else {
            return true
        }

        if let messages = ev.messages {
            subAgentViewerStore.replaceMessagesFromSessionCache(messages, isStreaming: ev.isStreaming)
            let restoredQuestions = Self.rebuildPendingQuestionRequests(
                sessionId: ev.sessionId,
                messages: messages
            )
            subAgentViewerStore.replaceQuestionRequests(restoredQuestions)
        } else if let ops = ev.ops {
            subAgentViewerStore.applySessionCacheOps(ops, isStreaming: ev.isStreaming)
        } else if !ev.isStreaming {
            subAgentViewerStore.applySessionCacheOps([], isStreaming: false)
        }
        subAgentViewerLoading = false
        subAgentViewerError = nil
        return true
    }

    func consumeSubAgentViewerDoneIfNeeded(_ ev: AIChatDoneV2) {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        subAgentViewerStore.handleChatDone(sessionId: ev.sessionId)
        subAgentViewerLoading = false
    }

    func consumeSubAgentViewerErrorIfNeeded(_ ev: AIChatErrorV2) {
        guard matchesSubAgentViewerContext(
            project: ev.projectName,
            workspace: ev.workspaceName,
            aiTool: ev.aiTool,
            sessionId: ev.sessionId
        ) else { return }
        if subAgentViewerStore.currentSessionId != ev.sessionId {
            subAgentViewerStore.setCurrentSessionId(ev.sessionId)
        }
        subAgentViewerStore.handleChatError(sessionId: ev.sessionId, error: ev.error)
        subAgentViewerLoading = false
        subAgentViewerError = ev.error
    }

    func matchesSubAgentViewerContext(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> Bool {
        guard let request = subAgentViewerRequest else { return false }
        return request.project == project &&
            normalizeEvolutionWorkspaceName(request.workspace) == normalizeEvolutionWorkspaceName(workspace) &&
            request.aiTool == aiTool &&
            request.sessionId == sessionId
    }
}
