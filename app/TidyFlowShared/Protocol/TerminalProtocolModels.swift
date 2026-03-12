import Foundation

public struct TerminalOutputBatchItem {
    public let termId: String
    public let data: [UInt8]

    public static func from(json: [String: Any]) -> TerminalOutputBatchItem? {
        guard let termId = json["term_id"] as? String else { return nil }
        return TerminalOutputBatchItem(termId: termId, data: WSBinary.decodeBytes(json["data"]))
    }

    public init(termId: String, data: [UInt8]) {
        self.termId = termId
        self.data = data
    }
}

/// 终端会话列表项
public struct TerminalSessionInfo {
    public let termId: String
    public let project: String
    public let workspace: String
    public let cwd: String
    public let shell: String
    public let status: String
    /// Core 权威生命周期相位："entering"/"active"/"resuming"/"idle"/"recovering"/"recovery_failed"
    public let lifecyclePhase: String
    public let name: String?
    public let icon: String?
    /// Core 重启恢复相位（仅 lifecycle_phase=recovering/recovery_failed 时非 nil）
    /// 客户端必须以此字段为权威来源，不得自行推导恢复状态
    public let recoveryPhase: String?
    /// 恢复失败原因（仅 recoveryPhase=recovery_failed 时有值）
    public let recoveryFailedReason: String?
    public let remoteSubscribers: [RemoteSubscriberDetail]

    public var isRunning: Bool { status == "running" }
    /// 是否处于 Core 重启恢复中（区别于 WS 断连重附着的 resuming）
    public var isRecovering: Bool { lifecyclePhase == "recovering" }
    /// 是否恢复失败
    public var isRecoveryFailed: Bool { lifecyclePhase == "recovery_failed" }

    public static func from(json: [String: Any]) -> TerminalSessionInfo? {
        guard let termId = json["term_id"] as? String,
              let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cwd = json["cwd"] as? String,
              let shell = json["shell"] as? String else {
            return nil
        }
        let status = json["status"] as? String ?? "running"
        let lifecyclePhase = json["lifecycle_phase"] as? String ?? "active"
        let name = json["name"] as? String
        let icon = json["icon"] as? String
        let recoveryPhase = json["recovery_phase"] as? String
        let recoveryFailedReason = json["recovery_failed_reason"] as? String
        var subscribers: [RemoteSubscriberDetail] = []
        if let arr = json["remote_subscribers"] as? [[String: Any]] {
            subscribers = arr.compactMap { RemoteSubscriberDetail.from(json: $0) }
        }
        return TerminalSessionInfo(
            termId: termId,
            project: project,
            workspace: workspace,
            cwd: cwd,
            shell: shell,
            status: status,
            lifecyclePhase: lifecyclePhase,
            name: name,
            icon: icon,
            recoveryPhase: recoveryPhase,
            recoveryFailedReason: recoveryFailedReason,
            remoteSubscribers: subscribers
        )
    }

    public init(termId: String, project: String, workspace: String, cwd: String, shell: String,
                status: String, lifecyclePhase: String = "active", name: String?, icon: String?,
                recoveryPhase: String? = nil, recoveryFailedReason: String? = nil,
                remoteSubscribers: [RemoteSubscriberDetail]) {
        self.termId = termId
        self.project = project
        self.workspace = workspace
        self.cwd = cwd
        self.shell = shell
        self.status = status
        self.lifecyclePhase = lifecyclePhase
        self.name = name
        self.icon = icon
        self.recoveryPhase = recoveryPhase
        self.recoveryFailedReason = recoveryFailedReason
        self.remoteSubscribers = remoteSubscribers
    }
}

/// 远程订阅者详情
public struct RemoteSubscriberDetail {
    public let deviceName: String
    public let connId: String

    public static func from(json: [String: Any]) -> RemoteSubscriberDetail? {
        guard let deviceName = json["device_name"] as? String,
              let connId = json["conn_id"] as? String else {
            return nil
        }
        return RemoteSubscriberDetail(deviceName: deviceName, connId: connId)
    }

    public init(deviceName: String, connId: String) {
        self.deviceName = deviceName
        self.connId = connId
    }
}

/// term_created 响应
public struct TermCreatedResult {
    public let termId: String
    public let project: String
    public let workspace: String
    public let cwd: String
    public let shell: String
    public let name: String?
    public let icon: String?

    public static func from(json: [String: Any]) -> TermCreatedResult? {
        guard let termId = json["term_id"] as? String,
              let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cwd = json["cwd"] as? String,
              let shell = json["shell"] as? String else {
            return nil
        }
        return TermCreatedResult(
            termId: termId, project: project, workspace: workspace,
            cwd: cwd, shell: shell,
            name: json["name"] as? String,
            icon: json["icon"] as? String
        )
    }

    public init(termId: String, project: String, workspace: String, cwd: String, shell: String, name: String?, icon: String?) {
        self.termId = termId
        self.project = project
        self.workspace = workspace
        self.cwd = cwd
        self.shell = shell
        self.name = name
        self.icon = icon
    }
}

/// term_attached 响应
public struct TermAttachedResult {
    public let termId: String
    public let project: String
    public let workspace: String
    public let cwd: String
    public let shell: String
    public let scrollback: [UInt8]
    public let name: String?
    public let icon: String?

    public static func from(json: [String: Any]) -> TermAttachedResult? {
        guard let termId = json["term_id"] as? String,
              let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cwd = json["cwd"] as? String,
              let shell = json["shell"] as? String else {
            return nil
        }
        let scrollback = WSBinary.decodeBytes(json["scrollback"])
        return TermAttachedResult(
            termId: termId,
            project: project,
            workspace: workspace,
            cwd: cwd,
            shell: shell,
            scrollback: scrollback,
            name: json["name"] as? String,
            icon: json["icon"] as? String
        )
    }

    public init(termId: String, project: String, workspace: String, cwd: String, shell: String, scrollback: [UInt8], name: String?, icon: String?) {
        self.termId = termId
        self.project = project
        self.workspace = workspace
        self.cwd = cwd
        self.shell = shell
        self.scrollback = scrollback
        self.name = name
        self.icon = icon
    }
}

/// term_list 响应
public struct TermListResult {
    public let items: [TerminalSessionInfo]

    public static func from(json: [String: Any]) -> TermListResult? {
        guard let arr = json["items"] as? [[String: Any]] else {
            return nil
        }
        return TermListResult(items: arr.compactMap { TerminalSessionInfo.from(json: $0) })
    }

    public init(items: [TerminalSessionInfo]) {
        self.items = items
    }
}

/// 二进制字段解码辅助
public enum WSBinary {
    /// MessagePack bin 在 AnyCodable 下可能表现为 `Data` / `[Int]` / `[UInt8]`
    public static func decodeBytes(_ value: Any?) -> [UInt8] {
        if let data = value as? Data {
            return [UInt8](data)
        }
        if let bytes = value as? [UInt8] {
            return bytes
        }
        if let arr = value as? [Int] {
            return arr.compactMap { num in
                guard num >= 0 && num <= 255 else { return nil }
                return UInt8(num)
            }
        }
        if let arr = value as? [Any] {
            return arr.compactMap { element -> UInt8? in
                if let n = element as? Int, n >= 0 && n <= 255 {
                    return UInt8(n)
                }
                if let n = element as? NSNumber {
                    let value = n.intValue
                    guard value >= 0 && value <= 255 else { return nil }
                    return UInt8(value)
                }
                return nil
            }
        }
        return []
    }
}
