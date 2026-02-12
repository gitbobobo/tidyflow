import Foundation

/// 已保存的连接信息，用于自动重连
struct SavedConnection: Codable {
    let host: String
    let port: Int
    let wsToken: String
    let deviceName: String
    let savedAt: Date
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
