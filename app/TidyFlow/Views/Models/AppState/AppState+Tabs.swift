import Foundation

extension AppState {
    // MARK: - Tab Helpers

    /// 打开工作空间级主页面（不新增 Tab）
    func showWorkspaceSpecialPage(workspaceKey: String, page: WorkspaceSpecialPage) {
        workspaceSpecialPageByWorkspace[workspaceKey] = page
    }

    /// 切换工作空间级主页面（再次点击同一按钮会关闭高亮并回到 Tab 内容）
    func toggleWorkspaceSpecialPage(workspaceKey: String, page: WorkspaceSpecialPage) {
        if workspaceSpecialPageByWorkspace[workspaceKey] == page {
            workspaceSpecialPageByWorkspace.removeValue(forKey: workspaceKey)
        } else {
            workspaceSpecialPageByWorkspace[workspaceKey] = page
        }
    }

    /// 当前工作空间正在展示的工作空间级主页面
    var currentWorkspaceSpecialPage: WorkspaceSpecialPage? {
        guard let globalKey = currentGlobalWorkspaceKey else { return nil }
        return workspaceSpecialPageByWorkspace[globalKey]
    }
    
    func ensureDefaultTab(for workspaceKey: String) {
        // 不再自动创建终端，仅确保字典有对应的键
        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }
    }
    
    func activateTab(workspaceKey: String, tabId: UUID) {
        activeTabIdByWorkspace[workspaceKey] = tabId
        // 切回普通 Tab 时，退出工作空间级页面
        workspaceSpecialPageByWorkspace.removeValue(forKey: workspaceKey)
    }
    
    func closeTab(workspaceKey: String, tabId: UUID) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }

        // 编辑器 Tab 且有未保存更改时，弹出确认对话框
        if tab.kind == .editor && tab.isDirty {
            pendingCloseWorkspaceKey = workspaceKey
            pendingCloseTabId = tabId
            showUnsavedChangesAlert = true
            return
        }

        performCloseTab(workspaceKey: workspaceKey, tabId: tabId)
    }

    /// 关闭其他标签页（保留指定 tab）
    func closeOtherTabs(workspaceKey: String, keepTabId: UUID) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        for tab in tabs where tab.id != keepTabId {
            closeTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 关闭右侧标签页
    func closeTabsToRight(workspaceKey: String, ofTabId: UUID) {
        guard let tabs = workspaceTabs[workspaceKey],
              let index = tabs.firstIndex(where: { $0.id == ofTabId }) else { return }
        let rightTabs = tabs.suffix(from: tabs.index(after: index))
        for tab in rightTabs {
            closeTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 关闭已保存的标签页（跳过 dirty 的编辑器 tab）
    func closeSavedTabs(workspaceKey: String) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        for tab in tabs {
            if tab.kind == .editor && tab.isDirty { continue }
            performCloseTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 全部关闭（dirty 的编辑器 tab 会弹确认）
    func closeAllTabs(workspaceKey: String) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        for tab in tabs {
            closeTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 强制关闭所有标签页（跳过未保存检查，用于工作空间删除）
    func forceCloseAllTabs(workspaceKey: String) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        for tab in tabs {
            performCloseTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
        // 工作空间被删除/结束工作时，同步清理工作空间级页面状态
        workspaceSpecialPageByWorkspace.removeValue(forKey: workspaceKey)
    }

    /// 实际执行关闭 Tab（跳过 dirty 检查）
    func performCloseTab(workspaceKey: String, tabId: UUID) {
        guard var tabs = workspaceTabs[workspaceKey] else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }

        let tab = tabs[index]
        let isActive = activeTabIdByWorkspace[workspaceKey] == tabId

        // Phase C1-2: Send terminal kill and clean up session mapping
        if tab.kind == .terminal {
            if let sessionId = terminalSessionByTabId[tabId] {
                wsClient.requestTermClose(termId: sessionId)
                terminalTabIdBySessionId.removeValue(forKey: sessionId)
            }
            terminalSessionByTabId.removeValue(forKey: tabId)
            staleTerminalTabs.remove(tabId)
        }

        // 编辑器 Tab 关闭时通知 JS 层清理缓存
        if tab.kind == .editor {
            onEditorTabClose?(tab.payload)
        }

        tabs.remove(at: index)
        workspaceTabs[workspaceKey] = tabs

        if isActive {
            if tabs.isEmpty {
                activeTabIdByWorkspace[workspaceKey] = nil
            } else {
                // Select previous tab if possible, else next
                let newIndex = max(0, min(index, tabs.count - 1))
                activeTabIdByWorkspace[workspaceKey] = tabs[newIndex].id
            }
        }

        // 关闭终端后检查是否需要清除时间记录（用于自动快捷键）
        if tab.kind == .terminal {
            let remainingTerminals = workspaceTabs[workspaceKey]?.filter { $0.kind == .terminal }.count ?? 0
            if remainingTerminals == 0 {
                workspaceTerminalOpenTime.removeValue(forKey: workspaceKey)
            }
        }
    }
    
    func addTab(workspaceKey: String, kind: TabKind, title: String, payload: String) {
        let newTab = TabModel(
            id: UUID(),
            title: title,
            kind: kind,
            workspaceKey: workspaceKey,
            payload: payload
        )
        
        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }
        
        workspaceTabs[workspaceKey]?.append(newTab)
        activeTabIdByWorkspace[workspaceKey] = newTab.id
        // 打开普通 Tab 后，退出工作空间级页面
        workspaceSpecialPageByWorkspace.removeValue(forKey: workspaceKey)

        // 记录工作空间首次打开终端的时间（用于自动快捷键排序）
        if kind == .terminal && workspaceTerminalOpenTime[workspaceKey] == nil {
            workspaceTerminalOpenTime[workspaceKey] = Date()
        }

    }
    
    func addTerminalTab(workspaceKey: String) {
        addTab(workspaceKey: workspaceKey, kind: .terminal, title: "Terminal", payload: "")
    }

    /// 创建终端并执行自定义命令
    func addTerminalWithCustomCommand(workspaceKey: String, command: CustomCommand) {
        // 创建终端 tab，使用命令名称作为标题，命令内容存入 payload，命令图标用于 Tab 栏显示
        let newTab = TabModel(
            id: UUID(),
            title: command.name,
            kind: .terminal,
            workspaceKey: workspaceKey,
            payload: command.command,  // 存储命令以便终端就绪后执行
            commandIcon: command.icon
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
}
