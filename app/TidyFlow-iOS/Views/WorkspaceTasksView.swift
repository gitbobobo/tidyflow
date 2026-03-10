import SwiftUI

/// 工作空间后台任务列表页。消费 WorkspaceTaskSemantics / WorkspaceTaskStore 共享语义层。
struct WorkspaceTasksView: View {
    let appState: MobileAppState
    let project: String
    let workspace: String
    @State private var projectionStore = WorkspaceTaskListProjectionStore()

    private var projection: WorkspaceTaskListProjection {
        projectionStore.projection
    }

    var body: some View {
        List {
            if projection.sections.isEmpty {
                ContentUnavailableView("暂无后台任务", systemImage: "tray")
            } else {
                ForEach(projection.sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { task in
                            taskRow(task)
                        }
                    }
                }
            }
        }
        .navigationTitle("后台任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if projection.terminalTaskCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.clearCompletedTasks(project: project, workspace: workspace)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .refreshable {
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
        .task(id: "\(project):\(workspace)") {
            projectionStore.bind(appState: appState, project: project, workspace: workspace)
        }
    }

    @ViewBuilder
    private func taskRow(_ task: WorkspaceTaskRowProjection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                MobileCommandIconView(iconName: task.iconName, size: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.body)
                    HStack(spacing: 6) {
                        Text(task.statusSummary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        // 耗时文本
                        if !task.durationText.isEmpty {
                            Text(task.durationText)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fontDesign(.monospaced)
                        }
                    }
                    if let line = task.lastOutputLine, !line.isEmpty {
                        Text(line)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if task.status.isActive {
                    if task.canCancel {
                        Button {
                            appState.cancelTask(project: project, workspace: workspace, taskID: task.id)
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

            // 失败诊断摘要（仅失败时显示）
            if let summary = task.failureSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(3)
                    .padding(.leading, 26)
            }

            // 重试按钮（仅 Core 标记可重试时显示）
            if let descriptor = task.retryDescriptor {
                HStack {
                    Spacer()
                    Button {
                        appState.retryTask(descriptor: descriptor)
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(task.status == .failed ? Color.red.opacity(0.04) : nil)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if task.canCancel {
                Button(role: .destructive) {
                    appState.cancelTask(project: project, workspace: workspace, taskID: task.id)
                } label: {
                    Label("取消", systemImage: "stop.circle")
                }
            }
            if let descriptor = task.retryDescriptor {
                Button {
                    appState.retryTask(descriptor: descriptor)
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .tint(.orange)
            }
        }
    }

    @ViewBuilder
    private func taskStatusIcon(_ task: WorkspaceTaskRowProjection) -> some View {
        Image(systemName: task.status.completedIconName)
            .foregroundColor(task.status.completedIconColor)
    }
}

/// 工作空间待办列表页。
struct WorkspaceTodosView: View {
    let appState: MobileAppState
    let project: String
    let workspace: String

    @State private var showAddSheet = false
    @State private var editingItem: WorkspaceTodoRowProjection?
    @State private var projectionStore = WorkspaceTodoProjectionStore()

    private var projection: WorkspaceTodoProjection {
        projectionStore.projection
    }

    var body: some View {
        List {
            if projection.totalCount == 0 {
                ContentUnavailableView("todo.empty".localized, systemImage: "checklist")
            } else {
                ForEach(projection.sections) { section in
                    todoSection(section: section)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("todo.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("todo.add".localized)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            TodoEditorSheet(title: "todo.add".localized) { title, note in
                let created = appState.addWorkspaceTodo(
                    project: project,
                    workspace: workspace,
                    title: title,
                    note: note
                )
                return created != nil
            }
        }
        .sheet(item: $editingItem) { item in
            TodoEditorSheet(
                title: "todo.edit".localized,
                initialTitle: item.title,
                initialNote: item.note ?? ""
            ) { title, note in
                appState.updateWorkspaceTodo(
                    project: project,
                    workspace: workspace,
                    todoID: item.id,
                    title: title,
                    note: note
                )
            }
        }
        .task(id: "\(project):\(workspace)") {
            projectionStore.bind(appState: appState, project: project, workspace: workspace)
        }
    }

    @ViewBuilder
    private func todoSection(section: WorkspaceTodoSectionProjection) -> some View {
        Section(section.title) {
            ForEach(section.items) { item in
                TodoListRow(
                    item: item,
                    onEdit: { editingItem = item },
                    onDelete: {
                        _ = appState.deleteWorkspaceTodo(
                            project: project,
                            workspace: workspace,
                            todoID: item.id
                        )
                    },
                    onChangeStatus: { nextStatus in
                        _ = appState.setWorkspaceTodoStatus(
                            project: project,
                            workspace: workspace,
                            todoID: item.id,
                            status: nextStatus
                        )
                    }
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        _ = appState.deleteWorkspaceTodo(
                            project: project,
                            workspace: workspace,
                            todoID: item.id
                        )
                    } label: {
                        Label("todo.delete".localized, systemImage: "trash")
                    }
                }
            }
            .onMove { from, to in
                appState.moveWorkspaceTodos(
                    project: project,
                    workspace: workspace,
                    status: section.status,
                    fromOffsets: from,
                    toOffset: to
                )
            }
        }
    }
}

private struct TodoListRow: View {
    let item: WorkspaceTodoRowProjection
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onChangeStatus: (WorkspaceTodoStatus) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                if let note = item.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Menu {
                ForEach(WorkspaceTodoStatus.allCases, id: \.rawValue) { status in
                    Button(status.localizedTitle) {
                        onChangeStatus(status)
                    }
                }
            } label: {
                Text(item.status.localizedTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

private struct TodoEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let onSave: (String, String?) -> Bool

    @State private var todoTitle: String
    @State private var todoNote: String

    init(
        title: String,
        initialTitle: String = "",
        initialNote: String = "",
        onSave: @escaping (String, String?) -> Bool
    ) {
        self.title = title
        self.onSave = onSave
        _todoTitle = State(initialValue: initialTitle)
        _todoNote = State(initialValue: initialNote)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("todo.input.title".localized, text: $todoTitle)
                    TextField("todo.input.note".localized, text: $todoNote)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.cancel".localized) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.confirm".localized) {
                        let saved = onSave(todoTitle, todoNote)
                        if saved {
                            dismiss()
                        }
                    }
                    .disabled(todoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
