import SwiftUI

/// 工作空间详情页：终端、后台任务、代码变更汇总与工具栏操作。
struct WorkspaceDetailView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    private var terminals: [TerminalSessionInfo] {
        appState.terminalsForWorkspace(project: project, workspace: workspace)
    }

    private var runningTasks: [MobileWorkspaceTask] {
        appState.runningTasksForWorkspace(project: project, workspace: workspace)
    }

    private var gitSummary: MobileWorkspaceGitSummary {
        appState.gitSummaryForWorkspace(project: project, workspace: workspace)
    }

    private var projectCommands: [ProjectCommand] {
        appState.projectCommands(for: project)
    }

    var body: some View {
        List {
            Section("代码变更") {
                HStack(spacing: 16) {
                    Label("+\(gitSummary.additions)", systemImage: "plus")
                        .foregroundColor(.green)
                    Label("-\(gitSummary.deletions)", systemImage: "minus")
                        .foregroundColor(.red)
                }
                .font(.headline)
                .padding(.vertical, 4)
            }

            Section("活跃终端") {
                if terminals.isEmpty {
                    Text("暂无活跃终端")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(terminals.enumerated()), id: \.element.termId) { index, term in
                        NavigationLink(value: MobileRoute.terminalAttach(
                            project: project,
                            workspace: workspace,
                            termId: term.termId
                        )) {
                            HStack(spacing: 10) {
                                let presentation = appState.terminalPresentation(for: term.termId)
                                MobileCommandIconView(
                                    iconName: presentation?.icon ?? "terminal",
                                    size: 18
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(presentation?.name ?? "终端 \(index + 1)")
                                        .font(.body)
                                    Text(String(term.termId.prefix(8)))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            Section("后台任务") {
                if runningTasks.isEmpty {
                    Text("当前无进行中的后台任务")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(runningTasks) { task in
                        NavigationLink(value: MobileRoute.workspaceTasks(project: project, workspace: workspace)) {
                            HStack(spacing: 10) {
                                MobileCommandIconView(iconName: task.icon, size: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                    Text(task.message)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.9)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .navigationTitle(workspace)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                newTerminalMenu
                moreActionsMenu
            }
        }
        .refreshable {
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
        .onAppear {
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
    }

    private var newTerminalMenu: some View {
        Menu {
            Button {
                appState.navigationPath.append(MobileRoute.terminal(project: project, workspace: workspace))
            } label: {
                Label("新建终端", systemImage: "terminal")
            }

            if !appState.customCommands.isEmpty {
                Divider()
                ForEach(appState.customCommands) { cmd in
                    Button {
                        appState.navigationPath.append(MobileRoute.terminal(
                            project: project,
                            workspace: workspace,
                            command: cmd.command,
                            commandIcon: cmd.icon,
                            commandName: cmd.name
                        ))
                    } label: {
                        Label {
                            Text(cmd.name)
                        } icon: {
                            MobileCommandIconView(iconName: cmd.icon, size: 14)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    private var moreActionsMenu: some View {
        Menu {
            Button {
                appState.runAICommit(project: project, workspace: workspace)
            } label: {
                Label("一键提交", systemImage: "sparkles")
            }

            Button {
                appState.runAIMerge(project: project, workspace: workspace)
            } label: {
                Label("智能合并", systemImage: "cpu")
            }

            Menu("执行") {
                if projectCommands.isEmpty {
                    Text("当前项目未配置命令")
                } else {
                    ForEach(projectCommands) { command in
                        Button {
                            appState.runProjectCommand(project: project, workspace: workspace, command: command)
                        } label: {
                            Label {
                                Text(command.name)
                            } icon: {
                                MobileCommandIconView(iconName: command.icon, size: 14)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}
