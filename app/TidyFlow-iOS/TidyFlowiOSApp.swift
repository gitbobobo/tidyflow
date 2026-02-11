import SwiftUI

/// 导航路由定义
enum MobileRoute: Hashable {
    case projects
    case workspaces(project: String)
    case terminal(project: String, workspace: String)
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
                        case .terminal(let project, let workspace):
                            MobileTerminalView(project: project, workspace: workspace)
                        }
                    }
            }
            .environmentObject(appState)
        }
    }
}
