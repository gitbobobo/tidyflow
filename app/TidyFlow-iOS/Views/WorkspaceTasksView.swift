import SwiftUI

/// 工作空间后台任务列表页。
struct WorkspaceTasksView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    private var tasks: [MobileWorkspaceTask] {
        appState.tasksForWorkspace(project: project, workspace: workspace)
    }

    private var activeTasks: [MobileWorkspaceTask] {
        tasks.filter { $0.status.isActive }
    }

    private var completedTasks: [MobileWorkspaceTask] {
        tasks.filter { !$0.status.isActive }
    }

    var body: some View {
        List {
            if tasks.isEmpty {
                ContentUnavailableView("暂无后台任务", systemImage: "tray")
            } else {
                if !activeTasks.isEmpty {
                    Section("进行中") {
                        ForEach(activeTasks) { task in
                            taskRow(task)
                        }
                    }
                }

                if !completedTasks.isEmpty {
                    Section("已完成") {
                        ForEach(completedTasks) { task in
                            taskRow(task)
                        }
                    }
                }
            }
        }
        .navigationTitle("后台任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !completedTasks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.clearCompletedTasks(project: project, workspace: workspace)
                    } label: {
                        Text("清除已完成")
                            .font(.caption)
                    }
                }
            }
        }
        .refreshable {
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
    }

    @ViewBuilder
    private func taskRow(_ task: MobileWorkspaceTask) -> some View {
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
                if appState.canCancelTask(task) {
                    Button {
                        appState.cancelTask(task)
                    } label: {
                        Image(systemName: "stop.circle")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                ProgressView()
                    .scaleEffect(0.9)
            } else {
                taskStatusIcon(task)
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

    @ViewBuilder
    private func taskStatusIcon(_ task: MobileWorkspaceTask) -> some View {
        switch task.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        case .running:
            ProgressView()
                .scaleEffect(0.9)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .cancelled:
            Image(systemName: "slash.circle")
                .foregroundColor(.secondary)
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

        var parts = [status]
        if !task.message.isEmpty {
            parts.append(task.message)
        }
        if let completedAt = task.completedAt, !task.status.isActive {
            parts.append(relativeTimeString(completedAt))
        }
        return parts.joined(separator: " · ")
    }

    private func relativeTimeString(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            return "\(Int(interval / 60))分钟前"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))小时前"
        } else {
            return "\(Int(interval / 86400))天前"
        }
    }
}
