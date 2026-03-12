import Foundation

extension AppState {
    /// Spawn a terminal tab and run a command (UX-3a: AI Resolve)
    func spawnTerminalWithCommand(workspaceKey: String, command: String) {
        let newTab = TabModel(
            id: UUID(),
            title: "AI Resolve",
            kind: .terminal,
            workspaceKey: workspaceKey,
            payload: command
        )
        appendAndActivateTab(newTab, workspaceKey: workspaceKey)
    }
    
    func addEditorTab(workspaceKey: String, path: String, line: Int? = nil) {
        // Check if editor tab for this path already exists
        if let tabs = workspaceTabs[workspaceKey],
           let existingTab = tabs.first(where: { $0.kind == .editor && $0.payload == path }) {
            activateTab(workspaceKey: workspaceKey, tabId: existingTab.id)
            if let line = line {
                pendingEditorReveal = (path: path, line: line, highlightMs: 2000)
            }
            return
        }
        addTab(workspaceKey: workspaceKey, kind: .editor, title: path, payload: path)
        if let line = line {
            pendingEditorReveal = (path: path, line: line, highlightMs: 2000)
        }
    }
    
    func addDiffTab(workspaceKey: String, path: String, mode: DiffMode = .working) {
        // Check if diff tab for this path already exists
        if let tabs = workspaceTabs[workspaceKey],
           let existingTab = tabs.first(where: { $0.kind == .diff && $0.payload == path }) {
            activateTab(workspaceKey: workspaceKey, tabId: existingTab.id)
            if existingTab.diffMode != mode.rawValue {
                if var tabs = workspaceTabs[workspaceKey],
                   let index = tabs.firstIndex(where: { $0.id == existingTab.id }) {
                    tabs[index].diffMode = mode.rawValue
                    workspaceTabs[workspaceKey] = tabs
                }
            }
            return
        }

        var newTab = TabModel(
            id: UUID(),
            title: "Diff: \(path.split(separator: "/").last ?? Substring(path))",
            kind: .diff,
            workspaceKey: workspaceKey,
            payload: path
        )
        newTab.diffMode = mode.rawValue

        appendAndActivateTab(newTab, workspaceKey: workspaceKey)
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

    // MARK: - Editor Bridge Helpers

    /// Get the active tab for the current workspace
    func getActiveTab() -> TabModel? {
        guard let ws = currentGlobalWorkspaceKey else { return nil }
        return displayedBottomPanelTab(workspaceKey: ws)
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

    // MARK: - 新建文件与另存为

    /// 创建新的未命名编辑器文件
    func createNewEditorFile() {
        guard let globalKey = currentGlobalWorkspaceKey else { return }
        let untitledName = editorStore.generateUntitledFileName()

        // 在文档状态中创建一个未保存的新文档
        var workspaceDocs = editorDocumentsByWorkspace[globalKey] ?? [:]
        workspaceDocs[untitledName] = EditorDocumentState(
            path: untitledName,
            content: "",
            originalContentHash: 0,  // 空内容的 hash
            isDirty: true,  // 新文件标记为 dirty，需要保存
            lastLoadedAt: Date(),
            status: .ready,
            conflictState: .none
        )
        editorDocumentsByWorkspace[globalKey] = workspaceDocs

        // 创建新的编辑器 Tab
        addTab(workspaceKey: globalKey, kind: .editor, title: untitledName, payload: untitledName)
    }

    /// 请求另存为当前活动编辑器
    func requestSaveAsForActiveEditor() {
        guard let globalKey = currentGlobalWorkspaceKey,
              let path = activeEditorPath else { return }

        editorStore.pendingSaveAsPath = path
        editorStore.pendingSaveAsWorkspaceKey = globalKey
        editorStore.showSaveAsPanel = true
    }

    /// 执行另存为操作（在用户选择了目标路径后调用）
    func performSaveAs(newPath: String) {
        guard let globalKey = editorStore.pendingSaveAsWorkspaceKey,
              let oldPath = editorStore.pendingSaveAsPath,
              var workspaceDocs = editorDocumentsByWorkspace[globalKey],
              let oldDoc = workspaceDocs[oldPath] else { return }

        // 创建新文档（使用新路径）
        let newDoc = EditorDocumentState(
            path: newPath,
            content: oldDoc.content,
            originalContentHash: 0,  // 新文件，需要保存
            isDirty: true,
            lastLoadedAt: Date(),
            status: .ready,
            conflictState: .none
        )
        workspaceDocs.removeValue(forKey: oldPath)
        workspaceDocs[newPath] = newDoc
        editorDocumentsByWorkspace[globalKey] = workspaceDocs

        // 更新 Tab 标题和 payload
        if var tabs = workspaceTabs[globalKey],
           let tabIndex = tabs.firstIndex(where: { $0.kind == .editor && $0.payload == oldPath }) {
            tabs[tabIndex].payload = newPath
            tabs[tabIndex].title = String(newPath.split(separator: "/").last ?? Substring(newPath))
            workspaceTabs[globalKey] = tabs
        }

        // 清除另存为状态
        editorStore.pendingSaveAsPath = nil
        editorStore.pendingSaveAsWorkspaceKey = nil
        editorStore.showSaveAsPanel = false

        // 执行保存
        let parts = globalKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        saveEditorDocument(project: parts[0], workspace: parts[1], path: newPath)
    }

    /// 取消另存为操作
    func cancelSaveAs() {
        editorStore.pendingSaveAsPath = nil
        editorStore.pendingSaveAsWorkspaceKey = nil
        editorStore.showSaveAsPanel = false
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

        // 驱动共享终端生命周期：entering → active
        terminalSessionStore.beginCreate(project: result.project, workspace: result.workspace, termId: result.termId)

        // 通过共享终端存储记录 attach 请求时间
        terminalSessionStore.recordAttachRequest(termId: result.termId)
        wsClient.requestTermAttach(termId: result.termId)
        wsClient.requestTermList()
    }

    func handleTermAttached(_ result: TermAttachedResult) {
        guard let tabId = findTabIdByTermId(result.termId) else {
            TFLog.app.warning("收到 term_attached 但未找到 tab，term=\(result.termId, privacy: .public)")
            return
        }
        // 通过共享终端存储处理 attach 完成（含 RTT 日志）
        if let rtt = terminalSessionStore.handleTermAttached(result: result) {
            let costMs = Int(rtt * 1000)
            TFLog.app.info("perf.terminal.attach.rtt_ms=\(costMs, privacy: .public) term=\(result.termId, privacy: .public)")
        }
        terminalState = .ready(sessionId: result.termId)
        if !result.scrollback.isEmpty {
            emitTerminalOutput(termId: result.termId, bytes: result.scrollback)
            wsClient.sendTermOutputAck(termId: result.termId, bytes: result.scrollback.count)
            terminalSessionStore.resetUnackedBytes(for: result.termId)
        }
        if let sink = terminalSink, terminalSinkTabId == tabId {
            sink.focusTerminal()
        }
        tryRunPendingCommandIfNeeded(tabId: tabId, termId: result.termId)
    }

    func handleTerminalOutput(termId: String?, bytes: [UInt8]) {
        guard let termId else { return }
        // 只接受处于 active 或 entering 相位的终端输出；
        // 已关闭或处于 idle/resuming 的终端输出被忽略（防止迟到事件污染）
        let phase = terminalSessionStore.lifecyclePhase(for: termId)
        guard phase == .active || phase == .entering else {
            TFLog.app.debug("忽略终端输出: term=\(termId, privacy: .public) phase=\(String(describing: phase), privacy: .public)")
            return
        }
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
            clearPendingTerminalOutput(termId: termId)
            // 通过共享终端存储清理所有与该 termId 相关的追踪状态
            terminalSessionStore.handleTermClosed(termId: termId)
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
                clearPendingTerminalOutput(termId: termId)
                // 通过共享终端存储清理所有与该 termId 相关的追踪状态
                terminalSessionStore.handleTermClosed(termId: termId)
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
        // 通过共享终端存储清理断线时的追踪状态
        terminalSessionStore.handleDisconnect()
        terminalState = .idle
    }

    /// 重连后附着当前工作区的 stale 终端会话。
    ///
    /// 严格按当前选中的 `(project, workspace)` 作用域执行，后台工作区的终端不会被错误恢复。
    /// 这是断线重连后终端恢复的唯一入口；不得在其他路径直接 requestTermAttach。
    func requestTerminalReattach() {
        guard !staleTerminalTabs.isEmpty else { return }
        // 仅恢复当前选中工作区的终端，防止后台工作区被错误恢复
        guard let currentWorkspace = selectedWorkspaceKey, !currentWorkspace.isEmpty else { return }
        let currentKey = "\(selectedProjectName):\(currentWorkspace)"
        guard let tabs = workspaceTabs[currentKey] else { return }

        for tab in tabs where tab.kind == .terminal && staleTerminalTabs.contains(tab.id) {
            guard let sessionId = tab.terminalSessionId, !sessionId.isEmpty else { continue }
            TFLog.app.info(
                "终端重连附着: tab=\(tab.id), session=\(sessionId, privacy: .public), workspace=\(currentKey, privacy: .public)"
            )
            // 驱动共享终端生命周期到 resuming（断连后重连）
            if let project = terminalSessionStore.displayInfo(for: sessionId)?.project,
               let workspace = terminalSessionStore.displayInfo(for: sessionId)?.workspace {
                terminalSessionStore.beginAttach(project: project, workspace: workspace, termId: sessionId)
            }
            // 通过共享终端存储记录重连 attach 请求时间
            terminalSessionStore.recordAttachRequest(termId: sessionId)
            wsClient.requestTermAttach(termId: sessionId)
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
            // 通过共享终端存储记录 attach 请求时间
            terminalSessionStore.recordAttachRequest(termId: termId)
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
        // 与 Core PTY clamp 保持一致：忽略初始化阶段的无效小尺寸，减少无意义往返与日志噪声。
        guard cols >= 20, rows >= 5 else { return }
        guard let termId = terminalSessionByTabId[tabId], !termId.isEmpty else { return }
        wsClient.requestTermResize(termId: termId, cols: cols, rows: rows)
    }

    #if os(macOS)
    func attachTerminalSink(_ sink: MacTerminalOutputSink, tabId: UUID) {
        let switchStartedAt = Date()
        if isPerfTerminalAutoDetachEnabled,
           let previousTabId = terminalSinkTabId,
           previousTabId != tabId,
           let previousTermId = terminalSessionByTabId[previousTabId],
           !previousTermId.isEmpty {
            // 通过共享终端存储记录 detach 请求时间
            terminalSessionStore.recordDetachRequest(termId: previousTermId)
            wsClient.requestTermDetach(termId: previousTermId)
            clearPendingTerminalOutput(termId: previousTermId)
        }

        terminalSink = sink
        terminalSinkTabId = tabId
        sink.resetTerminal()
        schedulePendingTerminalOutputFlush(forceImmediate: true)
        let switchCostMs = Int(Date().timeIntervalSince(switchStartedAt) * 1000)
        TFLog.app.info("perf.terminal.switch_ms=\(switchCostMs, privacy: .public)")
    }

    func detachTerminalSink(_ sink: MacTerminalOutputSink? = nil, tabId: UUID) {
        if let sink, let current = terminalSink, current !== sink {
            return
        }
        if terminalSinkTabId == tabId {
            if isPerfTerminalAutoDetachEnabled,
               let termId = terminalSessionByTabId[tabId],
               !termId.isEmpty {
                // 通过共享终端存储记录 detach 请求时间
                terminalSessionStore.recordDetachRequest(termId: termId)
                wsClient.requestTermDetach(termId: termId)
                clearPendingTerminalOutput(termId: termId)
            }
            terminalSink = nil
            terminalSinkTabId = nil
            terminalOutputFlushWorkItem?.cancel()
            terminalOutputFlushWorkItem = nil
        }
    }
    #endif

    private func bindTermToTab(tabId: UUID, termId: String, globalKey: String) {
        if let oldTermId = terminalSessionByTabId[tabId], oldTermId != termId {
            terminalTabIdBySessionId.removeValue(forKey: oldTermId)
            // 通过共享终端存储清理旧 termId 的追踪状态
            terminalSessionStore.handleTermClosed(termId: oldTermId)
        }
        if let oldTabId = terminalTabIdBySessionId[termId], oldTabId != tabId {
            terminalSessionByTabId.removeValue(forKey: oldTabId)
            staleTerminalTabs.insert(oldTabId)
        }
        terminalSessionByTabId[tabId] = termId
        terminalTabIdBySessionId[termId] = tabId
        staleTerminalTabs.remove(tabId)
        pendingSpawnTabs.remove(tabId)
        // 通过共享终端存储记录工作区首次打开时间
        terminalSessionStore.recordWorkspaceOpenTimeIfNeeded(key: globalKey)
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
        guard let tabId = findTabIdByTermId(termId) else { return }

        if terminalSinkTabId == tabId {
            enqueuePendingTerminalOutput(bytes, for: termId)
            schedulePendingTerminalOutputFlush()
        }

        // 通过共享终端存储追踪 ACK 计数
        terminalSessionStore.addUnackedBytes(bytes.count, for: termId)
        let newUnacked = terminalSessionStore.unackedBytes(for: termId)
        if newUnacked >= termOutputAckThreshold {
            wsClient.sendTermOutputAck(termId: termId, bytes: newUnacked)
            terminalSessionStore.clearUnackedBytes(for: termId)
        }
    }

    private func schedulePendingTerminalOutputFlush(forceImmediate: Bool = false) {
        terminalOutputFlushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingTerminalOutput()
        }
        terminalOutputFlushWorkItem = workItem
        let delay = forceImmediate ? 0 : terminalOutputFlushInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func flushPendingTerminalOutput() {
        terminalOutputFlushWorkItem = nil
        guard let sink = terminalSink else { return }
        guard let tabId = terminalSinkTabId,
              let termId = terminalSessionByTabId[tabId] else { return }
        var pendingChunks = pendingTerminalOutputByTermId.removeValue(forKey: termId) ?? []
        guard !pendingChunks.isEmpty else { return }

        let startedAt = Date()
        var bytesToWrite: [UInt8] = []
        bytesToWrite.reserveCapacity(min(terminalOutputMaxBytesPerFlush, pendingChunks.reduce(0) { $0 + $1.count }))

        while let first = pendingChunks.first {
            let nextSize = bytesToWrite.count + first.count
            if !bytesToWrite.isEmpty && nextSize > terminalOutputMaxBytesPerFlush {
                break
            }
            bytesToWrite.append(contentsOf: first)
            pendingChunks.removeFirst()
            if bytesToWrite.count >= terminalOutputMaxBytesPerFlush {
                break
            }
        }

        if bytesToWrite.isEmpty, let first = pendingChunks.first {
            bytesToWrite = first
            pendingChunks.removeFirst()
        }

        guard !bytesToWrite.isEmpty else { return }

        if !pendingChunks.isEmpty {
            pendingTerminalOutputByTermId[termId] = pendingChunks
        }
        sink.writeOutput(bytesToWrite)

        if pendingTerminalOutputByTermId[termId]?.isEmpty == false {
            schedulePendingTerminalOutputFlush()
        }

        let costMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        TFLog.perf.debug(
            "terminal_output_flush_ms=\(costMs, privacy: .public) bytes=\(bytesToWrite.count, privacy: .public) pending_chunks=\(pendingChunks.count, privacy: .public)"
        )
    }

    private func enqueuePendingTerminalOutput(_ bytes: [UInt8], for termId: String) {
        var pendingChunks = pendingTerminalOutputByTermId.removeValue(forKey: termId) ?? []
        pendingChunks.append(bytes)
        if pendingChunks.count > pendingOutputChunkLimit {
            pendingChunks.removeFirst(pendingChunks.count - pendingOutputChunkLimit)
        }
        pendingTerminalOutputByTermId[termId] = pendingChunks
    }

    private func clearPendingTerminalOutput(termId: String?) {
        guard let termId, !termId.isEmpty else { return }
        pendingTerminalOutputByTermId.removeValue(forKey: termId)
    }

    private func clearPendingTerminalOutput(for tabId: UUID) {
        guard let termId = terminalSessionByTabId[tabId] else { return }
        clearPendingTerminalOutput(termId: termId)
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
