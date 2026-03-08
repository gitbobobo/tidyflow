import SwiftUI

/// 工作空间列表视图（按工作空间分组展示活跃终端 + 新建终端入口）
struct WorkspaceListView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String

    var body: some View {
        List {
            if appState.workspaces.isEmpty {
                ContentUnavailableView("暂无工作空间", systemImage: "square.grid.2x2")
            } else {
                ForEach(appState.workspaces, id: \.name) { workspace in
                    Section {
                        let terminals = appState.terminalsForWorkspace(
                            project: project, workspace: workspace.name
                        )
                        ForEach(Array(terminals.enumerated()), id: \.element.termId) { index, term in
                            NavigationLink(value: MobileRoute.terminalAttach(
                                project: project,
                                workspace: workspace.name,
                                termId: term.termId
                            )) {
                                HStack {
                                    Image(systemName: "terminal")
                                        .foregroundColor(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("终端 \(index + 1)")
                                            .font(.body)
                                        Text(String(term.termId.prefix(8)))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    appState.closeTerminal(termId: term.termId)
                                } label: {
                                    Label("终止", systemImage: "xmark.circle")
                                }
                            }
                        }

                        newTerminalButton(workspace: workspace.name)
                    } header: {
                        HStack {
                            Text(workspace.name)
                                .font(.headline)
                            Spacer()
                            Text(workspace.branch)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .accessibilityIdentifier("tf.ios.workspace.item.\(workspace.name)")
                    }
                }
            }
        }
        .navigationTitle(project)
        .accessibilityIdentifier("tf.ios.workspace.list")
        .refreshable {
            appState.selectProject(project)
        }
        .onAppear {
            appState.selectProject(project)
        }
    }

    // MARK: - 新建终端按钮

    @ViewBuilder
    private func newTerminalButton(workspace: String) -> some View {
        let commands = appState.customCommands
        if commands.isEmpty {
            Button {
                appState.navigationPath.append(
                    MobileRoute.terminal(project: project, workspace: workspace)
                )
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.accentColor)
                    Text("新建")
                        .foregroundColor(.accentColor)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tf.ios.workspace.new-terminal.\(workspace)")
        } else {
            Menu {
                Button {
                    appState.navigationPath.append(
                        MobileRoute.terminal(project: project, workspace: workspace)
                    )
                } label: {
                    Label("新建终端", systemImage: "terminal")
                }
                Divider()
                ForEach(commands) { cmd in
                    Button {
                        appState.navigationPath.append(
                            MobileRoute.terminal(
                                project: project,
                                workspace: workspace,
                                command: cmd.command
                            )
                        )
                    } label: {
                        Label(cmd.name, systemImage: iconName(for: cmd.icon))
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.accentColor)
                    Text("新建")
                        .foregroundColor(.accentColor)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            // iOS 的 SwiftUI Menu 在 List 中有概率触发 UIKit 的层级告警（_UIReparentingView）。
            // compositingGroup 可以改变渲染/承载方式，实测能规避部分系统版本的该告警与动画抖动。
            .compositingGroup()
        }
    }

    /// 品牌/自定义图标降级为 terminal
    private func iconName(for icon: String) -> String {
        if icon.hasPrefix("brand:") || icon.hasPrefix("custom:") {
            return "terminal"
        }
        return icon
    }
}
