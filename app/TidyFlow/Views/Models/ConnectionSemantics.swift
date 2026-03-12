import Foundation

// MARK: - 共享连接语义层
//
// 单一入口表达所有连接状态转换，与 project/workspace 选择无关。
// macOS AppState 与 iOS MobileAppState 共同消费此模型，确保双端行为语义一致。

/// 连接阶段：覆盖从主动建连到主动断开的所有状态迁移路径。
enum ConnectionPhase: Equatable {
    /// 主动建连中（握手尚未完成）
    case connecting
    /// 已建立稳定连接
    case connected
    /// 意外断连，自动重连进行中
    case reconnecting(attempt: Int, maxAttempts: Int)
    /// 重连耗尽，待人工手动恢复
    case reconnectFailed
    /// 认证失败或 key 已失效，需重新输入有效凭据
    case authenticationFailed(reason: String)
    /// 主动断开（由用户或应用主动发起，不触发自动重连）
    case intentionallyDisconnected

    // MARK: - 派生属性

    /// 是否处于已连接状态
    var isConnected: Bool { self == .connected }

    /// 是否处于自动重连中
    var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }

    /// 是否需要人工干预才能恢复（重连耗尽或认证失败）
    var needsManualRecovery: Bool {
        switch self {
        case .reconnectFailed, .authenticationFailed:
            return true
        default:
            return false
        }
    }

    // MARK: - macOS 兼容导出

    #if os(macOS)
    /// 向 macOS 侧 `ConnectionState`（已连接/已断开二值）导出兼容结果。
    /// 新代码应直接读取 `connectionPhase`，此属性仅为过渡期向后兼容。
    /// 注：`ConnectionState` 定义在 TabModels.swift（macOS 专属），因此此属性仅对 macOS 可用。
    var legacyConnectionState: ConnectionState {
        switch self {
        case .connected:
            return .connected
        default:
            return .disconnected
        }
    }
    #endif
}

// MARK: - 状态迁移辅助
//
// 以下方法集中连接阶段迁移的决策逻辑，macOS 与 iOS 共用，
// 避免各平台在回调或探活中独立推导"是否应该重连"或"断连后应进入哪个阶段"。

extension ConnectionPhase {
    /// 是否允许发起自动重连。
    /// 排除已在重连、主动断开、认证失败、重连耗尽的场景，
    /// 防止自动重连误伤非意外断连状态。
    var allowsAutoReconnect: Bool {
        switch self {
        case .reconnecting, .intentionallyDisconnected, .authenticationFailed, .reconnectFailed:
            return false
        case .connecting, .connected:
            return true
        }
    }

    /// 评估断连后应进入的连接阶段（集中决策，双端共用）。
    /// - Parameters:
    ///   - isIntentional: 断开是否由用户或应用主动发起
    ///   - isCoreAvailable: 后端进程是否仍可用（macOS 为 Core 进程状态，iOS 固定传 true）
    /// - Returns: 应设置的确定阶段；返回 nil 表示意外断连，调用方应触发自动重连流程。
    static func evaluateDisconnect(isIntentional: Bool, isCoreAvailable: Bool) -> ConnectionPhase? {
        if isIntentional || !isCoreAvailable {
            return .intentionallyDisconnected
        }
        return nil
    }

    /// 根据当前已完成的尝试次数计算下一个重连阶段。
    /// - Parameter currentAttempt: 已完成的尝试次数（0 起始）
    /// - Returns: `.reconnecting(...)` 或 `.reconnectFailed`
    static func nextReconnectPhase(currentAttempt: Int) -> ConnectionPhase {
        let next = currentAttempt + 1
        if next > ReconnectPolicy.maxAttempts {
            return .reconnectFailed
        }
        return .reconnecting(attempt: next, maxAttempts: ReconnectPolicy.maxAttempts)
    }
}

/// 共享自动重连退避策略：macOS 与 iOS 使用同一份参数，避免双端重连行为漂移。
enum ReconnectPolicy {
    /// 最大自动重连尝试次数
    static let maxAttempts: Int = 5
    /// 各次尝试之间的退避延迟（秒），索引对应 attempt-1
    static let delays: [TimeInterval] = [0.5, 1.0, 2.0, 4.0, 8.0]
    /// 每次等待 WS 连接结果的轮询超时（秒）
    static let perAttemptTimeout: TimeInterval = 3.0
    /// disconnect 后等待旧连接完全关闭的缓冲时长（秒）
    static let disconnectDrainDelay: TimeInterval = 0.5

    /// 取第 attempt（1 起始）次对应的退避延迟
    static func delay(for attempt: Int) -> TimeInterval {
        delays[min(attempt - 1, delays.count - 1)]
    }
}
