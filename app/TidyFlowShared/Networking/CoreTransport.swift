import Foundation

// MARK: - 共享传输协议抽象

/// 服务端包络元数据（v7 协议）
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

/// 领域消息处理协议 — 跨平台共享接口
public protocol CoreMessageDispatcher: AnyObject {
    var onConnectionStateChanged: ((Bool) -> Void)? { get set }
    var onServerEnvelopeMeta: ((ServerEnvelopeMeta) -> Void)? { get set }
    var isConnected: Bool { get }
}
