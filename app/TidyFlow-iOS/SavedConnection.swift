import Foundation

/// 已保存的连接信息，用于自动重连
struct SavedConnection: Codable {
    let host: String
    let port: Int
    let wsToken: String
    let deviceName: String
    let savedAt: Date
    /// 是否使用 HTTPS/WSS（兼容旧数据默认 false）
    var useHTTPS: Bool = false

    enum CodingKeys: String, CodingKey {
        case host, port, wsToken, deviceName, savedAt, useHTTPS
    }

    init(host: String, port: Int, wsToken: String, deviceName: String, savedAt: Date, useHTTPS: Bool = false) {
        self.host = host
        self.port = port
        self.wsToken = wsToken
        self.deviceName = deviceName
        self.savedAt = savedAt
        self.useHTTPS = useHTTPS
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        wsToken = try c.decode(String.self, forKey: .wsToken)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        useHTTPS = (try? c.decode(Bool.self, forKey: .useHTTPS)) ?? false
    }
}

/// 连接信息持久化（UserDefaults）
enum ConnectionStorage {
    private static let key = "ios.savedConnection"

    static func save(_ conn: SavedConnection) {
        if let data = try? JSONEncoder().encode(conn) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> SavedConnection? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedConnection.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
