import Foundation

/// 终端会话列表项
public struct TerminalSessionInfo {
    public let termId: String
    public let project: String
    public let workspace: String
    public let cwd: String
    public let shell: String
    public let status: String
    public let name: String?
    public let icon: String?
    public let remoteSubscribers: [RemoteSubscriberDetail]

    public var isRunning: Bool { status == "running" }

    public static func from(json: [String: Any]) -> TerminalSessionInfo? {
        guard let termId = json["term_id"] as? String,
              let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cwd = json["cwd"] as? String,
              let shell = json["shell"] as? String else {
            return nil
        }
        let status = json["status"] as? String ?? "running"
        let name = json["name"] as? String
        let icon = json["icon"] as? String
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
            name: name,
            icon: icon,
            remoteSubscribers: subscribers
        )
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
