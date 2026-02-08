import SwiftUI

/// 工具栏项目命令下拉菜单
struct ProjectCommandsMenuView: View {
    @EnvironmentObject var appState: AppState

    /// 当前项目的命令列表
    private var commands: [ProjectCommand] {
        let projectName = appState.selectedProjectName
        guard let project = appState.projects.first(where: { $0.name == projectName }) else {
            return []
        }
        return project.commands
    }

    /// 当前工作空间的全局键
    private var workspaceGlobalKey: String? {
        guard let wsKey = appState.selectedWorkspaceKey else { return nil }
        return "\(appState.selectedProjectName):\(wsKey)"
    }

    /// 是否有正在运行的项目命令
    private var hasRunningCommand: Bool {
        guard let key = workspaceGlobalKey else { return false }
        let running = appState.taskManager.allRunningTasks(for: key)
        return running.contains(where: { $0.type == .projectCommand })
    }

    var body: some View {
        Menu {
            ForEach(commands) { cmd in
                Button {
                    runCommand(cmd)
                } label: {
                    Label {
                        Text(cmd.name)
                    } icon: {
                        CommandIconView(iconName: cmd.icon, size: 14)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if hasRunningCommand {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "play.circle")
                        .font(.system(size: 14))
                }
                Text("toolbar.run".localized)
            }
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8)
        .fixedSize()
        .help("toolbar.projectCommands".localized)
    }

    private func runCommand(_ cmd: ProjectCommand) {
        guard let wsKey = appState.selectedWorkspaceKey else { return }
        appState.runProjectCommand(
            projectName: appState.selectedProjectName,
            workspaceName: wsKey,
            command: cmd
        )
    }
}
