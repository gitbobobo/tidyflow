import Foundation

extension AppState {
    /// Spawn a terminal tab and run a command (UX-3a: AI Resolve)
    func spawnTerminalWithCommand(workspaceKey: String, command: String) {
        // Create a new terminal tab
        let newTab = TabModel(
            id: UUID(),
            title: "AI Resolve",
            kind: .terminal,
            workspaceKey: workspaceKey,
            payload: command  // Store command in payload for later execution
        )

        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }
        workspaceTabs[workspaceKey]?.append(newTab)
        activeTabIdByWorkspace[workspaceKey] = newTab.id

        // 记录工作空间首次打开终端的时间（用于自动快捷键排序）
        if workspaceTerminalOpenTime[workspaceKey] == nil {
            workspaceTerminalOpenTime[workspaceKey] = Date()
        }

        // The terminal view will check payload and execute the command after spawn
        // This is handled by the terminal bridge when it detects a non-empty payload
    }
    
    func addEditorTab(workspaceKey: String, path: String, line: Int? = nil) {
        // Check if editor tab for this path already exists
        if let tabs = workspaceTabs[workspaceKey],
           let existingTab = tabs.first(where: { $0.kind == .editor && $0.payload == path }) {
            // Activate existing tab
            activeTabIdByWorkspace[workspaceKey] = existingTab.id
            // Set pending reveal if line specified
            if let line = line {
                pendingEditorReveal = (path: path, line: line, highlightMs: 2000)
            }
            return
        }
        // Create new tab
        addTab(workspaceKey: workspaceKey, kind: .editor, title: path, payload: path)
        // Set pending reveal if line specified
        if let line = line {
            pendingEditorReveal = (path: path, line: line, highlightMs: 2000)
        }
    }
    
    func addDiffTab(workspaceKey: String, path: String, mode: DiffMode = .working) {
        // Check if diff tab for this path already exists
        if let tabs = workspaceTabs[workspaceKey],
           let existingTab = tabs.first(where: { $0.kind == .diff && $0.payload == path }) {
            // Activate existing tab and update mode
            activeTabIdByWorkspace[workspaceKey] = existingTab.id
            // Update diff mode if different
            if existingTab.diffMode != mode.rawValue {
                if var tabs = workspaceTabs[workspaceKey],
                   let index = tabs.firstIndex(where: { $0.id == existingTab.id }) {
                    tabs[index].diffMode = mode.rawValue
                    workspaceTabs[workspaceKey] = tabs
                }
            }
            return
        }

        // Create new diff tab
        var newTab = TabModel(
            id: UUID(),
            title: "Diff: \(path.split(separator: "/").last ?? Substring(path))",
            kind: .diff,
            workspaceKey: workspaceKey,
            payload: path
        )
        newTab.diffMode = mode.rawValue

        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }

        workspaceTabs[workspaceKey]?.append(newTab)
        activeTabIdByWorkspace[workspaceKey] = newTab.id
    }

    /// Close all diff tabs for a workspace (used after branch switch)
    func closeAllDiffTabs(workspaceKey: String) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        let diffTabIds = tabs.filter { $0.kind == .diff }.map { $0.id }
        for tabId in diffTabIds {
            closeTab(workspaceKey: workspaceKey, tabId: tabId)
        }
    }

    /// Close diff tab for a specific path (used when file is discarded)
    func closeDiffTab(workspaceKey: String, path: String) {
        guard let tabs = workspaceTabs[workspaceKey],
              let tab = tabs.first(where: { $0.kind == .diff && $0.payload == path }) else {
            return
        }
        closeTab(workspaceKey: workspaceKey, tabId: tab.id)
    }

    func nextTab() {
        guard let ws = currentGlobalWorkspaceKey,
              let tabs = workspaceTabs[ws], !tabs.isEmpty,
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId }) else { return }
        
        let nextIndex = (index + 1) % tabs.count
        activeTabIdByWorkspace[ws] = tabs[nextIndex].id
    }
    
    func prevTab() {
        guard let ws = currentGlobalWorkspaceKey,
              let tabs = workspaceTabs[ws], !tabs.isEmpty,
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId }) else { return }

        let prevIndex = (index - 1 + tabs.count) % tabs.count
        activeTabIdByWorkspace[ws] = tabs[prevIndex].id
    }

    /// 按索引切换 Tab，index 1-9 对应第 1-9 个 Tab
    func switchToTabByIndex(_ index: Int) {
        guard let ws = currentGlobalWorkspaceKey,
              let tabs = workspaceTabs[ws], !tabs.isEmpty else { return }

        let targetIndex = index - 1

        guard targetIndex >= 0 && targetIndex < tabs.count else { return }
        activeTabIdByWorkspace[ws] = tabs[targetIndex].id
    }

    // MARK: - Editor Bridge Helpers

    /// Get the active tab for the current workspace
    func getActiveTab() -> TabModel? {
        guard let ws = currentGlobalWorkspaceKey,
              let activeId = activeTabIdByWorkspace[ws],
              let tabs = workspaceTabs[ws] else { return nil }
        return tabs.first { $0.id == activeId }
    }

    /// Check if active tab is an editor tab
    var isActiveTabEditor: Bool {
        getActiveTab()?.kind == .editor
    }

    /// Get the file path of the active editor tab
    var activeEditorPath: String? {
        guard let tab = getActiveTab(), tab.kind == .editor else { return nil }
        return tab.payload
    }

    /// Save the active editor file (called by Cmd+S)
    func saveActiveEditorFile() {
        guard let path = activeEditorPath else {
            return
        }
        // The actual save is triggered via WebBridge in CenterContentView
        // This just sets the intent; the view will handle the bridge call
        lastEditorPath = path
        editorStatus = "Saving..."
        editorStatusIsError = false
        NotificationCenter.default.post(name: .saveEditorFile, object: path)
    }

    /// Update editor status after save result
    func handleEditorSaved(path: String) {
        editorStatus = "Saved"
        editorStatusIsError = false
        // 保存成功后清除 dirty 状态
        updateEditorDirtyState(path: path, isDirty: false)
        // 如果有待关闭的 Tab（保存后关闭流程），执行关闭
        if let pending = pendingCloseAfterSave {
            pendingCloseAfterSave = nil
            performCloseTab(workspaceKey: pending.workspaceKey, tabId: pending.tabId)
        }
        // Clear status after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.editorStatus == "Saved" {
                self?.editorStatus = ""
            }
        }
    }

    func handleEditorSaveError(path: String, message: String) {
        editorStatus = "Error: \(message)"
        editorStatusIsError = true
        // 保存失败时清除待关闭状态
        pendingCloseAfterSave = nil
    }

    /// 更新编辑器 Tab 的 dirty 状态
    func updateEditorDirtyState(path: String, isDirty: Bool) {
        guard let globalKey = currentGlobalWorkspaceKey else { return }
        guard var tabs = workspaceTabs[globalKey] else { return }
        if let index = tabs.firstIndex(where: { $0.kind == .editor && $0.payload == path }) {
            tabs[index].isDirty = isDirty
            workspaceTabs[globalKey] = tabs
        }
    }

    /// 保存并关闭 Tab（用于未保存确认对话框的"保存"按钮）
    func saveAndCloseTab(workspaceKey: String, tabId: UUID) {
        guard let tabs = workspaceTabs[workspaceKey],
              let tab = tabs.first(where: { $0.id == tabId }),
              tab.kind == .editor else { return }
        pendingCloseAfterSave = (workspaceKey: workspaceKey, tabId: tabId)
        // 触发保存
        lastEditorPath = tab.payload
        editorStatus = "Saving..."
        editorStatusIsError = false
        NotificationCenter.default.post(name: .saveEditorFile, object: tab.payload)
    }

    /// Check if active tab is a diff tab
    var isActiveTabDiff: Bool {
        getActiveTab()?.kind == .diff
    }

    /// Get the file path of the active diff tab
    var activeDiffPath: String? {
        guard let tab = getActiveTab(), tab.kind == .diff else { return nil }
        return tab.payload
    }

    /// Get the diff mode of the active diff tab
    var activeDiffMode: DiffMode {
        guard let tab = getActiveTab(), tab.kind == .diff,
              let modeStr = tab.diffMode,
              let mode = DiffMode(rawValue: modeStr) else { return .working }
        return mode
    }

    /// Update diff mode for active diff tab
    func setActiveDiffMode(_ mode: DiffMode) {
        guard let ws = currentGlobalWorkspaceKey,
              var tabs = workspaceTabs[ws],
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId && $0.kind == .diff }) else { return }

        tabs[index].diffMode = mode.rawValue
        workspaceTabs[ws] = tabs
    }

    /// Get the diff view mode of the active diff tab
    var activeDiffViewMode: DiffViewMode {
        guard let tab = getActiveTab(), tab.kind == .diff,
              let modeStr = tab.diffViewMode,
              let mode = DiffViewMode(rawValue: modeStr) else { return .unified }
        return mode
    }

    /// Update diff view mode for active diff tab
    func setActiveDiffViewMode(_ mode: DiffViewMode) {
        guard let ws = currentGlobalWorkspaceKey,
              var tabs = workspaceTabs[ws],
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId && $0.kind == .diff }) else { return }

        tabs[index].diffViewMode = mode.rawValue
        workspaceTabs[ws] = tabs
    }

    // MARK: - Phase C1-2: Terminal State Helpers (Multi-Session)

    /// Check if active tab is a terminal tab
    var isActiveTabTerminal: Bool {
        getActiveTab()?.kind == .terminal
    }

    /// Get the session ID for a specific terminal tab
    func getTerminalSessionId(for tabId: UUID) -> String? {
        return terminalSessionByTabId[tabId]
    }

    /// Get the session ID for the active terminal tab
    var activeTerminalSessionId: String? {
        guard let tab = getActiveTab(), tab.kind == .terminal else { return nil }
        return terminalSessionByTabId[tab.id]
    }

    /// Handle terminal ready event from WebBridge (with tabId)
    func handleTerminalReady(tabId: String, sessionId: String, project: String, workspace: String, webBridge: WebBridge?) {
        guard let uuid = UUID(uuidString: tabId) else {
            TFLog.app.error("Invalid tabId: \(tabId, privacy: .public)")
            return
        }

        // 兜底：若某些入口未提前记录，则在终端 ready 时补齐首次打开时间
        let globalKey = globalWorkspaceKey(projectName: project, workspaceName: workspace)
        if workspaceTerminalOpenTime[globalKey] == nil {
            workspaceTerminalOpenTime[globalKey] = Date()
        }

        // Update session mapping
        terminalSessionByTabId[uuid] = sessionId
        staleTerminalTabs.remove(uuid)
        pendingSpawnTabs.remove(uuid)  // 移除 pending 标记

        // Update tab's terminalSessionId（使用服务端返回的 project 和 workspace 生成全局键）
        if var tabs = workspaceTabs[globalKey],
           let index = tabs.firstIndex(where: { $0.id == uuid }) {
            tabs[index].terminalSessionId = sessionId
            workspaceTabs[globalKey] = tabs
            
            // 检查 tab 的 payload，如果非空则执行自定义命令
            let payload = tabs[index].payload
            if !payload.isEmpty, let bridge = webBridge {
                bridge.terminalSendInput(sessionId: sessionId, input: payload)
                
                // 清空 payload，防止 attach 时重复执行命令
                tabs[index].payload = ""
                workspaceTabs[globalKey] = tabs
            }
        }

        // Update global terminal state for status bar
        terminalState = .ready(sessionId: sessionId)
    }

    /// Handle terminal closed event from WebBridge
    func handleTerminalClosed(tabId: String, sessionId: String, code: Int?) {
        guard let uuid = UUID(uuidString: tabId) else { return }

        // Remove session mapping
        terminalSessionByTabId.removeValue(forKey: uuid)

        // Update tab's terminalSessionId（搜索所有工作空间的 tabs）
        for (globalKey, var tabs) in workspaceTabs {
            if let index = tabs.firstIndex(where: { $0.id == uuid }) {
                tabs[index].terminalSessionId = nil
                workspaceTabs[globalKey] = tabs
                break
            }
        }
    }

    /// Handle terminal error event from WebBridge
    func handleTerminalError(tabId: String?, message: String) {
        terminalState = .error(message: message)
        TFLog.app.error("Terminal error: \(message, privacy: .public)")
    }

    /// Handle terminal connected event
    func handleTerminalConnected() {
        // Clear error state when reconnected
        if case .error = terminalState {
            terminalState = .idle
        }
    }

    /// Mark all terminal sessions as stale (on disconnect)
    func markAllTerminalSessionsStale() {
        for tabId in terminalSessionByTabId.keys {
            staleTerminalTabs.insert(tabId)
        }
        terminalSessionByTabId.removeAll()
        terminalState = .idle
    }

    /// Check if a terminal tab needs respawn
    func terminalNeedsRespawn(_ tabId: UUID) -> Bool {
        return staleTerminalTabs.contains(tabId) || terminalSessionByTabId[tabId] == nil
    }

    /// Request terminal for current workspace (legacy, for status)
    func requestTerminal() {
        terminalState = .connecting
    }
}
