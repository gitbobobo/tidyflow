import SwiftUI

/// 导航路由定义
enum MobileRoute: Hashable {
    case projects
    case workspaceDetail(project: String, workspace: String)
    case workspaceTasks(project: String, workspace: String)
    case terminal(
        project: String,
        workspace: String,
        command: String? = nil,
        commandIcon: String? = nil,
        commandName: String? = nil
    )
    case terminalAttach(project: String, workspace: String, termId: String)
    case aiChat(project: String, workspace: String)
}

@main
struct TidyFlowiOSApp: App {
    @StateObject private var appState = MobileAppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .top) {
                NavigationStack(path: $appState.navigationPath) {
                    ConnectionView()
                        .navigationDestination(for: MobileRoute.self) { route in
                            switch route {
                            case .projects:
                                ProjectListView()
                            case .workspaceDetail(let project, let workspace):
                                WorkspaceDetailView(project: project, workspace: workspace)
                            case .workspaceTasks(let project, let workspace):
                                WorkspaceTasksView(project: project, workspace: workspace)
                            case .terminal(let project, let workspace, let command, let commandIcon, let commandName):
                                MobileTerminalView(
                                    project: project,
                                    workspace: workspace,
                                    command: command,
                                    commandIcon: commandIcon,
                                    commandName: commandName
                                )
                            case .terminalAttach(let project, let workspace, let termId):
                                MobileTerminalView(project: project, workspace: workspace, termId: termId)
                            case .aiChat:
                                MobileAIChatView()
                            }
                        }
                }
                .environmentObject(appState)

                DisconnectBannerView()
                    .environmentObject(appState)
            }
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    appState.handleReturnToForeground()
                case .background:
                    appState.handleEnterBackground()
                default:
                    break
                }
            }
        }
    }
}
