import Foundation
import Combine

enum RightTool: String, CaseIterable {
    case explorer
    case search
    case git
}

enum ConnectionState {
    case connected
    case disconnected
}

enum TabKind: String, Codable {
    case terminal
    case editor
    case diff
    
    var iconName: String {
        switch self {
        case .terminal: return "terminal"
        case .editor: return "doc.text"
        case .diff: return "arrow.left.arrow.right"
        }
    }
}

struct TabModel: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let kind: TabKind
    let workspaceKey: String
    let payload: String
}

typealias TabSet = [TabModel]

class AppState: ObservableObject {
    @Published var selectedWorkspaceKey: String?
    @Published var activeRightTool: RightTool? = .explorer
    @Published var connectionState: ConnectionState = .disconnected
    
    @Published var workspaceTabs: [String: TabSet] = [:]
    @Published var activeTabIdByWorkspace: [String: UUID] = [:]
    
    // Mock data for workspaces
    let workspaces = [
        "default": "Default Workspace",
        "project-alpha": "Project Alpha",
        "project-beta": "Project Beta"
    ]
    
    init() {
        // Set default workspace
        // self.selectedWorkspaceKey = "default" 
        // Intentionally NOT setting default workspace immediately to test "empty state"
        // But Phase A behavior might expect it. The prompt says:
        // "Unselected workspace: no tabs... Click workspace: ensure default tab"
        // Existing code sets it to "default". I'll keep existing behavior but ensure ensureDefaultTab is called if I set it.
        self.selectedWorkspaceKey = "default"
        ensureDefaultTab(for: "default")
    }
    
    func ensureDefaultTab(for workspaceKey: String) {
        if workspaceTabs[workspaceKey]?.isEmpty ?? true {
            let newTab = TabModel(
                id: UUID(),
                title: "Terminal",
                kind: .terminal,
                workspaceKey: workspaceKey,
                payload: ""
            )
            workspaceTabs[workspaceKey] = [newTab]
            activeTabIdByWorkspace[workspaceKey] = newTab.id
        }
    }
    
    func activateTab(workspaceKey: String, tabId: UUID) {
        activeTabIdByWorkspace[workspaceKey] = tabId
    }
    
    func closeTab(workspaceKey: String, tabId: UUID) {
        guard var tabs = workspaceTabs[workspaceKey] else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        
        let isActive = activeTabIdByWorkspace[workspaceKey] == tabId
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
    }
}
