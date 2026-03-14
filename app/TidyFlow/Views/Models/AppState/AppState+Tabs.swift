import Foundation

extension AppState {
    // MARK: - Tab Helpers

    #if os(macOS)
    func expandBottomPanelIfNeeded() {
        let restoredHeight = BottomPanelLayoutSemantics.restoredExpandedHeight(
            currentHeight: tabPanelHeight,
            lastExpandedHeight: tabPanelLastExpandedHeight
        )
        tabPanelExpanded = true
        tabPanelHeight = restoredHeight
        if restoredHeight > 0 {
            tabPanelLastExpandedHeight = restoredHeight
        }
    }

    func collapseBottomPanel() {
        if tabPanelExpanded, tabPanelHeight > 0 {
            tabPanelLastExpandedHeight = tabPanelHeight
        }
        tabPanelExpanded = false
        tabPanelHeight = 0
    }

    func toggleBottomPanel() {
        if tabPanelExpanded {
            collapseBottomPanel()
        } else {
            expandBottomPanelIfNeeded()
        }
    }
    #endif

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
        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }
        if activeBottomPanelCategoryByWorkspace[workspaceKey] == nil {
            activeBottomPanelCategoryByWorkspace[workspaceKey] = .projectConfig
        }
    }

    func tabs(in category: BottomPanelCategory, workspaceKey: String) -> [TabModel] {
        (workspaceTabs[workspaceKey] ?? []).filter { $0.bottomPanelCategory == category }
    }

    func activeBottomPanelCategory(workspaceKey: String) -> BottomPanelCategory {
        resolvedBottomPanelCategory(for: workspaceKey)
    }

    func displayedBottomPanelTabs(workspaceKey: String) -> [TabModel] {
        tabs(in: resolvedBottomPanelCategory(for: workspaceKey), workspaceKey: workspaceKey)
    }

    func displayedBottomPanelTab(workspaceKey: String) -> TabModel? {
        let category = resolvedBottomPanelCategory(for: workspaceKey)
        let categoryTabs = tabs(in: category, workspaceKey: workspaceKey)
        guard !categoryTabs.isEmpty else { return nil }
        if let activeId = activeTabIdByWorkspace[workspaceKey],
           let activeTab = categoryTabs.first(where: { $0.id == activeId }) {
            return activeTab
        }
        if let rememberedId = lastActiveTabIdByWorkspaceByCategory[workspaceKey]?[category],
           let rememberedTab = categoryTabs.first(where: { $0.id == rememberedId }) {
            return rememberedTab
        }
        return categoryTabs.first
    }

    func activateBottomPanelCategory(workspaceKey: String, category: BottomPanelCategory) {
        ensureDefaultTab(for: workspaceKey)
        activeBottomPanelCategoryByWorkspace[workspaceKey] = category
        let categoryTabs = tabs(in: category, workspaceKey: workspaceKey)
        guard !categoryTabs.isEmpty else {
            if category == .projectConfig {
                activeTabIdByWorkspace[workspaceKey] = nil
                workspaceSpecialPageByWorkspace.removeValue(forKey: workspaceKey)
                #if os(macOS)
                expandBottomPanelIfNeeded()
                #endif
                return
            }
            if category == .terminal {
                addTerminalTab(workspaceKey: workspaceKey)
                return
            }
            activeTabIdByWorkspace[workspaceKey] = nil
            workspaceSpecialPageByWorkspace.removeValue(forKey: workspaceKey)
            #if os(macOS)
            expandBottomPanelIfNeeded()
            #endif
            return
        }

        let rememberedId = lastActiveTabIdByWorkspaceByCategory[workspaceKey]?[category]
        if let rememberedId,
           categoryTabs.contains(where: { $0.id == rememberedId }) {
            recordTabActivation(workspaceKey: workspaceKey, tabId: rememberedId)
        } else if let first = categoryTabs.first {
            recordTabActivation(workspaceKey: workspaceKey, tabId: first.id)
        }
    }

    func activateTab(workspaceKey: String, tabId: UUID) {
        guard let tab = workspaceTabs[workspaceKey]?.first(where: { $0.id == tabId }) else { return }
        ensureDefaultTab(for: workspaceKey)
        activeBottomPanelCategoryByWorkspace[workspaceKey] = tab.bottomPanelCategory
        recordTabActivation(workspaceKey: workspaceKey, tabId: tabId)
    }

    func closeTab(workspaceKey: String, tabId: UUID) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }

        if tab.kind == .editor && tab.isDirty {
            pendingCloseWorkspaceKey = workspaceKey
            pendingCloseTabId = tabId
            showUnsavedChangesAlert = true
            return
        }

        // 关闭 editor Tab 时释放该文档的撤销/重做历史记录
        if tab.kind == .editor {
            editorStore.releaseDocumentUndoHistory(workspaceKey: workspaceKey, path: tab.payload)
        }

        performCloseTab(workspaceKey: workspaceKey, tabId: tabId)
    }

    /// 关闭其他标签页（仅作用于与 keepTab 同类别的实例）
    func closeOtherTabs(workspaceKey: String, keepTabId: UUID) {
        guard let tabs = workspaceTabs[workspaceKey],
              let keepTab = tabs.first(where: { $0.id == keepTabId }) else { return }
        let sameCategoryTabs = tabs.filter { $0.bottomPanelCategory == keepTab.bottomPanelCategory }
        for tab in sameCategoryTabs where tab.id != keepTabId && !tab.isPinned {
            closeTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 关闭下方标签页（竖向实例栏语义）
    func closeTabsBelow(workspaceKey: String, ofTabId: UUID) {
        let currentTabs = workspaceTabs[workspaceKey] ?? []
        guard let tab = currentTabs.first(where: { $0.id == ofTabId }) else { return }
        let sameCategoryTabs = currentTabs.filter { $0.bottomPanelCategory == tab.bottomPanelCategory }
        guard let index = sameCategoryTabs.firstIndex(where: { $0.id == ofTabId }) else { return }
        let tabsBelow = sameCategoryTabs.suffix(from: sameCategoryTabs.index(after: index))
        for item in tabsBelow where !item.isPinned {
            closeTab(workspaceKey: workspaceKey, tabId: item.id)
        }
    }

    func toggleTerminalTabPinned(workspaceKey: String, tabId: UUID) {
        guard var tabs = workspaceTabs[workspaceKey],
              let index = tabs.firstIndex(where: { $0.id == tabId && $0.kind == .terminal }) else { return }
        tabs[index].isPinned.toggle()
        workspaceTabs[workspaceKey] = tabs
    }

    /// 关闭已保存的标签页（仅作用于当前类别）
    func closeSavedTabs(workspaceKey: String) {
        for tab in displayedBottomPanelTabs(workspaceKey: workspaceKey) {
            if tab.kind == .editor && tab.isDirty { continue }
            performCloseTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 全部关闭（仅作用于当前类别）
    func closeAllTabs(workspaceKey: String) {
        for tab in displayedBottomPanelTabs(workspaceKey: workspaceKey) {
            closeTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
    }

    /// 强制关闭所有标签页（跳过未保存检查，用于工作空间删除）
    func forceCloseAllTabs(workspaceKey: String) {
        guard let tabs = workspaceTabs[workspaceKey] else { return }
        for tab in tabs {
            performCloseTab(workspaceKey: workspaceKey, tabId: tab.id)
        }
        // 释放该工作区所有文档的撤销/重做历史记录
        editorStore.releaseAllDocumentUndoHistory(workspaceKey: workspaceKey)
        workspaceSpecialPageByWorkspace.removeValue(forKey: workspaceKey)
        activeBottomPanelCategoryByWorkspace.removeValue(forKey: workspaceKey)
        lastActiveTabIdByWorkspaceByCategory.removeValue(forKey: workspaceKey)
    }

    /// 工作区级未保存保护入口。
    ///
    /// 在关闭工作区、切换工作区等场景中调用，若存在未保存文档则触发确认对话框。
    /// 返回 true 表示可以继续关闭，false 表示已触发确认对话框、操作已挂起。
    ///
    /// - Parameters:
    ///   - workspaceKey: 目标工作区 key
    ///   - onConfirmed: 用户确认后执行的动作（放弃更改或保存后）
    @discardableResult
    func requestWorkspaceCloseWithUnsavedGuard(
        workspaceKey: String,
        onConfirmed: (() -> Void)? = nil
    ) -> Bool {
        guard editorStore.hasDirtyDocuments(workspaceKey: workspaceKey) else {
            // 无未保存文档，直接执行
            onConfirmed?()
            return true
        }
        // 有未保存文档：触发工作区级确认对话框
        // 设置 pendingCloseWorkspaceKey 但不设置 pendingCloseTabId（工作区级）
        pendingCloseWorkspaceKey = workspaceKey
        pendingCloseTabId = nil
        showUnsavedChangesAlert = true
        return false
    }

    /// 实际执行关闭 Tab（跳过 dirty 检查）
    func performCloseTab(workspaceKey: String, tabId: UUID) {
        guard var tabs = workspaceTabs[workspaceKey] else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }

        let tab = tabs[index]
        let category = tab.bottomPanelCategory
        let categoryTabsBefore = tabs.filter { $0.bottomPanelCategory == category }
        let categoryIndexBefore = categoryTabsBefore.firstIndex(where: { $0.id == tabId })
        let isDisplayedTab = activeTabIdByWorkspace[workspaceKey] == tabId
        let isCurrentCategory = resolvedBottomPanelCategory(for: workspaceKey) == category

        if tab.kind == .terminal {
            if let sessionId = terminalSessionByTabId[tabId] {
                terminalSessionStore.recordDetachRequest(termId: sessionId)
                wsClient.requestTermClose(termId: sessionId)
                terminalTabIdBySessionId.removeValue(forKey: sessionId)
                terminalSessionStore.handleTermClosed(termId: sessionId)
            }
            terminalSessionByTabId.removeValue(forKey: tabId)
            staleTerminalTabs.remove(tabId)
        }

        if tab.kind == .editor {
            onEditorTabClose?(tab.payload)
        }

        tabs.remove(at: index)
        workspaceTabs[workspaceKey] = tabs
        forgetRememberedTab(workspaceKey: workspaceKey, tabId: tabId)

        let categoryTabsAfter = tabs.filter { $0.bottomPanelCategory == category }
        let replacementId = replacementTabId(
            categoryTabs: categoryTabsAfter,
            removedIndex: categoryIndexBefore
        )
        if let replacementId {
            rememberTab(workspaceKey: workspaceKey, category: category, tabId: replacementId)
        }

        if isCurrentCategory {
            activeBottomPanelCategoryByWorkspace[workspaceKey] = category
            if isDisplayedTab {
                activeTabIdByWorkspace[workspaceKey] = replacementId
            } else if let activeId = activeTabIdByWorkspace[workspaceKey],
                      tabs.contains(where: { $0.id == activeId }) {
                // 保持当前显示实例不变。
            } else {
                activeTabIdByWorkspace[workspaceKey] = replacementId
            }
        }

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
        appendAndActivateTab(newTab, workspaceKey: workspaceKey)
    }

    func addTerminalTab(workspaceKey: String) {
        addTab(workspaceKey: workspaceKey, kind: .terminal, title: "Terminal", payload: "")
    }

    /// 创建终端并执行自定义命令
    func addTerminalWithCustomCommand(workspaceKey: String, command: CustomCommand) {
        let newTab = TabModel(
            id: UUID(),
            title: command.name,
            kind: .terminal,
            workspaceKey: workspaceKey,
            payload: command.command,
            commandIcon: command.icon
        )
        appendAndActivateTab(newTab, workspaceKey: workspaceKey)
    }

    func appendAndActivateTab(_ newTab: TabModel, workspaceKey: String) {
        ensureDefaultTab(for: workspaceKey)
        workspaceTabs[workspaceKey, default: []].append(newTab)
        activeBottomPanelCategoryByWorkspace[workspaceKey] = newTab.bottomPanelCategory
        recordTabActivation(workspaceKey: workspaceKey, tabId: newTab.id)
        workspaceSpecialPageByWorkspace.removeValue(forKey: workspaceKey)
        #if os(macOS)
        expandBottomPanelIfNeeded()
        #endif

        if newTab.kind == .terminal && workspaceTerminalOpenTime[workspaceKey] == nil {
            workspaceTerminalOpenTime[workspaceKey] = Date()
        }
    }

    private func resolvedBottomPanelCategory(for workspaceKey: String) -> BottomPanelCategory {
        if let category = activeBottomPanelCategoryByWorkspace[workspaceKey] {
            return category
        }
        if let firstTab = workspaceTabs[workspaceKey]?.first {
            return firstTab.bottomPanelCategory
        }
        return .projectConfig
    }

    private func recordTabActivation(workspaceKey: String, tabId: UUID) {
        guard let tab = workspaceTabs[workspaceKey]?.first(where: { $0.id == tabId }) else { return }
        activeTabIdByWorkspace[workspaceKey] = tabId
        activeBottomPanelCategoryByWorkspace[workspaceKey] = tab.bottomPanelCategory
        rememberTab(workspaceKey: workspaceKey, category: tab.bottomPanelCategory, tabId: tabId)
        workspaceSpecialPageByWorkspace.removeValue(forKey: workspaceKey)
        #if os(macOS)
        expandBottomPanelIfNeeded()
        #endif
    }

    private func rememberTab(workspaceKey: String, category: BottomPanelCategory, tabId: UUID) {
        var remembered = lastActiveTabIdByWorkspaceByCategory[workspaceKey] ?? [:]
        remembered[category] = tabId
        lastActiveTabIdByWorkspaceByCategory[workspaceKey] = remembered
    }

    private func forgetRememberedTab(workspaceKey: String, tabId: UUID) {
        guard var remembered = lastActiveTabIdByWorkspaceByCategory[workspaceKey] else { return }
        for (category, rememberedId) in remembered where rememberedId == tabId {
            remembered.removeValue(forKey: category)
        }
        lastActiveTabIdByWorkspaceByCategory[workspaceKey] = remembered
    }

    private func replacementTabId(categoryTabs: [TabModel], removedIndex: Int?) -> UUID? {
        guard !categoryTabs.isEmpty else { return nil }
        let candidateIndex = max(0, min(removedIndex ?? 0, categoryTabs.count - 1))
        return categoryTabs[candidateIndex].id
    }
}
