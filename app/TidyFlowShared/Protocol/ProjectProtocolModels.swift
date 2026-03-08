import Foundation

// MARK: - 项目级命令模型

/// 项目级命令配置（作为后台任务执行，不新建终端 tab）
public struct ProjectCommand: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var icon: String
    public var command: String
    public var blocking: Bool
    public var interactive: Bool

    public init(id: String = UUID().uuidString, name: String = "", icon: String = "terminal", command: String = "", blocking: Bool = false, interactive: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.command = command
        self.blocking = blocking
        self.interactive = interactive
    }
}


// MARK: - UX-2: Project Import Protocol Models

/// Workspace info returned from import/create operations
public struct WorkspaceSidebarStatusInfo {
    public let taskIcon: String?
    public let chatActive: Bool
    public let evolutionActive: Bool

    public static let empty = WorkspaceSidebarStatusInfo(
        taskIcon: nil,
        chatActive: false,
        evolutionActive: false
    )

    public static func from(json: [String: Any]?) -> WorkspaceSidebarStatusInfo {
        guard let json else { return .empty }
        return WorkspaceSidebarStatusInfo(
            taskIcon: json["task_icon"] as? String,
            chatActive: json["chat_active"] as? Bool ?? false,
            evolutionActive: json["evolution_active"] as? Bool ?? false
        )
    }
}

/// Workspace info returned from import/create operations
public struct WorkspaceImportInfo {
    public let name: String
    public let root: String
    public let branch: String
    public let status: String
    public let sidebarStatus: WorkspaceSidebarStatusInfo

    public static func from(json: [String: Any]) -> WorkspaceImportInfo? {
        guard let name = json["name"] as? String,
              let root = json["root"] as? String,
              let branch = json["branch"] as? String,
              let status = json["status"] as? String else {
            return nil
        }
        return WorkspaceImportInfo(
            name: name,
            root: root,
            branch: branch,
            status: status,
            sidebarStatus: WorkspaceSidebarStatusInfo.from(json: json["sidebar_status"] as? [String: Any])
        )
    }
}

/// Result from import_project request
public struct ProjectImportedResult {
    public let name: String
    public let root: String
    public let defaultBranch: String
    public let workspace: WorkspaceImportInfo?

    public static func from(json: [String: Any]) -> ProjectImportedResult? {
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
public struct WorkspaceCreatedResult {
    public let project: String
    public let workspace: WorkspaceImportInfo

    public static func from(json: [String: Any]) -> WorkspaceCreatedResult? {
        guard let project = json["project"] as? String,
              let wsJson = json["workspace"] as? [String: Any],
              let workspace = WorkspaceImportInfo.from(json: wsJson) else {
            return nil
        }
        return WorkspaceCreatedResult(project: project, workspace: workspace)
    }
}

/// Project info returned from list_projects
public struct ProjectInfo {
    public let name: String
    public let root: String
    public let workspaceCount: Int
    public let commands: [ProjectCommand]

    public static func from(json: [String: Any]) -> ProjectInfo? {
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
public struct ProjectsListResult {
    public let items: [ProjectInfo]

    public static func from(json: [String: Any]) -> ProjectsListResult? {
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
public struct WorkspaceInfo {
    public let name: String
    public let root: String
    public let branch: String
    public let status: String
    public let sidebarStatus: WorkspaceSidebarStatusInfo

    public static func from(json: [String: Any]) -> WorkspaceInfo? {
        guard let name = json["name"] as? String,
              let root = json["root"] as? String,
              let branch = json["branch"] as? String,
              let status = json["status"] as? String else {
            return nil
        }
        return WorkspaceInfo(
            name: name,
            root: root,
            branch: branch,
            status: status,
            sidebarStatus: WorkspaceSidebarStatusInfo.from(json: json["sidebar_status"] as? [String: Any])
        )
    }
}

/// Result from list_workspaces request (server sends "workspaces" message)
public struct WorkspacesListResult {
    public let project: String
    public let items: [WorkspaceInfo]

    public static func from(json: [String: Any]) -> WorkspacesListResult? {
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
public struct ProjectRemovedResult {
    public let name: String
    public let ok: Bool
    public let message: String?

    public static func from(json: [String: Any]) -> ProjectRemovedResult? {
        guard let name = json["name"] as? String,
              let ok = json["ok"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        return ProjectRemovedResult(name: name, ok: ok, message: message)
    }
}

/// Result from remove_workspace request
public struct WorkspaceRemovedResult {
    public let project: String
    public let workspace: String
    public let ok: Bool
    public let message: String?

    public static func from(json: [String: Any]) -> WorkspaceRemovedResult? {
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
public struct FileIndexResult {
    public let project: String
    public let workspace: String
    public let items: [String]
    public let truncated: Bool

    public static func from(json: [String: Any]) -> FileIndexResult? {
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
public struct FileIndexCache {
    public var items: [String]
    public var truncated: Bool
    public var updatedAt: Date
    public var isLoading: Bool
    public var error: String?

    public static func empty() -> FileIndexCache {
        FileIndexCache(items: [], truncated: false, updatedAt: .distantPast, isLoading: false, error: nil)
    }

    public var isExpired: Bool {
        // Cache expires after 10 minutes
        Date().timeIntervalSince(updatedAt) > 600
    }
}

// MARK: - 工作流模板协议模型

/// 工作流模板命令
public struct TemplateCommandInfo: Identifiable {
    public let id: String
    public let name: String
    public let icon: String
    public let command: String
    public let blocking: Bool
    public let interactive: Bool

    public static func from(json: [String: Any]) -> TemplateCommandInfo? {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let icon = json["icon"] as? String,
              let command = json["command"] as? String else {
            return nil
        }
        return TemplateCommandInfo(
            id: id,
            name: name,
            icon: icon,
            command: command,
            blocking: json["blocking"] as? Bool ?? false,
            interactive: json["interactive"] as? Bool ?? false
        )
    }

    public func toDict() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "icon": icon,
            "command": command,
            "blocking": blocking,
            "interactive": interactive
        ]
    }
}

/// 工作流模板
public struct TemplateInfo: Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let tags: [String]
    public let commands: [TemplateCommandInfo]
    /// 环境变量，格式为 [[key, value], ...]（对应 Rust Vec<(String,String)>）
    public let envVars: [[String]]
    public let builtin: Bool

    public static func from(json: [String: Any]) -> TemplateInfo? {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else {
            return nil
        }
        let description = json["description"] as? String ?? ""
        let tags = json["tags"] as? [String] ?? []
        let commandsJson = json["commands"] as? [[String: Any]] ?? []
        let commands = commandsJson.compactMap { TemplateCommandInfo.from(json: $0) }
        let envVars = json["env_vars"] as? [[String]] ?? []
        let builtin = json["builtin"] as? Bool ?? false
        return TemplateInfo(
            id: id,
            name: name,
            description: description,
            tags: tags,
            commands: commands,
            envVars: envVars,
            builtin: builtin
        )
    }

    public func toDict() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "description": description,
            "tags": tags,
            "commands": commands.map { $0.toDict() },
            "env_vars": envVars,
            "builtin": builtin
        ]
    }
}

/// 模板列表结果
public struct TemplatesListResult {
    public let items: [TemplateInfo]

    public static func from(json: [String: Any]) -> TemplatesListResult? {
        guard let itemsArray = json["items"] as? [[String: Any]] else {
            return nil
        }
        let items = itemsArray.compactMap { TemplateInfo.from(json: $0) }
        return TemplatesListResult(items: items)
    }
}

/// 模板保存结果
public struct TemplateSavedResult {
    public let template: TemplateInfo
    public let ok: Bool
    public let message: String?

    public static func from(json: [String: Any]) -> TemplateSavedResult? {
        guard let templateJson = json["template"] as? [String: Any],
              let template = TemplateInfo.from(json: templateJson),
              let ok = json["ok"] as? Bool else {
            return nil
        }
        return TemplateSavedResult(template: template, ok: ok, message: json["message"] as? String)
    }
}

/// 模板删除结果
public struct TemplateDeletedResult {
    public let templateId: String
    public let ok: Bool
    public let message: String?

    public static func from(json: [String: Any]) -> TemplateDeletedResult? {
        guard let templateId = json["template_id"] as? String,
              let ok = json["ok"] as? Bool else {
            return nil
        }
        return TemplateDeletedResult(templateId: templateId, ok: ok, message: json["message"] as? String)
    }
}

/// 模板导入结果
public struct TemplateImportedResult {
    public let template: TemplateInfo
    public let ok: Bool
    public let message: String?

    public static func from(json: [String: Any]) -> TemplateImportedResult? {
        guard let templateJson = json["template"] as? [String: Any],
              let template = TemplateInfo.from(json: templateJson),
              let ok = json["ok"] as? Bool else {
            return nil
        }
        return TemplateImportedResult(template: template, ok: ok, message: json["message"] as? String)
    }
}

/// 模板导出结果
public struct TemplateExportedResult {
    public let template: TemplateInfo

    public static func from(json: [String: Any]) -> TemplateExportedResult? {
        guard let templateJson = json["template"] as? [String: Any],
              let template = TemplateInfo.from(json: templateJson) else {
            return nil
        }
        return TemplateExportedResult(template: template)
    }
}
