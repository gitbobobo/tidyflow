import Foundation

/// 终端会话列表项
struct TerminalSessionInfo {
    let termId: String
    let project: String
    let workspace: String
    let cwd: String
    let shell: String
    let status: String
    let remoteSubscribers: [RemoteSubscriberDetail]

    var isRunning: Bool { status == "running" }

    static func from(json: [String: Any]) -> TerminalSessionInfo? {
        guard let termId = json["term_id"] as? String,
              let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cwd = json["cwd"] as? String,
              let shell = json["shell"] as? String else {
            return nil
        }
        let status = json["status"] as? String ?? "running"
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
            remoteSubscribers: subscribers
        )
    }
}

/// 远程订阅者详情
struct RemoteSubscriberDetail {
    let deviceName: String
    let connId: String

    static func from(json: [String: Any]) -> RemoteSubscriberDetail? {
        guard let deviceName = json["device_name"] as? String,
              let connId = json["conn_id"] as? String else {
            return nil
        }
        return RemoteSubscriberDetail(deviceName: deviceName, connId: connId)
    }
}

/// term_created 响应
struct TermCreatedResult {
    let termId: String
    let project: String
    let workspace: String
    let cwd: String
    let shell: String

    static func from(json: [String: Any]) -> TermCreatedResult? {
        guard let termId = json["term_id"] as? String,
              let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cwd = json["cwd"] as? String,
              let shell = json["shell"] as? String else {
            return nil
        }
        return TermCreatedResult(termId: termId, project: project, workspace: workspace, cwd: cwd, shell: shell)
    }
}

/// term_attached 响应
struct TermAttachedResult {
    let termId: String
    let project: String
    let workspace: String
    let cwd: String
    let shell: String
    let scrollback: [UInt8]

    static func from(json: [String: Any]) -> TermAttachedResult? {
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
            scrollback: scrollback
        )
    }
}

/// term_list 响应
struct TermListResult {
    let items: [TerminalSessionInfo]

    static func from(json: [String: Any]) -> TermListResult? {
        guard let arr = json["items"] as? [[String: Any]] else {
            return nil
        }
        return TermListResult(items: arr.compactMap { TerminalSessionInfo.from(json: $0) })
    }
}

/// 二进制字段解码辅助
enum WSBinary {
    /// MessagePack bin 在 AnyCodable 下可能表现为 `Data` / `[Int]` / `[UInt8]`
    static func decodeBytes(_ value: Any?) -> [UInt8] {
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
