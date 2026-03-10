import Foundation

// MARK: - 共享传输协议抽象

/// 服务端包络元数据（v8 协议）
public struct ServerEnvelopeMeta {
    public let seq: UInt64
    public let domain: String
    public let action: String
    public let kind: String
    public let requestID: String?
    public let serverTS: UInt64?

    public init(seq: UInt64, domain: String, action: String, kind: String, requestID: String?, serverTS: UInt64?) {
        self.seq = seq
        self.domain = domain
        self.action = action
        self.kind = kind
        self.requestID = requestID
        self.serverTS = serverTS
    }
}

/// WebSocket 连接状态
public enum CoreConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, maxAttempts: Int)
    case reconnectFailed
    case intentionallyDisconnected
}

// MARK: - 多工作区 HTTP 读取失败上下文（共享）
//
// HTTP 读取失败时，客户端通过此上下文确定失败归属的 (project, workspace, aiTool)，
// 避免来自其他工作区的失败影响当前激活工作区的 UI 状态。
//
// macOS (`WSClient.HTTPReadRequestContext`) 和 iOS 应使用相同的归属判断逻辑：
// 仅当 `(project, workspace, aiTool)` 与当前激活工作区匹配时才更新 UI 状态。

/// HTTP 读取请求的多工作区上下文。
/// 用于回调时判断失败归属，保证多工作区并行时不互相污染状态。
public struct HTTPReadRequestContext: Equatable {
    /// 请求所属 domain（如 "ai"、"evidence"、"evolution"）
    public let domain: String
    /// 请求所属项目
    public let project: String
    /// 请求所属工作区
    public let workspace: String
    /// 附加标识（如 aiTool.rawValue，可为空字符串）
    public let qualifier: String

    public init(domain: String, project: String, workspace: String, qualifier: String = "") {
        self.domain = domain
        self.project = project
        self.workspace = workspace
        self.qualifier = qualifier
    }

    /// 判断上下文是否归属于指定的 (project, workspace)。
    /// 用于快速过滤跨工作区的回调，不影响当前激活工作区状态。
    public func belongs(to targetProject: String, workspace targetWorkspace: String) -> Bool {
        project == targetProject && workspace == targetWorkspace
    }
}

/// 领域消息处理协议 — 跨平台共享接口
public protocol CoreMessageDispatcher: AnyObject {
    var onConnectionStateChanged: ((Bool) -> Void)? { get set }
    var onServerEnvelopeMeta: ((ServerEnvelopeMeta) -> Void)? { get set }
    var isConnected: Bool { get }
}
