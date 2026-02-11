import SwiftUI

/// 工作空间列表视图
struct WorkspaceListView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String

    var body: some View {
        List {
            if appState.workspaces.isEmpty {
                ContentUnavailableView("暂无工作空间", systemImage: "square.grid.2x2")
            } else {
                ForEach(appState.workspaces, id: \.name) { workspace in
                    Button {
                        appState.navigationPath.append(
                            MobileRoute.terminal(project: project, workspace: workspace.name)
                        )
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workspace.name)
                                    .font(.body)
                                Text(workspace.branch)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "terminal")
                                .foregroundColor(.accentColor)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(project)
        .onAppear {
            appState.selectProject(project)
        }
    }
}
