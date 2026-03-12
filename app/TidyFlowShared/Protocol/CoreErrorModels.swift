import Foundation

// MARK: - 共享错误码

/// TidyFlow 跨端共享错误码
///
/// 与 Rust Core 的 `AppError::code()` 保持一致，客户端通过此枚举
/// 决定状态迁移与恢复提示，不依赖自由文本字符串匹配。
///
/// 错误码分层：
/// - 基础层（`project_*`、`workspace_*`）：项目/工作区解析失败
/// - 传输层（`ws_*`、`http_*`）：客户端本地连接错误（非 Core 返回）
/// - 业务层（`ai_*`、`evolution_*`、`git_*`、`file_*`）：领域错误
/// - 通用层（`internal_error`、`error`）：兜底
public enum CoreErrorCode: String, Hashable {
    // MARK: 项目/工作区
    case projectNotFound = "project_not_found"
    case workspaceNotFound = "workspace_not_found"

    // MARK: Git
    case gitError = "git_error"
    case notGitRepo = "not_git_repo"

    // MARK: 文件
    case fileError = "file_error"
    case pathNotFound = "path_not_found"
    case invalidPath = "invalid_path"

    // MARK: 终端
    case termNotFound = "term_not_found"

    // MARK: AI 会话
    case aiSessionError = "ai_session_error"

    // MARK: Evolution
    case evolutionError = "evolution_error"
    case artifactContractViolation = "artifact_contract_violation"
    case managedBacklogSyncFailed = "managed_backlog_sync_failed"

    // MARK: 协议/传输
    case invalidPayload = "invalid_payload"
    case importError = "import_error"
    case workspaceError = "workspace_error"
    case authenticationFailed = "authentication_failed"
    case authenticationRevoked = "authentication_revoked"

    // MARK: 通用
    case internalError = "internal_error"
    case unknown = "error"

    // MARK: 客户端本地错误（不来自 Core，由 Swift 端生成）
    case wsReceiveError = "ws_receive_error"
    case wsEncodeError = "ws_encode_error"
    case wsDecodeError = "ws_decode_error"
    case wsNotConnected = "ws_not_connected"

    /// 从字符串解析，未知码 fallback 为 `.unknown`
    public static func parse(_ raw: String?) -> CoreErrorCode {
        guard let raw else { return .unknown }
        return CoreErrorCode(rawValue: raw) ?? .unknown
    }

    // MARK: 错误分类

    /// 是否为可恢复错误（可通过重试或选择其他工作区恢复）
    public var isRecoverable: Bool {
        switch self {
        case .projectNotFound, .workspaceNotFound,
             .wsNotConnected, .wsReceiveError,
             .wsEncodeError, .wsDecodeError:
            return true
        default:
            return false
        }
    }

    /// 是否为多工作区定位相关错误（需要显示 project/workspace 上下文）
    public var requiresWorkspaceContext: Bool {
        switch self {
        case .projectNotFound, .workspaceNotFound,
             .aiSessionError, .evolutionError,
             .artifactContractViolation, .managedBacklogSyncFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - 结构化核心错误

/// 从 Core 收到的结构化错误（含上下文定位字段）
public struct CoreError {
    public let code: CoreErrorCode
    public let message: String
    /// 错误归属的项目（多项目场景）
    public let project: String?
    /// 错误归属的工作区
    public let workspace: String?
    /// AI 会话 ID
    public let sessionId: String?
    /// Evolution Cycle ID
    public let cycleId: String?

    public init(
        code: CoreErrorCode,
        message: String,
        project: String? = nil,
        workspace: String? = nil,
        sessionId: String? = nil,
        cycleId: String? = nil
    ) {
        self.code = code
        self.message = message
        self.project = project
        self.workspace = workspace
        self.sessionId = sessionId
        self.cycleId = cycleId
    }

    /// 从 WebSocket 错误 payload（`kind = "error"` 或 `action = "error"`）解析
    public static func from(json: [String: Any]) -> CoreError {
        let code = CoreErrorCode.parse(json["code"] as? String)
        let message = (json["message"] as? String) ?? "Unknown error"
        return CoreError(
            code: code,
            message: message,
            project: json["project"] as? String,
            workspace: json["workspace"] as? String,
            sessionId: json["session_id"] as? String,
            cycleId: json["cycle_id"] as? String
        )
    }

    /// 从 evo_error payload 解析（Core 的 EvoError 结构）
    public static func fromEvoError(json: [String: Any]) -> CoreError {
        let code = CoreErrorCode.parse(json["code"] as? String ?? "evolution_error")
        let message = (json["message"] as? String) ?? "Evolution error"
        return CoreError(
            code: code,
            message: message,
            project: json["project"] as? String,
            workspace: json["workspace"] as? String,
            sessionId: nil,
            cycleId: json["cycle_id"] as? String
        )
    }

    /// 是否与当前选中工作区匹配（用于过滤跨工作区错误污染）
    public func belongsTo(project: String?, workspace: String?) -> Bool {
        if let errProject = self.project, let curProject = project {
            if errProject != curProject { return false }
        }
        if let errWorkspace = self.workspace, let curWorkspace = workspace {
            if errWorkspace != curWorkspace { return false }
        }
        return true
    }
}
