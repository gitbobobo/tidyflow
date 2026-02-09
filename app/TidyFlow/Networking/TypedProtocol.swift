import Foundation
import MessagePacker

// MARK: - 类型化协议基础设施
// 替代手动字典构建，提供编译期类型安全

/// 请求包络 — 支持可选 request_id 关联响应
struct WSRequestEnvelope<Body: Encodable>: Encodable {
    /// 客户端 request ID（可选），服务端在响应中回显
    let id: String?
    /// 消息体
    let body: Body

    /// 不带 id 的便捷构造
    init(_ body: Body) {
        self.id = nil
        self.body = body
    }

    /// 带 id 的构造
    init(id: String, _ body: Body) {
        self.id = id
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let id = id {
            try container.encode(id, forKey: .id)
        }
        // flatten body
        try body.encode(to: encoder)
    }
}

// MARK: - 消息路由协议

/// 领域消息处理协议 — 替代 30+ 回调闭包
protocol GitMessageHandler: AnyObject {
    func handleGitDiffResult(_ result: GitDiffResult)
    func handleGitStatusResult(_ result: GitStatusResult)
    func handleGitLogResult(_ result: GitLogResult)
    func handleGitShowResult(_ result: GitShowResult)
    func handleGitOpResult(_ result: GitOpResult)
    func handleGitBranchesResult(_ result: GitBranchesResult)
    func handleGitCommitResult(_ result: GitCommitResult)
    func handleGitRebaseResult(_ result: GitRebaseResult)
    func handleGitOpStatusResult(_ result: GitOpStatusResult)
    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult)
    func handleGitIntegrationStatusResult(_ result: GitIntegrationStatusResult)
    func handleGitRebaseOntoDefaultResult(_ result: GitRebaseOntoDefaultResult)
    func handleGitResetIntegrationWorktreeResult(_ result: GitResetIntegrationWorktreeResult)
    func handleGitStatusChanged(_ notification: GitStatusChangedNotification)
    func handleGitAICommitResult(_ result: GitAICommitResult)
}

/// 默认空实现，子类只需 override 关心的方法
extension GitMessageHandler {
    func handleGitDiffResult(_ result: GitDiffResult) {}
    func handleGitStatusResult(_ result: GitStatusResult) {}
    func handleGitLogResult(_ result: GitLogResult) {}
    func handleGitShowResult(_ result: GitShowResult) {}
    func handleGitOpResult(_ result: GitOpResult) {}
    func handleGitBranchesResult(_ result: GitBranchesResult) {}
    func handleGitCommitResult(_ result: GitCommitResult) {}
    func handleGitRebaseResult(_ result: GitRebaseResult) {}
    func handleGitOpStatusResult(_ result: GitOpStatusResult) {}
    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult) {}
    func handleGitIntegrationStatusResult(_ result: GitIntegrationStatusResult) {}
    func handleGitRebaseOntoDefaultResult(_ result: GitRebaseOntoDefaultResult) {}
    func handleGitResetIntegrationWorktreeResult(_ result: GitResetIntegrationWorktreeResult) {}
    func handleGitStatusChanged(_ notification: GitStatusChangedNotification) {}
    func handleGitAICommitResult(_ result: GitAICommitResult) {}
}

protocol ProjectMessageHandler: AnyObject {
    func handleProjectsList(_ result: ProjectsListResult)
    func handleWorkspacesList(_ result: WorkspacesListResult)
    func handleProjectImported(_ result: ProjectImportedResult)
    func handleWorkspaceCreated(_ result: WorkspaceCreatedResult)
    func handleProjectRemoved(_ result: ProjectRemovedResult)
    func handleWorkspaceRemoved(_ result: WorkspaceRemovedResult)
    func handleProjectCommandsSaved(_ project: String, _ ok: Bool, _ message: String?)
    func handleProjectCommandStarted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String)
    func handleProjectCommandCompleted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String, _ ok: Bool, _ message: String?)
    func handleProjectCommandOutput(_ taskId: String, _ line: String)
}

extension ProjectMessageHandler {
    func handleProjectsList(_ result: ProjectsListResult) {}
    func handleWorkspacesList(_ result: WorkspacesListResult) {}
    func handleProjectImported(_ result: ProjectImportedResult) {}
    func handleWorkspaceCreated(_ result: WorkspaceCreatedResult) {}
    func handleProjectRemoved(_ result: ProjectRemovedResult) {}
    func handleWorkspaceRemoved(_ result: WorkspaceRemovedResult) {}
    func handleProjectCommandsSaved(_ project: String, _ ok: Bool, _ message: String?) {}
    func handleProjectCommandStarted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String) {}
    func handleProjectCommandCompleted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String, _ ok: Bool, _ message: String?) {}
    func handleProjectCommandOutput(_ taskId: String, _ line: String) {}
}

protocol FileMessageHandler: AnyObject {
    func handleFileIndexResult(_ result: FileIndexResult)
    func handleFileListResult(_ result: FileListResult)
    func handleFileRenameResult(_ result: FileRenameResult)
    func handleFileDeleteResult(_ result: FileDeleteResult)
    func handleFileCopyResult(_ result: FileCopyResult)
    func handleFileMoveResult(_ result: FileMoveResult)
    func handleFileWriteResult(_ result: FileWriteResult)
    func handleFileChanged(_ notification: FileChangedNotification)
    func handleWatchSubscribed(_ result: WatchSubscribedResult)
    func handleWatchUnsubscribed()
}

extension FileMessageHandler {
    func handleFileIndexResult(_ result: FileIndexResult) {}
    func handleFileListResult(_ result: FileListResult) {}
    func handleFileRenameResult(_ result: FileRenameResult) {}
    func handleFileDeleteResult(_ result: FileDeleteResult) {}
    func handleFileCopyResult(_ result: FileCopyResult) {}
    func handleFileMoveResult(_ result: FileMoveResult) {}
    func handleFileWriteResult(_ result: FileWriteResult) {}
    func handleFileChanged(_ notification: FileChangedNotification) {}
    func handleWatchSubscribed(_ result: WatchSubscribedResult) {}
    func handleWatchUnsubscribed() {}
}

protocol SettingsMessageHandler: AnyObject {
    func handleClientSettingsResult(_ settings: ClientSettings)
    func handleClientSettingsSaved(_ ok: Bool, _ message: String?)
}

extension SettingsMessageHandler {
    func handleClientSettingsResult(_ settings: ClientSettings) {}
    func handleClientSettingsSaved(_ ok: Bool, _ message: String?) {}
}

// MARK: - 类型安全的请求构建器

/// Git 领域请求
enum GitRequest {
    /// 构建 git_status 请求
    static func status(project: String, workspace: String) -> [String: Any] {
        ["type": "git_status", "project": project, "workspace": workspace]
    }

    /// 构建 git_diff 请求
    static func diff(project: String, workspace: String, path: String, mode: String) -> [String: Any] {
        ["type": "git_diff", "project": project, "workspace": workspace, "path": path, "mode": mode]
    }

    /// 构建 git_stage 请求
    static func stage(project: String, workspace: String, path: String?, scope: String) -> [String: Any] {
        var msg: [String: Any] = ["type": "git_stage", "project": project, "workspace": workspace, "scope": scope]
        if let path = path { msg["path"] = path }
        return msg
    }

    /// 构建 git_unstage 请求
    static func unstage(project: String, workspace: String, path: String?, scope: String) -> [String: Any] {
        var msg: [String: Any] = ["type": "git_unstage", "project": project, "workspace": workspace, "scope": scope]
        if let path = path { msg["path"] = path }
        return msg
    }

    /// 构建 git_discard 请求
    static func discard(project: String, workspace: String, path: String?, scope: String, includeUntracked: Bool = false) -> [String: Any] {
        var msg: [String: Any] = ["type": "git_discard", "project": project, "workspace": workspace, "scope": scope]
        if let path = path { msg["path"] = path }
        if includeUntracked { msg["include_untracked"] = true }
        return msg
    }

    /// 构建 git_commit 请求
    static func commit(project: String, workspace: String, message: String) -> [String: Any] {
        ["type": "git_commit", "project": project, "workspace": workspace, "message": message]
    }

    /// 构建 git_branches 请求
    static func branches(project: String, workspace: String) -> [String: Any] {
        ["type": "git_branches", "project": project, "workspace": workspace]
    }

    /// 构建 git_switch_branch 请求
    static func switchBranch(project: String, workspace: String, branch: String) -> [String: Any] {
        ["type": "git_switch_branch", "project": project, "workspace": workspace, "branch": branch]
    }

    /// 构建 git_create_branch 请求
    static func createBranch(project: String, workspace: String, branch: String) -> [String: Any] {
        ["type": "git_create_branch", "project": project, "workspace": workspace, "branch": branch]
    }
}

/// 项目领域请求
enum ProjectRequest {
    static func listProjects() -> [String: Any] {
        ["type": "list_projects"]
    }

    static func listWorkspaces(project: String) -> [String: Any] {
        ["type": "list_workspaces", "project": project]
    }

    static func importProject(name: String, path: String) -> [String: Any] {
        ["type": "import_project", "name": name, "path": path]
    }
}
