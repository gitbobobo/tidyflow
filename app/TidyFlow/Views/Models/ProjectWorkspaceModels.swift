import Foundation

// MARK: - UX-1: Project/Workspace Models

/// 工作空间在侧边栏中的活动状态快照（由 Rust Core 计算）
struct WorkspaceSidebarStatusModel: Equatable {
    var taskIconName: String?
    var hasStreamingChat: Bool
    var hasActiveEvolutionLoop: Bool

    static let empty = WorkspaceSidebarStatusModel(
        taskIconName: nil,
        hasStreamingChat: false,
        hasActiveEvolutionLoop: false
    )
}

/// Represents a workspace within a project
struct WorkspaceModel: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var root: String?  // 工作空间路径
    var status: String?
    var isDefault: Bool = false  // 是否为默认工作空间（虚拟，指向项目根目录）
    var sidebarStatus: WorkspaceSidebarStatusModel = .empty
}

extension WorkspaceModel: WorkspaceSortable {
    var isDefaultWorkspace: Bool { isDefault }
    var workspaceSortName: String { name }
}

/// Represents a project containing multiple workspaces
struct ProjectModel: Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String?
    var workspaces: [WorkspaceModel]
    var isExpanded: Bool = true
    var commands: [ProjectCommand] = []
}

extension ProjectModel: ProjectIdentifiable {
    var projectUUID: UUID { id }
    var projectDisplayName: String { name }
}


