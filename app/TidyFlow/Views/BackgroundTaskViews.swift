import SwiftUI

// MARK: - 工具栏按钮

struct BackgroundTaskToolbarButton: View {
    @ObservedObject var taskManager: BackgroundTaskManager
    @EnvironmentObject var appState: AppState
    @State private var showPopover = false

    private var currentWorkspaceKey: String? {
        appState.currentGlobalWorkspaceKey
    }

    private var activeCount: Int {
        guard let key = currentWorkspaceKey else { return 0 }
        return taskManager.activeTaskCount(for: key)
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            if activeCount > 0 {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 16, height: 16)
                    Text("\(activeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }
            } else {
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .frame(width: 14, height: 14)
                    .foregroundColor(.secondary)
            }
        }
        .help("toolbar.backgroundTasks".localized)
        .popover(isPresented: $showPopover) {
            if let key = currentWorkspaceKey {
                BackgroundTaskPopoverView(
                    taskManager: taskManager,
                    workspaceKey: key
                )
                .environmentObject(appState)
            }
        }
    }
}

// MARK: - Popover 主视图

struct BackgroundTaskPopoverView: View {
    @ObservedObject var taskManager: BackgroundTaskManager
    let workspaceKey: String
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // 标题 + Tab 切换
            HStack {
                Text("task.title".localized)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("", selection: $selectedTab) {
                    Text("task.tab.active".localized).tag(0)
                    Text("task.tab.completed".localized).tag(1)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 150)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if selectedTab == 0 {
                ActiveTaskListView(
                    taskManager: taskManager,
                    workspaceKey: workspaceKey
                )
                .environmentObject(appState)
            } else {
                CompletedTaskListView(
                    taskManager: taskManager,
                    workspaceKey: workspaceKey
                )
            }
        }
        .frame(width: 380, height: 420)
        .onAppear {
            let hasActive = !taskManager.allRunningTasks(for: workspaceKey).isEmpty
                || !taskManager.pendingTasks(for: workspaceKey).isEmpty
            selectedTab = hasActive ? 0 : 1
        }
    }
}

// MARK: - 活跃任务列表

struct ActiveTaskListView: View {
    @ObservedObject var taskManager: BackgroundTaskManager
    let workspaceKey: String
    @EnvironmentObject var appState: AppState

    private var runningTasks: [BackgroundTask] {
        taskManager.allRunningTasks(for: workspaceKey)
    }

    private var pendingTasks: [BackgroundTask] {
        taskManager.pendingTasks(for: workspaceKey)
    }

    var body: some View {
        if runningTasks.isEmpty && pendingTasks.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("task.noActive".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(runningTasks) { task in
                    RunningTaskRow(task: task)
                }
                if !pendingTasks.isEmpty {
                    Section("task.section.pending".localized) {
                        ForEach(pendingTasks) { task in
                            PendingTaskRow(task: task)
                        }
                        .onMove { from, to in
                            appState.reorderPendingTasks(
                                for: workspaceKey,
                                fromOffsets: from,
                                toOffset: to
                            )
                        }
                        .onDelete { offsets in
                            let tasks = taskManager.pendingTasks(for: workspaceKey)
                            for idx in offsets {
                                appState.removeBackgroundTask(tasks[idx])
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - 运行中任务行

struct RunningTaskRow: View {
    @ObservedObject var task: BackgroundTask
    @EnvironmentObject var appState: AppState
    /// 每秒递增，驱动 durationText 刷新
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            CommandIconView(iconName: task.taskIconName, size: 12)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayTitle)
                    .font(.system(size: 13))
                // 项目命令实时输出最后一行
                if let line = task.lastOutputLine, !line.isEmpty {
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Text(task.durationText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .id(tick)
            Button {
                appState.stopBackgroundTask(task)
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("task.stop".localized)
        }
        .padding(.vertical, 2)
        .onReceive(timer) { _ in
            tick += 1
        }
    }
}

// MARK: - 等待中任务行

struct PendingTaskRow: View {
    @ObservedObject var task: BackgroundTask
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            CommandIconView(iconName: task.taskIconName, size: 12)
                .foregroundColor(.secondary)
            Text(task.displayTitle)
                .font(.system(size: 13))
            Spacer()
            Button {
                appState.removeBackgroundTask(task)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("task.remove".localized)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 已完成任务列表

struct CompletedTaskListView: View {
    @ObservedObject var taskManager: BackgroundTaskManager
    let workspaceKey: String
    @State private var selectedTaskId: UUID?

    private var completedTasks: [BackgroundTask] {
        taskManager.completedTasks(for: workspaceKey)
    }

    private var selectedTask: BackgroundTask? {
        completedTasks.first(where: { $0.id == selectedTaskId })
    }

    var body: some View {
        if completedTasks.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("task.noCompleted".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                // 任务列表
                List(completedTasks, selection: $selectedTaskId) { task in
                    CompletedTaskRow(task: task)
                        .tag(task.id)
                }
                .listStyle(.plain)
                .frame(height: 160)

                Divider()

                // 结果详情
                if let task = selectedTask, let result = task.result {
                    TaskResultDetailView(result: result)
                } else {
                    VStack {
                        Spacer()
                        Text("task.selectToViewResult".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - 已完成任务行

struct CompletedTaskRow: View {
    @ObservedObject var task: BackgroundTask

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.status.completedIconName)
                .font(.system(size: 12))
                .foregroundColor(task.status.completedIconColor)
            CommandIconView(iconName: task.taskIconName, size: 12)
            Text(task.displayTitle)
                .font(.system(size: 13))
            Spacer()
            Text(task.durationText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 任务结果详情

struct TaskResultDetailView: View {
    let result: BackgroundTaskResult
    @State private var showRawOutput = false

    var body: some View {
        // 整块详情仅用一层 ScrollView，内部输出区块不再嵌套 ScrollView，避免双层滚动条
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // 状态
                HStack(spacing: 6) {
                    Image(systemName: result.resultStatus.iconName)
                        .foregroundColor(result.resultStatus.iconColor)
                    Text(result.summaryLine)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // 类型特定详情
                switch result {
                case .aiCommit(let r):
                    aiCommitDetail(r)
                case .aiMerge(let r):
                    aiMergeDetail(r)
                case .projectCommand(let r):
                    projectCommandDetail(r)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func aiCommitDetail(_ r: AICommitResult) -> some View {
        if !r.commits.isEmpty {
            Text(String(format: "git.aiCommit.commitCount".localized, r.commits.count))
                .font(.system(size: 12, weight: .medium))
            ForEach(r.commits) { commit in
                HStack(spacing: 4) {
                    Text(commit.sha.prefix(7))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.accentColor)
                    Text(commit.message)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
        }
        rawOutputSection(r.rawOutput)
    }

    @ViewBuilder
    private func aiMergeDetail(_ r: AIMergeResult) -> some View {
        if !r.conflicts.isEmpty {
            Text("sidebar.aiMerge.conflicts".localized)
                .font(.system(size: 12, weight: .medium))
            ForEach(r.conflicts, id: \.self) { file in
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(file)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        }
        rawOutputSection(r.rawOutput)
    }

    @ViewBuilder
    private func projectCommandDetail(_ r: ProjectCommandResult) -> some View {
        if !r.message.isEmpty {
            Text(r.message)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .cornerRadius(4)
        }
    }

    @ViewBuilder
    private func rawOutputSection(_ output: String) -> some View {
        if !output.isEmpty {
            DisclosureGroup(
                isExpanded: $showRawOutput,
                content: {
                    Text(output)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                        .cornerRadius(4)
                },
                label: {
                    Text("sidebar.aiMerge.rawOutput".localized)
                        .font(.system(size: 11, weight: .medium))
                }
            )
        }
    }
}
