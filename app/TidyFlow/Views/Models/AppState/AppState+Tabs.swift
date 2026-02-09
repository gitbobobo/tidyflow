import Foundation

extension AppState {
    // MARK: - Tab Helpers
    
    func ensureDefaultTab(for workspaceKey: String) {
        // 不再自动创建终端，仅确保字典有对应的键
        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }
    }
    
    func activateTab(workspaceKey: String, tabId: UUID) {
        activeTabIdByWorkspace[workspaceKey] = tabId
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
                onTerminalKill?(tabId.uuidString, sessionId)
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
        // 检查是否已有终端 Tab（用于判断是否需要通过回调 spawn）
        let existingTabs = workspaceTabs[workspaceKey] ?? []
        let hasExistingTerminalTab = existingTabs.contains { $0.kind == .terminal }
        
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

        // 记录工作空间首次打开终端的时间（用于自动快捷键排序）
        if kind == .terminal && workspaceTerminalOpenTime[workspaceKey] == nil {
            workspaceTerminalOpenTime[workspaceKey] = Date()
        }

        // 当创建终端 Tab 且已有其他终端时，直接通知 WebBridge spawn 新终端
        // （第一个终端由 TerminalContentView.onAppear 处理）
        if kind == .terminal && hasExistingTerminalTab {
            // 标记为 pending spawn，防止 handleTabSwitch 重复 spawn
            pendingSpawnTabs.insert(newTab.id)
            
            // 协议要求传 (projectName, workspaceName)。TabStrip 传入的是 globalKey "project:workspace"，需解析为纯 workspace 名
            let (rpcProject, rpcWorkspace): (String, String)
            if let colonIdx = workspaceKey.firstIndex(of: ":") {
                rpcProject = String(workspaceKey[..<colonIdx])
                rpcWorkspace = String(workspaceKey[workspaceKey.index(after: colonIdx)...])
            } else {
                rpcProject = selectedProjectName
                rpcWorkspace = workspaceKey
            }
            onTerminalSpawn?(newTab.id.uuidString, rpcProject, rpcWorkspace)
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

        // 终端视图会在 spawn 后检查 payload 并执行命令
    }
}
