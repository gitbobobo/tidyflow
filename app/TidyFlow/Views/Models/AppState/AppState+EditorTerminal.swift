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

        // 终端会在视图出现时创建/附着
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
        guard let path = activeEditorPath,
              let workspace = selectedWorkspaceKey else {
            return
        }
        saveEditorDocument(project: selectedProjectName, workspace: workspace, path: path)
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
        let parts = workspaceKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            pendingCloseAfterSave = nil
            return
        }
        saveEditorDocument(project: parts[0], workspace: parts[1], path: tab.payload)
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

    // MARK: - Terminal State Helpers

    /// Check if active tab is a terminal tab
    var isActiveTabTerminal: Bool {
        getActiveTab()?.kind == .terminal
    }

    /// Get the term_id for a specific terminal tab
    func getTerminalSessionId(for tabId: UUID) -> String? {
        return terminalSessionByTabId[tabId]
    }

    /// Get the term_id for the active terminal tab
    var activeTerminalSessionId: String? {
        guard let tab = getActiveTab(), tab.kind == .terminal else { return nil }
        return terminalSessionByTabId[tab.id]
    }

    func handleTermCreated(_ result: TermCreatedResult) {
        guard let tabId = pendingSpawnTabs.first else {
            TFLog.app.warning("收到 term_created 但没有 pending 终端 tab")
            return
        }
        let globalKey = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        bindTermToTab(tabId: tabId, termId: result.termId, globalKey: globalKey)
        wsClient.requestTermAttach(termId: result.termId)
        wsClient.requestTermList()
    }

    func handleTermAttached(_ result: TermAttachedResult) {
        guard let tabId = findTabIdByTermId(result.termId) else {
            TFLog.app.warning("收到 term_attached 但未找到 tab，term=\(result.termId, privacy: .public)")
            return
        }
        terminalState = .ready(sessionId: result.termId)
        if !result.scrollback.isEmpty {
            emitTerminalOutput(termId: result.termId, bytes: result.scrollback)
            wsClient.sendTermOutputAck(termId: result.termId, bytes: result.scrollback.count)
            termOutputUnackedBytes = 0
        }
        if let sink = terminalSink, terminalSinkTabId == tabId {
            sink.focusTerminal()
        }
        tryRunPendingCommandIfNeeded(tabId: tabId, termId: result.termId)
    }

    func handleTerminalOutput(termId: String?, bytes: [UInt8]) {
        guard let termId else { return }
        emitTerminalOutput(termId: termId, bytes: bytes)
    }

    func handleTerminalExit(termId: String?, code: Int) {
        guard let termId else { return }
        TFLog.app.info("终端退出: term=\(termId, privacy: .public), code=\(code)")
    }

    func handleTermClosed(_ termId: String) {
        if let tabId = terminalTabIdBySessionId.removeValue(forKey: termId) {
            terminalSessionByTabId.removeValue(forKey: tabId)
            staleTerminalTabs.remove(tabId)
            for (globalKey, var tabs) in workspaceTabs {
                if let index = tabs.firstIndex(where: { $0.id == tabId }) {
                    tabs[index].terminalSessionId = nil
                    workspaceTabs[globalKey] = tabs
                    break
                }
            }
            if terminalSinkTabId == tabId {
                terminalSink?.resetTerminal()
            }
            wsClient.requestTermList()
            return
        }

        // 兼容历史状态：反向映射缺失时做一次兜底扫描并回填。
        for (globalKey, var tabs) in workspaceTabs {
            if let index = tabs.firstIndex(where: { $0.terminalSessionId == termId }) {
                let tabId = tabs[index].id
                terminalSessionByTabId.removeValue(forKey: tabId)
                staleTerminalTabs.remove(tabId)
                terminalTabIdBySessionId.removeValue(forKey: termId)
                tabs[index].terminalSessionId = nil
                workspaceTabs[globalKey] = tabs
                if terminalSinkTabId == tabId {
                    terminalSink?.resetTerminal()
                }
                break
            }
        }
        wsClient.requestTermList()
    }

    /// Mark all terminal sessions as stale (on disconnect)
    func markAllTerminalSessionsStale() {
        for tabId in terminalSessionByTabId.keys {
            staleTerminalTabs.insert(tabId)
        }
        terminalSessionByTabId.removeAll()
        terminalTabIdBySessionId.removeAll()
        terminalState = .idle
    }

    func requestTerminalReattach() {
        guard !staleTerminalTabs.isEmpty else { return }

        for (_, tabs) in workspaceTabs {
            for tab in tabs where tab.kind == .terminal && staleTerminalTabs.contains(tab.id) {
                if let sessionId = tab.terminalSessionId, !sessionId.isEmpty {
                    TFLog.app.info("终端重连附着: tab=\(tab.id), session=\(sessionId, privacy: .public)")
                    wsClient.requestTermAttach(termId: sessionId)
                }
            }
        }
    }

    /// Check if a terminal tab needs respawn
    func terminalNeedsRespawn(_ tabId: UUID) -> Bool {
        return staleTerminalTabs.contains(tabId) || terminalSessionByTabId[tabId] == nil
    }

    /// Request terminal for current workspace (legacy, for status)
    func requestTerminal() {
        terminalState = .connecting
    }

    func ensureTerminalForTab(_ tab: TabModel) {
        guard tab.kind == .terminal else { return }
        let globalKey = tab.workspaceKey
        let parts = globalKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let project = parts[0]
        let workspace = parts[1]

        if let termId = terminalSessionByTabId[tab.id], !termId.isEmpty {
            terminalTabIdBySessionId[termId] = tab.id
            wsClient.requestTermAttach(termId: termId)
            requestTerminal()
            return
        }

        pendingSpawnTabs.insert(tab.id)
        requestTerminal()
        let icon = tab.commandIcon
        let name = (tab.kind == .terminal && !tab.title.isEmpty && tab.title != "Terminal") ? tab.title : nil
        wsClient.requestTermCreate(
            project: project,
            workspace: workspace,
            name: name,
            icon: icon
        )
    }

    func sendTerminalInputBytes(tabId: UUID, _ bytes: [UInt8]) {
        guard let termId = terminalSessionByTabId[tabId], !termId.isEmpty else { return }
        wsClient.sendTerminalInput(bytes, termId: termId)
    }

    func terminalViewDidResize(tabId: UUID, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard let termId = terminalSessionByTabId[tabId], !termId.isEmpty else { return }
        wsClient.requestTermResize(termId: termId, cols: cols, rows: rows)
    }

    #if os(macOS)
    func attachTerminalSink(_ sink: MacTerminalOutputSink, tabId: UUID) {
        terminalSink = sink
        terminalSinkTabId = tabId
        sink.resetTerminal()
        flushPendingTerminalOutput()
    }

    func detachTerminalSink(_ sink: MacTerminalOutputSink? = nil, tabId: UUID) {
        if let sink, let current = terminalSink, current !== sink {
            return
        }
        if terminalSinkTabId == tabId {
            terminalSink = nil
            terminalSinkTabId = nil
            pendingTerminalOutput.removeAll()
            termOutputUnackedBytes = 0
        }
    }
    #endif

    private func bindTermToTab(tabId: UUID, termId: String, globalKey: String) {
        if let oldTermId = terminalSessionByTabId[tabId], oldTermId != termId {
            terminalTabIdBySessionId.removeValue(forKey: oldTermId)
        }
        if let oldTabId = terminalTabIdBySessionId[termId], oldTabId != tabId {
            terminalSessionByTabId.removeValue(forKey: oldTabId)
            staleTerminalTabs.insert(oldTabId)
        }
        terminalSessionByTabId[tabId] = termId
        terminalTabIdBySessionId[termId] = tabId
        staleTerminalTabs.remove(tabId)
        pendingSpawnTabs.remove(tabId)
        if workspaceTerminalOpenTime[globalKey] == nil {
            workspaceTerminalOpenTime[globalKey] = Date()
        }
        if var tabs = workspaceTabs[globalKey],
           let index = tabs.firstIndex(where: { $0.id == tabId }) {
            tabs[index].terminalSessionId = termId
            workspaceTabs[globalKey] = tabs
        }
    }

    private func findTabIdByTermId(_ termId: String) -> UUID? {
        if let tabId = terminalTabIdBySessionId[termId] {
            return tabId
        }
        if let hit = terminalSessionByTabId.first(where: { $0.value == termId }) {
            terminalTabIdBySessionId[termId] = hit.key
            return hit.key
        }
        for (_, tabs) in workspaceTabs {
            if let tab = tabs.first(where: { $0.kind == .terminal && $0.terminalSessionId == termId }) {
                terminalTabIdBySessionId[termId] = tab.id
                return tab.id
            }
        }
        return nil
    }

    private func emitTerminalOutput(termId: String, bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        guard let tabId = findTabIdByTermId(termId), terminalSinkTabId == tabId else { return }

        if let sink = terminalSink {
            sink.writeOutput(bytes)
        } else {
            pendingTerminalOutput.append(bytes)
            if pendingTerminalOutput.count > pendingOutputChunkLimit {
                pendingTerminalOutput.removeFirst(pendingTerminalOutput.count - pendingOutputChunkLimit)
            }
        }

        termOutputUnackedBytes += bytes.count
        if termOutputUnackedBytes >= termOutputAckThreshold {
            wsClient.sendTermOutputAck(termId: termId, bytes: termOutputUnackedBytes)
            termOutputUnackedBytes = 0
        }
    }

    private func flushPendingTerminalOutput() {
        guard let sink = terminalSink else { return }
        guard !pendingTerminalOutput.isEmpty else { return }
        for chunk in pendingTerminalOutput {
            sink.writeOutput(chunk)
        }
        pendingTerminalOutput.removeAll()
    }

    private func tryRunPendingCommandIfNeeded(tabId: UUID, termId: String) {
        for (globalKey, var tabs) in workspaceTabs {
            guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { continue }
            let payload = tabs[index].payload
            guard !payload.isEmpty else { return }
            wsClient.sendTerminalInput(payload + "\n", termId: termId)
            tabs[index].payload = ""
            workspaceTabs[globalKey] = tabs
            return
        }
    }
}
