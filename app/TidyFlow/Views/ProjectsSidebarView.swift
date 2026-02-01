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

    var body: some View {
        DisclosureGroup(
            isExpanded: $project.isExpanded,
            content: {
                ForEach(project.workspaces) { workspace in
                    WorkspaceRowView(
                        workspace: workspace,
                        projectId: project.id,
                        isSelected: appState.selectedWorkspaceKey == workspace.name
                    )
                    .environmentObject(appState)
                }
            },
            label: {
                HStack(spacing: 6) {
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
            }
        )
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
