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

class AppState: ObservableObject {
    @Published var selectedWorkspaceKey: String?
    @Published var activeRightTool: RightTool? = .explorer
    @Published var connectionState: ConnectionState = .disconnected
    
    // Mock data for workspaces
    let workspaces = [
        "default": "Default Workspace",
        "project-alpha": "Project Alpha",
        "project-beta": "Project Beta"
    ]
    
    init() {
        // Set default workspace
        self.selectedWorkspaceKey = "default"
    }
}
