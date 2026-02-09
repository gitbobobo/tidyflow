import Foundation

// MARK: - UX-2: Project Import Protocol Models

/// Workspace info returned from import/create operations
struct WorkspaceImportInfo {
    let name: String
    let root: String
    let branch: String
    let status: String

    static func from(json: [String: Any]) -> WorkspaceImportInfo? {
        guard let name = json["name"] as? String,
              let root = json["root"] as? String,
              let branch = json["branch"] as? String,
              let status = json["status"] as? String else {
            return nil
        }
        return WorkspaceImportInfo(name: name, root: root, branch: branch, status: status)
    }
}

/// Result from import_project request
struct ProjectImportedResult {
    let name: String
    let root: String
    let defaultBranch: String
    let workspace: WorkspaceImportInfo?

    static func from(json: [String: Any]) -> ProjectImportedResult? {
        guard let name = json["name"] as? String,
              let root = json["root"] as? String,
              let defaultBranch = json["default_branch"] as? String else {
            return nil
        }
        var workspace: WorkspaceImportInfo? = nil
        if let wsJson = json["workspace"] as? [String: Any] {
            workspace = WorkspaceImportInfo.from(json: wsJson)
        }
        return ProjectImportedResult(
            name: name,
            root: root,
            defaultBranch: defaultBranch,
            workspace: workspace
        )
    }
}

/// Result from create_workspace request
struct WorkspaceCreatedResult {
    let project: String
    let workspace: WorkspaceImportInfo

    static func from(json: [String: Any]) -> WorkspaceCreatedResult? {
        guard let project = json["project"] as? String,
              let wsJson = json["workspace"] as? [String: Any],
              let workspace = WorkspaceImportInfo.from(json: wsJson) else {
            return nil
        }
        return WorkspaceCreatedResult(project: project, workspace: workspace)
    }
}

/// Project info returned from list_projects
struct ProjectInfo {
    let name: String
    let root: String
    let workspaceCount: Int
    let commands: [ProjectCommand]

    static func from(json: [String: Any]) -> ProjectInfo? {
        guard let name = json["name"] as? String,
              let root = json["root"] as? String else {
            return nil
        }
        let workspaceCount = json["workspace_count"] as? Int ?? 0
        var commands: [ProjectCommand] = []
        if let cmdsJson = json["commands"] as? [[String: Any]] {
            commands = cmdsJson.compactMap { cmdJson -> ProjectCommand? in
                guard let id = cmdJson["id"] as? String,
                      let cmdName = cmdJson["name"] as? String,
                      let icon = cmdJson["icon"] as? String,
                      let command = cmdJson["command"] as? String else {
                    return nil
                }
                let blocking = cmdJson["blocking"] as? Bool ?? false
                let interactive = cmdJson["interactive"] as? Bool ?? false
                return ProjectCommand(id: id, name: cmdName, icon: icon, command: command, blocking: blocking, interactive: interactive)
            }
        }
        return ProjectInfo(name: name, root: root, workspaceCount: workspaceCount, commands: commands)
    }
}

/// Result from list_projects request (server sends "projects" message)
struct ProjectsListResult {
    let items: [ProjectInfo]

    static func from(json: [String: Any]) -> ProjectsListResult? {
        guard let itemsArray = json["items"] as? [[String: Any]] else {
            return nil
        }
        
        var items: [ProjectInfo] = []
        for itemJson in itemsArray {
            if let info = ProjectInfo.from(json: itemJson) {
                items.append(info)
            }
        }
        
        return ProjectsListResult(items: items)
    }
}

/// Workspace info returned from list_workspaces
struct WorkspaceInfo {
    let name: String
    let root: String
    let branch: String
    let status: String

    static func from(json: [String: Any]) -> WorkspaceInfo? {
        guard let name = json["name"] as? String,
              let root = json["root"] as? String,
              let branch = json["branch"] as? String,
              let status = json["status"] as? String else {
            return nil
        }
        return WorkspaceInfo(name: name, root: root, branch: branch, status: status)
    }
}

/// Result from list_workspaces request (server sends "workspaces" message)
struct WorkspacesListResult {
    let project: String
    let items: [WorkspaceInfo]

    static func from(json: [String: Any]) -> WorkspacesListResult? {
        guard let project = json["project"] as? String,
              let itemsArray = json["items"] as? [[String: Any]] else {
            return nil
        }
        
        var items: [WorkspaceInfo] = []
        for itemJson in itemsArray {
            if let info = WorkspaceInfo.from(json: itemJson) {
                items.append(info)
            }
        }
        
        return WorkspacesListResult(project: project, items: items)
    }
}

/// Result from remove_project request
struct ProjectRemovedResult {
    let name: String
    let ok: Bool
    let message: String?

    static func from(json: [String: Any]) -> ProjectRemovedResult? {
        guard let name = json["name"] as? String,
              let ok = json["ok"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        return ProjectRemovedResult(name: name, ok: ok, message: message)
    }
}

/// Result from remove_workspace request
struct WorkspaceRemovedResult {
    let project: String
    let workspace: String
    let ok: Bool
    let message: String?

    static func from(json: [String: Any]) -> WorkspaceRemovedResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let ok = json["ok"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        return WorkspaceRemovedResult(project: project, workspace: workspace, ok: ok, message: message)
    }
}

/// Result from file_index request
struct FileIndexResult {
    let project: String
    let workspace: String
    let items: [String]
    let truncated: Bool

    static func from(json: [String: Any]) -> FileIndexResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let items = json["items"] as? [String] else {
            return nil
        }
        let truncated = json["truncated"] as? Bool ?? false
        return FileIndexResult(project: project, workspace: workspace, items: items, truncated: truncated)
    }
}

/// Cached file index for a workspace
struct FileIndexCache {
    var items: [String]
    var truncated: Bool
    var updatedAt: Date
    var isLoading: Bool
    var error: String?

    static func empty() -> FileIndexCache {
        FileIndexCache(items: [], truncated: false, updatedAt: .distantPast, isLoading: false, error: nil)
    }

    var isExpired: Bool {
        // Cache expires after 10 minutes
        Date().timeIntervalSince(updatedAt) > 600
    }
}

