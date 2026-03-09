import SwiftUI

struct CenterContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var editorStore: EditorStore

    /// 拖拽开始时记录的底部面板总高度（收起态为分类栏高度，展开态为面板实际高度）
    @State private var dragStartBottomPanelHeight: CGFloat?

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
                            .frame(
                                maxWidth: .infinity,
                                minHeight: BottomPanelLayoutSemantics.minChatPanelHeight,
                                maxHeight: .infinity
                            )

                        bottomPanel(totalHeight: totalHeight)
                            .frame(height: bottomPanelHeight(totalHeight: totalHeight))
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
        .sheet(isPresented: $editorStore.showSaveAsPanel) {
            SaveAsSheetView(
                initialPath: editorStore.pendingSaveAsPath ?? "",
                onCancel: { appState.cancelSaveAs() },
                onConfirm: { appState.performSaveAs(newPath: $0) }
            )
        }
        .accessibilityIdentifier("tf.mac.content.main")
    }

    // MARK: - 底部面板

    private func bottomPanel(totalHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            TabStripView(
                collapsed: !appState.tabPanelExpanded,
                onResizeDrag: { delta in
                    handleBottomPanelDrag(delta: delta, totalHeight: totalHeight)
                },
                onResizeDragEnd: {
                    finalizeBottomPanelDrag(totalHeight: totalHeight)
                },
                onResizeDoubleTap: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.collapseBottomPanel()
                    }
                }
            )

            if appState.tabPanelExpanded {
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
    }

    // MARK: - 顶部线拖拽

    private func handleBottomPanelDrag(delta: CGFloat, totalHeight: CGFloat) {
        if dragStartBottomPanelHeight == nil {
            let currentHeight = BottomPanelLayoutSemantics.clampedExpandedHeight(
                appState.tabPanelHeight,
                totalHeight: totalHeight
            )
            dragStartBottomPanelHeight = BottomPanelLayoutSemantics.dragStartPanelHeight(
                isExpanded: appState.tabPanelExpanded,
                currentHeight: currentHeight
            )
        }
        guard let dragStartBottomPanelHeight else { return }

        let candidateHeight = dragStartBottomPanelHeight - delta
        if BottomPanelLayoutSemantics.shouldExpand(
            candidateHeight: candidateHeight,
            totalHeight: totalHeight
        ) {
            let clampedHeight = BottomPanelLayoutSemantics.clampedExpandedHeight(
                candidateHeight,
                totalHeight: totalHeight
            )
            appState.tabPanelExpanded = true
            appState.tabPanelHeight = clampedHeight
            appState.tabPanelLastExpandedHeight = clampedHeight
        } else {
            appState.tabPanelExpanded = false
            appState.tabPanelHeight = 0
        }
    }

    private func finalizeBottomPanelDrag(totalHeight: CGFloat) {
        defer { dragStartBottomPanelHeight = nil }
        guard appState.tabPanelExpanded else { return }

        let normalizedHeight = BottomPanelLayoutSemantics.clampedExpandedHeight(
            appState.tabPanelHeight,
            totalHeight: totalHeight
        )
        if normalizedHeight <= 0 {
            appState.collapseBottomPanel()
        } else {
            appState.tabPanelHeight = normalizedHeight
            appState.tabPanelLastExpandedHeight = normalizedHeight
        }
    }

    private func bottomPanelHeight(totalHeight: CGFloat) -> CGFloat {
        if appState.tabPanelExpanded {
            return BottomPanelLayoutSemantics.clampedExpandedHeight(
                appState.tabPanelHeight,
                totalHeight: totalHeight
            )
        }
        return BottomPanelLayoutSemantics.collapsedTabStripHeight
    }
}

private struct SaveAsSheetView: View {
    let initialPath: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void
    @State private var targetPath: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("editor.saveAs".localized)
                    .font(.headline)
                TextField("editor.saveAs.targetPath".localized, text: $targetPath)
                    .textFieldStyle(.roundedBorder)
                Text("editor.saveAs.hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                HStack {
                    Button("common.cancel".localized, role: .cancel) {
                        onCancel()
                    }
                    Spacer()
                    Button("common.save".localized) {
                        onConfirm(targetPath.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(targetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .navigationTitle("editor.saveAs".localized)
        }
        .frame(minWidth: 420, minHeight: 180)
        .onAppear {
            targetPath = initialPath
        }
    }
}
