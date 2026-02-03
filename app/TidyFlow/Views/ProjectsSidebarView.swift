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
            // 标题栏
            HStack {
                Text("项目")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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

    /// 扁平化的列表行类型
    private enum SidebarRow: Identifiable {
        case project(Binding<ProjectModel>)
        case workspace(WorkspaceModel, projectId: UUID, projectName: String)

        var id: String {
            switch self {
            case .project(let binding):
                return "project-\(binding.wrappedValue.id)"
            case .workspace(let ws, let projectId, _):
                return "workspace-\(projectId)-\(ws.id)"
            }
        }
    }

    /// 将项目和工作空间扁平化为单一列表
    private var flattenedRows: [SidebarRow] {
        var rows: [SidebarRow] = []
        for index in appState.projects.indices {
            let projectBinding = $appState.projects[index]
            let project = projectBinding.wrappedValue
            rows.append(.project(projectBinding))
            if project.isExpanded {
                for workspace in project.workspaces {
                    rows.append(.workspace(workspace, projectId: project.id, projectName: project.name))
                }
            }
        }
        return rows
    }

    /// 使用 ScrollView + LazyVStack 实现无间距列表，与资源管理器面板保持一致
    private var projectListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(flattenedRows) { row in
                    switch row {
                    case .project(let binding):
                        ProjectRowView(project: binding)
                            .environmentObject(appState)
                    case .workspace(let workspace, let projectId, let projectName):
                        WorkspaceRowView(
                            workspace: workspace,
                            projectId: projectId,
                            projectName: projectName,
                            isSelected: appState.selectedProjectId == projectId && appState.selectedWorkspaceKey == workspace.name
                        )
                        .environmentObject(appState)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Project Row (Collapsible)

struct ProjectRowView: View {
    @Binding var project: ProjectModel
    @EnvironmentObject var appState: AppState
    @State private var showDeleteConfirmation = false

    /// 项目路径（项目根目录），用于复制与在编辑器中打开
    private var projectPath: String? { project.path }

    /// 菜单项图标尺寸
    private let menuIconSize: CGFloat = 16

    private func editorMenuIcon(_ editor: ExternalEditor) -> some View {
        FixedSizeAssetImage(name: editor.assetName, targetSize: menuIconSize)
    }

    var body: some View {
        TreeRowView(
            isExpandable: true,
            isExpanded: project.isExpanded,
            iconName: project.isExpanded ? "folder.fill" : "folder",
            iconColor: .accentColor,
            title: project.name,
            depth: 0,
            isSelected: false,
            onTap: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    project.isExpanded.toggle()
                }
            }
        )
        // 项目右键菜单：复制路径、在编辑器中打开(VSCode/Cursor)、新建工作空间、移除项目
        .contextMenu {
            if let path = projectPath {
                Button {
                    copyPathToPasteboard(path)
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
                Menu {
                    ForEach(ExternalEditor.allCases, id: \.self) { editor in
                        Button {
                            _ = appState.openPathInEditor(path, editor: editor)
                        } label: {
                            Label {
                                Text(editor.rawValue)
                            } icon: {
                                editorMenuIcon(editor)
                            }
                        }
                        .disabled(!editor.isInstalled)
                    }
                } label: {
                    Label("在编辑器中打开", systemImage: "square.and.arrow.up")
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

    /// 菜单项图标尺寸
    private let menuIconSize: CGFloat = 16

    private func editorMenuIcon(_ editor: ExternalEditor) -> some View {
        FixedSizeAssetImage(name: editor.assetName, targetSize: menuIconSize)
    }

    var body: some View {
        TreeRowView(
            isExpandable: false,
            isExpanded: false,
            iconName: "square.grid.2x2",
            iconColor: .secondary,
            title: workspace.name,
            depth: 1,
            isSelected: isSelected,
            onTap: {
                appState.selectWorkspace(projectId: projectId, workspaceName: workspace.name)
            }
        )
        .tag(workspace.name)
        // 工作空间右键菜单：复制路径、在编辑器中打开(VSCode/Cursor)、删除（默认工作空间不可删除）
        .contextMenu {
            if let path = workspacePath {
                Button {
                    copyPathToPasteboard(path)
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
                Menu {
                    ForEach(ExternalEditor.allCases, id: \.self) { editor in
                        Button {
                            _ = appState.openPathInEditor(path, editor: editor)
                        } label: {
                            Label {
                                Text(editor.rawValue)
                            } icon: {
                                editorMenuIcon(editor)
                            }
                        }
                        .disabled(!editor.isInstalled)
                    }
                } label: {
                    Label("在编辑器中打开", systemImage: "square.and.arrow.up")
                }
            }
            // 只有非默认工作空间才显示删除选项
            if !workspace.isDefault {
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
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
