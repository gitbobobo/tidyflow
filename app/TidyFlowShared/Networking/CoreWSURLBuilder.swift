import Foundation

/// 共享网络层 WebSocket URL 构造辅助
/// 避免 TidyFlowShared 反向依赖 app target 的 AppConfig。
public enum CoreWSURLBuilder {
    /// 构造 WebSocket 连接 URL
    public static func makeURL(
        host: String = "127.0.0.1",
        port: Int,
        token: String? = nil,
        clientID: String? = nil,
        deviceName: String? = nil,
        secure: Bool = false
    ) -> URL {
        var components = URLComponents()
        components.scheme = secure ? "wss" : "ws"
        components.host = host
        components.port = port
        components.path = "/ws"
        var queryItems: [URLQueryItem] = []
        if let token, !token.isEmpty {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        if let clientID, !clientID.isEmpty {
            queryItems.append(URLQueryItem(name: "client_id", value: clientID))
        }
        if let deviceName, !deviceName.isEmpty {
            queryItems.append(URLQueryItem(name: "device_name", value: deviceName))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url!
    }
}
