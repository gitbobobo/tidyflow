import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

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

    /// 项目与工作空间拆成 List 的独立行，避免嵌套时右键菜单被项目行抢走（点哪里都是项目菜单）
    private var projectListView: some View {
        List {
            ForEach($appState.projects) { $project in
                ProjectRowView(project: $project)
                    .environmentObject(appState)
                if project.isExpanded {
                    ForEach(project.workspaces) { workspace in
                        WorkspaceRowView(
                            workspace: workspace,
                            projectId: project.id,
                            projectName: project.name,
                            isSelected: appState.selectedWorkspaceKey == workspace.name
                        )
                        .environmentObject(appState)
                        .padding(.leading, 18)
                    }
                }
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

    /// 项目路径（项目根目录），用于复制与在编辑器中打开
    private var projectPath: String? { project.path }

    var body: some View {
        // 仅项目头行；工作空间行由 List 中单独渲染，保证各自右键菜单独立
        HStack(spacing: 6) {
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
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                project.isExpanded.toggle()
            }
        }
        // 项目右键菜单：复制路径、在编辑器中打开(VSCode/Cursor)、新建工作空间、移除项目
        .contextMenu {
            if let path = projectPath {
                Button {
                    copyPathToPasteboard(path)
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
                Menu("在编辑器中打开") {
                    ForEach(ExternalEditor.allCases, id: \.self) { editor in
                        Button(editor.rawValue) {
                            _ = appState.openPathInEditor(path, editor: editor)
                        }
                        .disabled(!editor.isInstalled)
                    }
                }
            }
            Button {
                appState.createWorkspace(projectName: project.name)
            } label: {
                Label("新建工作空间", systemImage: "plus.square.on.square")
            }
            Divider()
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
    }
}

#if canImport(AppKit)
private func copyPathToPasteboard(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
}
#else
private func copyPathToPasteboard(_ path: String) {}
#endif

// MARK: - Workspace Row

struct WorkspaceRowView: View {
    let workspace: WorkspaceModel
    let projectId: UUID
    let projectName: String
    let isSelected: Bool
    @EnvironmentObject var appState: AppState
    @State private var showDeleteConfirmation = false

    /// 工作空间路径，用于复制与在编辑器中打开
    private var workspacePath: String? { workspace.root }

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
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .tag(workspace.name)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectWorkspace(projectId: projectId, workspaceName: workspace.name)
        }
        // 工作空间右键菜单：复制路径、在编辑器中打开(VSCode/Cursor)、删除（与项目菜单不同，无「新建工作空间/移除项目」）
        .contextMenu {
            if let path = workspacePath {
                Button {
                    copyPathToPasteboard(path)
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
                Menu("在编辑器中打开") {
                    ForEach(ExternalEditor.allCases, id: \.self) { editor in
                        Button(editor.rawValue) {
                            _ = appState.openPathInEditor(path, editor: editor)
                        }
                        .disabled(!editor.isInstalled)
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .alert("删除工作空间", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                appState.removeWorkspace(projectName: projectName, workspaceName: workspace.name)
            }
        } message: {
            Text("确定要删除工作空间 \"\(workspace.name)\" 吗？\n将移除该 worktree，分支与未提交更改请先自行处理。")
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}
