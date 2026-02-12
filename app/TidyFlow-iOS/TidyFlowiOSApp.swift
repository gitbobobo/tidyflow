import SwiftUI

/// 导航路由定义
enum MobileRoute: Hashable {
    case projects
    case workspaces(project: String)
    case terminal(project: String, workspace: String, command: String? = nil)
    case terminalAttach(project: String, workspace: String, termId: String)
}

@main
struct TidyFlowiOSApp: App {
    @StateObject private var appState = MobileAppState()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $appState.navigationPath) {
                ConnectionView()
                    .navigationDestination(for: MobileRoute.self) { route in
                        switch route {
                        case .projects:
                            ProjectListView()
                        case .workspaces(let project):
                            WorkspaceListView(project: project)
                        case .terminal(let project, let workspace, let command):
                            MobileTerminalView(project: project, workspace: workspace, command: command)
                        case .terminalAttach(let project, let workspace, let termId):
                            MobileTerminalView(project: project, workspace: workspace, termId: termId)
                        }
                    }
            }
            .environmentObject(appState)
        }
    }
}
