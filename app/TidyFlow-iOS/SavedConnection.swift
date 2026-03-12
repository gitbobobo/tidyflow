import Foundation

/// 已保存的连接信息，用于自动重连
struct SavedConnection: Codable {
    let host: String
    let port: Int
    let apiKey: String
    let clientInstanceID: String
    let savedAt: Date
    /// 是否使用 HTTPS/WSS（兼容旧数据默认 false）
    var useHTTPS: Bool = false

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case apiKey = "api_key"
        case clientInstanceID = "client_instance_id"
        case savedAt
        case useHTTPS
    }

    init(
        host: String,
        port: Int,
        apiKey: String,
        clientInstanceID: String,
        savedAt: Date,
        useHTTPS: Bool = false
    ) {
        self.host = host
        self.port = port
        self.apiKey = apiKey
        self.clientInstanceID = clientInstanceID
        self.savedAt = savedAt
        self.useHTTPS = useHTTPS
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
        do {
            return try JSONDecoder().decode(SavedConnection.self, from: data)
        } catch {
            // 旧的 wsToken 存档不做兼容迁移，直接清除。
            clear()
            return nil
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

enum ClientIdentityStorage {
    private static let key = "ios.clientInstanceID"

    static func loadOrCreate() -> String {
        if let existing = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
