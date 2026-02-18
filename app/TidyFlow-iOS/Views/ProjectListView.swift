import SwiftUI

/// 项目列表视图
struct ProjectListView: View {
    @EnvironmentObject var appState: MobileAppState

    var body: some View {
        List {
            if appState.sortedProjectsForSidebar.isEmpty {
                ContentUnavailableView("暂无项目", systemImage: "folder")
            } else {
                ForEach(appState.sortedProjectsForSidebar, id: \.name) { project in
                    Section {
                        let workspaces = appState.workspacesForProject(project.name)
                        if workspaces.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.85)
                                Text("加载工作空间中...")
                                    .foregroundColor(.secondary)
                            }
                            .onAppear {
                                appState.requestWorkspacesIfNeeded(project: project.name)
                            }
                        } else {
                            ForEach(workspaces, id: \.name) { workspace in
                                NavigationLink(value: MobileRoute.workspaceDetail(
                                    project: project.name,
                                    workspace: workspace.name
                                )) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(workspace.name)
                                            .font(.body)
                                        HStack(spacing: 8) {
                                            Text(workspace.branch)
                                            Text(workspace.status)
                                        }
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(.headline)
                            if !project.root.isEmpty {
                                Text(project.root)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("项目")
        .refreshable {
            appState.refreshProjectTree()
        }
        .onAppear {
            appState.refreshProjectTree()
        }
    }
}
