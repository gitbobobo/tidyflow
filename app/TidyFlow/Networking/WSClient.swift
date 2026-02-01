import Foundation

/// Minimal WebSocket client for Core communication
class WSClient: NSObject, ObservableObject {
    static let defaultPort: Int = 47999
    static let defaultHost: String = "127.0.0.1"

    @Published private(set) var isConnected: Bool = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Message handlers
    var onFileIndexResult: ((FileIndexResult) -> Void)?
    var onError: ((String) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    // MARK: - Connection

    func connect() {
        guard webSocketTask == nil else { return }

        let urlString = "ws://\(Self.defaultHost):\(Self.defaultPort)/ws"
        guard let url = URL(string: urlString) else {
            onError?("Invalid WebSocket URL")
            return
        }

        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        updateConnectionState(false)
    }

    func reconnect() {
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.connect()
        }
    }

    // MARK: - Send Messages

    func send(_ message: String) {
        guard isConnected else {
            onError?("Not connected")
            return
        }

        webSocketTask?.send(.string(message)) { [weak self] error in
            if let error = error {
                self?.onError?("Send failed: \(error.localizedDescription)")
            }
        }
    }

    func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: data, encoding: .utf8) else {
            onError?("Failed to serialize JSON")
            return
        }
        send(jsonString)
    }

    func requestFileIndex(project: String, workspace: String) {
        sendJSON([
            "type": "file_index",
            "project": project,
            "workspace": workspace
        ])
    }

    // MARK: - Receive Messages

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage() // Continue listening
            case .failure(let error):
                // Connection closed or error
                if self?.isConnected == true {
                    self?.onError?("Receive error: \(error.localizedDescription)")
                    self?.updateConnectionState(false)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseAndDispatch(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseAndDispatch(text)
            }
        @unknown default:
            break
        }
    }

    private func parseAndDispatch(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "hello":
            // Connection established, ignore or log
            break

        case "file_index_result":
            if let result = FileIndexResult.from(json: json) {
                onFileIndexResult?(result)
            }

        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown error"
            onError?(errorMsg)

        default:
            // Unknown message type, ignore
            break
        }
    }

    private func updateConnectionState(_ connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = connected
            self?.onConnectionStateChanged?(connected)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WSClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        updateConnectionState(true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        updateConnectionState(false)
    }
}
