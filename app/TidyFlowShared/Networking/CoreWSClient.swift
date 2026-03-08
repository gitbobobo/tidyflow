import Foundation

// MARK: - CoreWSClient 共享引用类型

/// 平台侧通过此协议与共享 WSClient 交互，屏蔽具体实现细节。
/// macOS 和 iOS 均可通过同一套共享抽象消费协议事件。
public protocol CoreWSClientProtocol: CoreMessageDispatcher {
    // 连接生命周期
    func connect()
    func connect(port: Int)
    func disconnect()
    func reconnect()
    func updateAuthToken(_ token: String?)
    func updatePort(_ port: Int, reconnect: Bool)

    // Ping 探活
    func sendPing(timeout: TimeInterval, completion: @escaping (Bool) -> Void)

    // 领域 handler 绑定
    var gitMessageHandler: (any GitMessageHandler)? { get set }
    var projectMessageHandler: (any ProjectMessageHandler)? { get set }
    var fileMessageHandler: (any FileMessageHandler)? { get set }
    var terminalMessageHandler: (any TerminalMessageHandler)? { get set }
    var aiMessageHandler: (any AIMessageHandler)? { get set }
    var evolutionMessageHandler: (any EvolutionMessageHandler)? { get set }
    var errorMessageHandler: (any ErrorMessageHandler)? { get set }
}
