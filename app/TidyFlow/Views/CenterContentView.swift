import SwiftUI

struct CenterContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var editorStore: EditorStore

    /// Tab 面板收起时的高度（仅显示 TabStripView 收起模式）
    private let collapsedTabStripHeight: CGFloat = 28
    /// 底部 Tab 面板最小高度
    private let minTabPanelHeight: CGFloat = 100
    /// 顶部聊天面板最小高度（保证输入框可见）
    private let minChatPanelHeight: CGFloat = 220
    /// 分割线热区高度，需要与 VerticalSplitDivider 保持一致
    private let splitDividerHeight: CGFloat = 8
    /// 拖拽开始时记录的 Tab 面板高度
    @State private var dragStartTabPanelHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if appState.selectedWorkspaceKey != nil {
                GeometryReader { geo in
                    let totalHeight = geo.size.height
                    VStack(spacing: 0) {
                        // 上方：AI 聊天面板（始终可见）
                        AITabView()
                            .environmentObject(appState)
                            .environmentObject(appState.aiChatStore)
                            .environmentObject(appState.fileCache)
                            .frame(maxWidth: .infinity, minHeight: minChatPanelHeight, maxHeight: .infinity)

                        // 可拖拽分割线
                        VerticalSplitDivider(
                            onDrag: { delta in
                                handleDividerDrag(delta: delta, totalHeight: totalHeight)
                            },
                            onDragEnd: {
                                finalizeDividerDrag(totalHeight: totalHeight)
                            },
                            onDoubleTap: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    appState.tabPanelExpanded.toggle()
                                    if appState.tabPanelExpanded {
                                        appState.tabPanelHeight = clampedTabPanelHeightValue(
                                            totalHeight * 0.5,
                                            totalHeight: totalHeight
                                        )
                                    } else {
                                        appState.tabPanelHeight = 0
                                    }
                                }
                            }
                        )

                        // 下方：Tab 面板
                        if appState.tabPanelExpanded {
                            // 展开状态：Tab 栏 + Tab 内容
                            expandedTabPanel
                                .frame(height: clampedTabPanelHeight(totalHeight: totalHeight))
                        } else {
                            // 收起状态：仅显示紧凑 Tab 条
                            TabStripView(collapsed: true)
                        }
                    }
                }
            } else {
                // 未选择工作空间
                ZStack {
                    if let projectName = appState.selectedProjectForConfig {
                        ProjectConfigView(projectName: projectName)
                            .transition(.opacity)
                    } else {
                        NoActiveTabView()
                    }
                }
            }
        }
        .alert("tabContent.unsavedChanges".localized, isPresented: $editorStore.showUnsavedChangesAlert) {
            Button("common.save".localized, role: nil) {
                if let wsKey = appState.pendingCloseWorkspaceKey,
                   let tabId = appState.pendingCloseTabId {
                    appState.saveAndCloseTab(workspaceKey: wsKey, tabId: tabId)
                }
                appState.pendingCloseWorkspaceKey = nil
                appState.pendingCloseTabId = nil
            }
            Button("tabContent.dontSave".localized, role: .destructive) {
                if let wsKey = appState.pendingCloseWorkspaceKey,
                   let tabId = appState.pendingCloseTabId {
                    appState.performCloseTab(workspaceKey: wsKey, tabId: tabId)
                }
                appState.pendingCloseWorkspaceKey = nil
                appState.pendingCloseTabId = nil
            }
            Button("common.cancel".localized, role: .cancel) {
                appState.pendingCloseWorkspaceKey = nil
                appState.pendingCloseTabId = nil
            }
        } message: {
            Text("tabContent.unsavedChanges.message".localized)
        }
    }

    // MARK: - 展开状态的 Tab 面板

    private var expandedTabPanel: some View {
        VStack(spacing: 0) {
            TabStripView(collapsed: false)
            Divider()
            ZStack {
                if let projectName = appState.selectedProjectForConfig {
                    ProjectConfigView(projectName: projectName)
                        .transition(.opacity)
                } else {
                    TabContentHostView()
                }
            }
        }
    }

    // MARK: - 分割线拖拽

    private func handleDividerDrag(delta: CGFloat, totalHeight: CGFloat) {
        let maxTabHeight = maxTabPanelHeight(totalHeight: totalHeight)
        guard maxTabHeight > 0 else {
            appState.tabPanelExpanded = false
            appState.tabPanelHeight = 0
            dragStartTabPanelHeight = 0
            return
        }
        if dragStartTabPanelHeight == 0 {
            dragStartTabPanelHeight = appState.tabPanelExpanded
                ? clampedTabPanelHeightValue(appState.tabPanelHeight, totalHeight: totalHeight)
                : 0
        }
        // delta 正值 = 向下拖 = Tab 面板变小，负值 = 向上拖 = Tab 面板变大
        let newHeight = dragStartTabPanelHeight - delta

        if newHeight < minEffectiveTabPanelHeight(totalHeight: totalHeight) / 2 {
            // 拖到足够小时收起
            appState.tabPanelExpanded = false
            appState.tabPanelHeight = 0
            dragStartTabPanelHeight = 0
        } else {
            appState.tabPanelExpanded = true
            appState.tabPanelHeight = clampedTabPanelHeightValue(newHeight, totalHeight: totalHeight)
            // 不重置 dragStartTabPanelHeight，因为 DragGesture 的 translation 是相对于起始点的累计值。
        }
    }

    /// 拖拽结束后重置基线，并将状态高度归一化到当前布局范围内。
    private func finalizeDividerDrag(totalHeight: CGFloat) {
        dragStartTabPanelHeight = 0
        guard appState.tabPanelExpanded else { return }
        let normalized = clampedTabPanelHeightValue(appState.tabPanelHeight, totalHeight: totalHeight)
        if normalized <= 0 {
            appState.tabPanelExpanded = false
            appState.tabPanelHeight = 0
        } else {
            appState.tabPanelHeight = normalized
        }
    }

    private func minEffectiveTabPanelHeight(totalHeight: CGFloat) -> CGFloat {
        min(minTabPanelHeight, maxTabPanelHeight(totalHeight: totalHeight))
    }

    private func maxTabPanelHeight(totalHeight: CGFloat) -> CGFloat {
        max(0, totalHeight - minChatPanelHeight - splitDividerHeight)
    }

    private func clampedTabPanelHeightValue(_ value: CGFloat, totalHeight: CGFloat) -> CGFloat {
        let maxTabHeight = maxTabPanelHeight(totalHeight: totalHeight)
        guard maxTabHeight > 0 else { return 0 }
        let minTabHeight = minEffectiveTabPanelHeight(totalHeight: totalHeight)
        return min(max(value, minTabHeight), maxTabHeight)
    }

    /// 限制 Tab 面板高度在合理范围内
    private func clampedTabPanelHeight(totalHeight: CGFloat) -> CGFloat {
        clampedTabPanelHeightValue(appState.tabPanelHeight, totalHeight: totalHeight)
    }
}
