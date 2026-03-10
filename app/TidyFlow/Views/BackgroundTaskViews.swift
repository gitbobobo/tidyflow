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
        return taskManager.taskStore.activeCount(for: key)
    }

    private var hasFailures: Bool {
        guard let key = currentWorkspaceKey else { return false }
        return taskManager.taskStore.runStatusGroup(for: key)?.hasFailures ?? false
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
            } else if hasFailures {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
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

    private var statusGroup: WorkspaceRunStatusGroup? {
        taskManager.taskStore.runStatusGroup(for: workspaceKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("task.title".localized)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let group = statusGroup, !group.failedTasks.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                        Text("\(group.failedTasks.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.red)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if let group = statusGroup {
                UnifiedTaskStatusListView(
                    group: group,
                    taskManager: taskManager,
                    workspaceKey: workspaceKey
                )
                .environmentObject(appState)
            } else {
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
            }
        }
        .frame(width: 380, height: 420)
    }
}

// MARK: - 统一任务状态列表（活跃 → 失败 → 已完成）

struct UnifiedTaskStatusListView: View {
    let group: WorkspaceRunStatusGroup
    @ObservedObject var taskManager: BackgroundTaskManager
    let workspaceKey: String
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            // 活跃任务区
            if !group.activeTasks.isEmpty {
                Section("task.tab.active".localized) {
                    ForEach(group.activeTasks) { task in
                        UnifiedActiveTaskRow(task: task)
                            .environmentObject(appState)
                    }
                }
            }

            // 失败任务区（高亮 + 重试按钮）
            if !group.failedTasks.isEmpty {
                Section {
                    ForEach(group.failedTasks) { task in
                        UnifiedFailedTaskRow(task: task)
                            .environmentObject(appState)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text(WorkspaceTaskStatus.failed.sectionTitle)
                        if group.retryableCount > 0 {
                            Text("·")
                            Text("\(group.retryableCount) 可重试")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            // 已完成任务区
            if !group.completedTasks.isEmpty {
                Section(WorkspaceTaskStatus.completed.sectionTitle) {
                    ForEach(group.completedTasks) { task in
                        UnifiedCompletedTaskRow(task: task)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - 统一活跃任务行

struct UnifiedActiveTaskRow: View {
    let task: WorkspaceTaskItem
    @EnvironmentObject var appState: AppState
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            CommandIconView(iconName: task.iconName, size: 12)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13))
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
            if task.isCancellable {
                Button {
                    DispatchQueue.main.async {
                        appState.stopTask(byItemId: task.id)
                    }
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("task.stop".localized)
            }
        }
        .padding(.vertical, 2)
        .onReceive(timer) { _ in tick += 1 }
    }
}

// MARK: - 统一失败任务行（诊断摘要 + 重试按钮）

struct UnifiedFailedTaskRow: View {
    let task: WorkspaceTaskItem
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: task.status.completedIconName)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                CommandIconView(iconName: task.iconName, size: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 13))
                    // 耗时
                    if !task.durationText.isEmpty {
                        Text(task.durationText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                // 重试按钮（仅 Core 标记可重试时显示）
                if let descriptor = task.retryDescriptor {
                    Button {
                        DispatchQueue.main.async {
                            appState.retryTask(descriptor: descriptor)
                        }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                }
            }

            // 失败诊断摘要
            if let summary = task.failureSummary {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.9))
                    .lineLimit(3)
                    .padding(.leading, 20)
            }

            // 详细错误信息
            if let detail = task.errorDetail, !detail.isEmpty, task.failureSummary == nil || task.errorCode != nil {
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.red.opacity(0.04))
    }
}

// MARK: - 统一已完成任务行

struct UnifiedCompletedTaskRow: View {
    let task: WorkspaceTaskItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.status.completedIconName)
                .font(.system(size: 12))
                .foregroundColor(task.status.completedIconColor)
            CommandIconView(iconName: task.iconName, size: 12)
            Text(task.title)
                .font(.system(size: 13))
            Spacer()
            Text(task.durationText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
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
                            let tasksToRemove = offsets.map { tasks[$0] }
                            DispatchQueue.main.async {
                                for task in tasksToRemove {
                                    appState.removeBackgroundTask(task)
                                }
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
                // 延迟执行，避免 Popover 内部状态变更触发 NSPopoverFrame 释放时 KVO 野指针崩溃
                DispatchQueue.main.async {
                    appState.stopBackgroundTask(task)
                }
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
                DispatchQueue.main.async {
                    appState.removeBackgroundTask(task)
                }
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
