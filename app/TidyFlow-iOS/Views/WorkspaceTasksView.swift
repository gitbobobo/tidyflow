import SwiftUI

/// 工作空间后台任务列表页。消费 WorkspaceTaskSemantics / WorkspaceTaskStore 共享语义层。
struct WorkspaceTasksView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    private var workspaceKey: String {
        appState.globalWorkspaceKey(project: project, workspace: workspace)
    }

    private var tasks: [WorkspaceTaskItem] {
        appState.tasksForWorkspace(project: project, workspace: workspace)
    }

    private var activeTasks: [WorkspaceTaskItem] {
        appState.taskStore.activeTasks(for: workspaceKey)
    }

    private var completedTasks: [WorkspaceTaskItem] {
        tasks.filter { $0.status == .completed }
    }

    private var failedTasks: [WorkspaceTaskItem] {
        tasks.filter { $0.status == .failed || $0.status == .unknown }
    }

    private var cancelledTasks: [WorkspaceTaskItem] {
        tasks.filter { $0.status == .cancelled }
    }

    var body: some View {
        List {
            if tasks.isEmpty {
                ContentUnavailableView("暂无后台任务", systemImage: "tray")
            } else {
                if !activeTasks.isEmpty {
                    Section(WorkspaceTaskStatus.running.sectionTitle) {
                        ForEach(activeTasks) { task in
                            taskRow(task)
                        }
                    }
                }

                if !failedTasks.isEmpty {
                    Section(WorkspaceTaskStatus.failed.sectionTitle) {
                        ForEach(failedTasks) { task in
                            taskRow(task)
                        }
                    }
                }

                if !completedTasks.isEmpty {
                    Section(WorkspaceTaskStatus.completed.sectionTitle) {
                        ForEach(completedTasks) { task in
                            taskRow(task)
                        }
                    }
                }

                if !cancelledTasks.isEmpty {
                    Section(WorkspaceTaskStatus.cancelled.sectionTitle) {
                        ForEach(cancelledTasks) { task in
                            taskRow(task)
                        }
                    }
                }
            }
        }
        .navigationTitle("后台任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !completedTasks.isEmpty || !failedTasks.isEmpty || !cancelledTasks.isEmpty {
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
    }

    @ViewBuilder
    private func taskRow(_ task: WorkspaceTaskItem) -> some View {
        HStack(spacing: 10) {
            MobileCommandIconView(iconName: task.iconName, size: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.body)
                Text(task.statusSummaryText())
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
    private func taskStatusIcon(_ task: WorkspaceTaskItem) -> some View {
        Image(systemName: task.status.completedIconName)
            .foregroundColor(task.status.completedIconColor)
    }
}

/// 工作空间待办列表页。
struct WorkspaceTodosView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    @State private var showAddSheet = false
    @State private var editingItem: WorkspaceTodoItem?

    private var todos: [WorkspaceTodoItem] {
        appState.todosForWorkspace(project: project, workspace: workspace)
    }

    private var pendingTodos: [WorkspaceTodoItem] {
        todos.filter { $0.status == .pending }
    }

    private var inProgressTodos: [WorkspaceTodoItem] {
        todos.filter { $0.status == .inProgress }
    }

    private var completedTodos: [WorkspaceTodoItem] {
        todos.filter { $0.status == .completed }
    }

    var body: some View {
        List {
            if todos.isEmpty {
                ContentUnavailableView("todo.empty".localized, systemImage: "checklist")
            } else {
                todoSection(
                    title: "todo.section.pending".localized,
                    status: .pending,
                    items: pendingTodos
                )
                todoSection(
                    title: "todo.section.inProgress".localized,
                    status: .inProgress,
                    items: inProgressTodos
                )
                todoSection(
                    title: "todo.section.completed".localized,
                    status: .completed,
                    items: completedTodos
                )
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
    }

    @ViewBuilder
    private func todoSection(
        title: String,
        status: WorkspaceTodoStatus,
        items: [WorkspaceTodoItem]
    ) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
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
                        status: status,
                        fromOffsets: from,
                        toOffset: to
                    )
                }
            }
        }
    }
}

private struct TodoListRow: View {
    let item: WorkspaceTodoItem
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
