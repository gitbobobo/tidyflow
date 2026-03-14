import SwiftUI

/// 导航路由定义
enum MobileRoute: Hashable {
    case projects
    case settings
    case workspaceDetail(project: String, workspace: String)
    case workspaceExplorer(project: String, workspace: String)
    case workspaceTasks(project: String, workspace: String)
    case workspaceTodos(project: String, workspace: String)
    case workspaceGit(project: String, workspace: String)
    case terminal(
        project: String,
        workspace: String,
        command: String? = nil,
        commandIcon: String? = nil,
        commandName: String? = nil
    )
    case terminalAttach(project: String, workspace: String, termId: String)
    case aiChat(project: String, workspace: String)
    case evolution(project: String, workspace: String)
    case workspaceDiff(project: String, workspace: String, path: String, mode: String)
    case workspaceEditor(project: String, workspace: String, path: String)
    case workspaceSearch(project: String, workspace: String)
}

@main
struct TidyFlowiOSApp: App {
    @StateObject private var appState = MobileAppState()
    @Environment(\.scenePhase) private var scenePhase

    private var perfFixtureScenario: AIChatPerfFixtureScenario? {
        AIChatPerfFixtureScenario.current()
    }

    private var evolutionPerfFixtureScenario: EvolutionPerfFixtureScenario? {
        EvolutionPerfFixtureScenario.current()
    }

    private enum PerfFixtureLaunchDestination {
        case aiChat(AIChatPerfFixtureScenario)
        case evolution(EvolutionPerfFixtureScenario)
        case terminal(TerminalPerfFixtureScenario)
        case gitPanel(GitPanelPerfFixtureScenario)
    }

    private var perfFixtureLaunchDestination: PerfFixtureLaunchDestination? {
        if let terminalScenario = TerminalPerfFixtureScenario.current() {
            return .terminal(terminalScenario)
        }
        if let gitScenario = GitPanelPerfFixtureScenario.current() {
            return .gitPanel(gitScenario)
        }
        if let evolutionPerfFixtureScenario {
            return .evolution(evolutionPerfFixtureScenario)
        }
        if let perfFixtureScenario {
            return .aiChat(perfFixtureScenario)
        }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .top) {
                NavigationStack(path: $appState.navigationPath) {
                    rootView
                        .navigationDestination(for: MobileRoute.self) { route in
                            switch route {
                            case .projects:
                                ProjectListView(appState: appState)
                            case .settings:
                                MobileSettingsView()
                            case .workspaceDetail(let project, let workspace):
                                WorkspaceDetailView(appState: appState, project: project, workspace: workspace)
                            case .workspaceExplorer(let project, let workspace):
                                WorkspaceExplorerView(project: project, workspace: workspace)
                            case .workspaceTasks(let project, let workspace):
                                WorkspaceTasksView(appState: appState, project: project, workspace: workspace)
                            case .workspaceTodos(let project, let workspace):
                                WorkspaceTodosView(appState: appState, project: project, workspace: workspace)
                            case .workspaceGit(let project, let workspace):
                                WorkspaceGitView(project: project, workspace: workspace)
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
                            case .aiChat(let project, let workspace):
                                MobileAIChatView(
                                    appState: appState,
                                    aiChatStore: appState.aiChatStore,
                                    project: project,
                                    workspace: workspace
                                )
                            case .evolution(let project, let workspace):
                                MobileEvolutionView(
                                    appState: appState,
                                    project: project,
                                    workspace: workspace
                                )
                            case .workspaceDiff(let project, let workspace, let path, let mode):
                                WorkspaceDiffView(
                                    project: project,
                                    workspace: workspace,
                                    path: path,
                                    initialMode: mode
                                )
                                .environmentObject(appState)
                            case .workspaceEditor(let project, let workspace, let path):
                                MobileEditorView(
                                    appState: appState,
                                    project: project,
                                    workspace: workspace,
                                    path: path
                                )
                            case .workspaceSearch(let project, let workspace):
                                MobileSearchView(
                                    appState: appState,
                                    project: project,
                                    workspace: workspace
                                )
                            }
                        }
                }
                .environmentObject(appState)
                .environment(appState.aiChatStore)
                .environmentObject(appState.aiSessionListStore)

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

    @ViewBuilder
    private var rootView: some View {
        if let destination = perfFixtureLaunchDestination {
            switch destination {
            case .terminal(let terminalScenario):
                // 终端输出性能 fixture：直接进入终端页，绕过连接页。
                MobileTerminalView(
                    project: terminalScenario.project,
                    workspace: terminalScenario.workspace,
                    termId: terminalScenario.termId
                )
                .environmentObject(appState)
            case .gitPanel(let gitScenario):
                // Git 面板性能 fixture：直接进入 Git 面板，绕过连接页。
                WorkspaceGitView(
                    project: gitScenario.project,
                    workspace: gitScenario.workspace
                )
                .environmentObject(appState)
            case .evolution(let evolutionScenario):
                // Evolution 面板性能 fixture：直接进入 MobileEvolutionView，绕过连接页。
                // 支持基础场景 evolution_panel 与多工作区场景 evolution_panel_multi_workspace。
                MobileEvolutionView(
                    appState: appState,
                    project: evolutionScenario.project,
                    workspace: evolutionScenario.workspace
                )
            case .aiChat(let chatScenario):
                // 聊天流式性能 fixture：直接进入 MobileAIChatView，绕过连接页。
                // 支持基础场景 stream_heavy 与多工作区场景 chat_stream_workspace_switch。
                MobileAIChatView(
                    appState: appState,
                    aiChatStore: appState.aiChatStore,
                    project: chatScenario.project,
                    workspace: chatScenario.workspace
                )
            }
        } else {
            ConnectionView()
        }
    }
}
