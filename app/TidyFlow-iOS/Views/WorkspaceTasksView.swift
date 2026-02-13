import SwiftUI

/// 工作空间后台任务列表页。
struct WorkspaceTasksView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    private var tasks: [MobileWorkspaceTask] {
        appState.tasksForWorkspace(project: project, workspace: workspace)
    }

    var body: some View {
        List {
            if tasks.isEmpty {
                ContentUnavailableView("暂无后台任务", systemImage: "tray")
            } else {
                ForEach(tasks) { task in
                    HStack(spacing: 10) {
                        MobileCommandIconView(iconName: task.icon, size: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title)
                                .font(.body)
                            Text(taskStatusText(task))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            if let line = task.lastOutputLine, !line.isEmpty {
                                Text(line)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if task.status.isActive {
                            ProgressView()
                                .scaleEffect(0.9)
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if appState.canCancelTask(task) {
                            Button(role: .destructive) {
                                appState.cancelTask(task)
                            } label: {
                                Label("取消", systemImage: "stop.circle")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("后台任务")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
    }

    private func taskStatusText(_ task: MobileWorkspaceTask) -> String {
        let status: String
        switch task.status {
        case .pending: status = "等待中"
        case .running: status = "运行中"
        case .completed: status = "已完成"
        case .failed: status = "失败"
        case .cancelled: status = "已取消"
        }

        if task.message.isEmpty {
            return status
        }
        return "\(status) · \(task.message)"
    }
}
