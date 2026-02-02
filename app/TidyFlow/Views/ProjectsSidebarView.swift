import SwiftUI

/// Project Tree Sidebar - Shows Projects > Workspaces hierarchy
/// UX-1: Replaces flat workspace list with collapsible project tree
struct ProjectsSidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header with Add Project button
            HStack {
                Text("Projects")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    appState.addProjectSheetPresented = true
                }) {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Add Project")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Project Tree or Empty State
            if appState.projects.isEmpty {
                emptyStateView
            } else {
                projectListView
            }
        }
        .frame(minWidth: 200)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No Projects")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Add a project to get started")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
            Button("Add Project") {
                appState.addProjectSheetPresented = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Project List

    private var projectListView: some View {
        List(selection: Binding(
            get: { appState.selectedWorkspaceKey },
            set: { newValue in
                if let ws = newValue {
                    // Find which project this workspace belongs to
                    for project in appState.projects {
                        if project.workspaces.contains(where: { $0.name == ws }) {
                            appState.selectWorkspace(projectId: project.id, workspaceName: ws)
                            return
                        }
                    }
                }
                appState.selectedWorkspaceKey = newValue
            }
        )) {
            ForEach($appState.projects) { $project in
                ProjectRowView(project: $project)
                    .environmentObject(appState)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Project Row (Collapsible)

struct ProjectRowView: View {
    @Binding var project: ProjectModel
    @EnvironmentObject var appState: AppState
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project Header Row
            HStack(spacing: 6) {
                // Chevron indicator
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(project.isExpanded ? .degrees(90) : .zero)
                    .animation(.easeInOut(duration: 0.2), value: project.isExpanded)

                Image(systemName: "folder.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(project.name)
                    .fontWeight(.medium)
                Spacer()
                Text("\(project.workspaces.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle()) // Make entire row tappable
            .onTapGesture {
                withAnimation {
                    project.isExpanded.toggle()
                }
            }
            .contextMenu {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("移除项目", systemImage: "trash")
                }
            }
            .alert("移除项目", isPresented: $showDeleteConfirmation) {
                Button("取消", role: .cancel) { }
                Button("移除", role: .destructive) {
                    appState.removeProject(id: project.id)
                }
            } message: {
                Text("确定要移除项目 \"\(project.name)\" 吗？\n此操作仅从列表移除，不会删除磁盘文件。")
            }

            // Workspaces List
            if project.isExpanded {
                ForEach(project.workspaces) { workspace in
                    WorkspaceRowView(
                        workspace: workspace,
                        projectId: project.id,
                        isSelected: appState.selectedWorkspaceKey == workspace.name
                    )
                    .environmentObject(appState)
                    .padding(.leading, 18) // Indent workspaces
                }
            }
        }
    }
}

// MARK: - Workspace Row

struct WorkspaceRowView: View {
    let workspace: WorkspaceModel
    let projectId: UUID
    let isSelected: Bool
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .foregroundColor(.blue)
                .font(.caption)
            Text(workspace.name)
            Spacer()
            if let status = workspace.status {
                Text(status)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .tag(workspace.name)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectWorkspace(projectId: projectId, workspaceName: workspace.name)
        }
    }
}
