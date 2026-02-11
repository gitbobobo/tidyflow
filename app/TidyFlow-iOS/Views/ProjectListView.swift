import SwiftUI

/// 项目列表视图
struct ProjectListView: View {
    @EnvironmentObject var appState: MobileAppState

    var body: some View {
        List {
            if appState.projects.isEmpty {
                ContentUnavailableView("暂无项目", systemImage: "folder")
            } else {
                ForEach(appState.projects, id: \.name) { project in
                    NavigationLink(value: MobileRoute.workspaces(project: project.name)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.name)
                                .font(.body)
                            if !project.root.isEmpty {
                                Text(project.root)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("项目")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.disconnect()
                    appState.navigationPath.removeLast(appState.navigationPath.count)
                } label: {
                    Text("断开")
                        .foregroundColor(.red)
                }
            }
        }
    }
}
