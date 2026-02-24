import SwiftUI

struct CenterContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.selectedWorkspaceKey != nil {
                TabStripView()
                Divider()
            }

            ZStack {
                if let projectName = appState.selectedProjectForConfig {
                    ProjectConfigView(projectName: projectName)
                        .transition(.opacity)
                } else {
                    if appState.selectedWorkspaceKey != nil {
                        TabContentHostView()
                    } else {
                        NoActiveTabView()
                    }
                }
            }
        }
        .alert("tabContent.unsavedChanges".localized, isPresented: $appState.showUnsavedChangesAlert) {
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
}
