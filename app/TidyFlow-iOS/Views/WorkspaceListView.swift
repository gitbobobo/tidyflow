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
                        // 该工作空间的活跃终端
                        let terminals = appState.terminalsForWorkspace(project: project, workspace: workspace.name)
                        ForEach(terminals, id: \.termId) { term in
                            Button {
                                appState.navigationPath.append(
                                    MobileRoute.terminalAttach(
                                        project: project,
                                        workspace: workspace.name,
                                        termId: term.termId
                                    )
                                )
                            } label: {
                                HStack {
                                    Image(systemName: "terminal")
                                        .foregroundColor(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(term.shell.isEmpty ? "Terminal" : term.shell)
                                            .font(.body)
                                        Text(term.termId.prefix(8))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }

                        // 新建终端按钮
                        Button {
                            appState.navigationPath.append(
                                MobileRoute.terminal(
                                    project: project,
                                    workspace: workspace.name
                                )
                            )
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle")
                                    .foregroundColor(.accentColor)
                                Text("新建终端")
                                    .foregroundColor(.accentColor)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    } header: {
                        HStack {
                            Text(workspace.name)
                                .font(.headline)
                            Spacer()
                            Text(workspace.branch)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(project)
        .refreshable {
            appState.selectProject(project)
        }
        .onAppear {
            appState.selectProject(project)
        }
    }
}

