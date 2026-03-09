import Foundation

// MARK: - WSClient 接收消息扩展

extension WSClient {
    private struct ServerEnvelopeV6: Decodable {
        let requestID: String?
        let seq: UInt64
        let domain: String
        let action: String
        let kind: String
        let payload: AnyCodable
        let serverTS: UInt64

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case seq
            case domain
            case action
            case kind
            case payload
            case serverTS = "server_ts"
        }
    }

    private struct DecodedServerEnvelope {
        let requestID: String?
        let seq: UInt64
        let domain: String
        let action: String
        let kind: String
        let payload: [String: Any]
        let serverTS: UInt64
    }

    // MARK: - Receive Messages

    func receiveMessage(for task: URLSessionWebSocketTask, identity: String) {
        task.receive { [weak self] result in
            guard let self else { return }
            // 旧连接回调可能在重连后延迟到达；只处理当前 task 的回调。
            guard self.webSocketTask === task, self.webSocketTaskIdentity == identity else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message, identity: identity)
                self.receiveMessage(for: task, identity: identity) // Continue listening
            case .failure(let error):
                // Connection closed or error — 切回主线程更新状态
                DispatchQueue.main.async {
                    guard self.webSocketTask === task, self.webSocketTaskIdentity == identity else { return }
                    self.isConnecting = false
                    self.webSocketTask = nil
                    self.webSocketTaskIdentity = nil
                    self.connectionIdentity = nil
                    if self.isConnected {
                        self.emitClientError("Receive error: \(error.localizedDescription)")
                        self.updateConnectionState(false)
                    }
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message, identity: String) {
        switch message {
        case .data(let data):
            parseAndDispatchBinary(data, identity: identity)
        case .string:
            TFLog.ws.error("Received unexpected text message, protocol v6 requires binary")
        @unknown default:
            break
        }
    }

    /// 解析并分发二进制 MessagePack 消息
    /// 解码在后台队列执行，分发回调切回主线程
    private func parseAndDispatchBinary(_ data: Data, identity: String) {
        do {
            let envelope = try decodeServerEnvelope(data)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.webSocketTaskIdentity == identity else { return }
                self.dispatchMessage(envelope)
            }
        } catch {
            TFLog.ws.error("MessagePack decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func decodeServerEnvelope(_ data: Data) throws -> DecodedServerEnvelope {
        let envelope = try msgpackDecoder.decode(ServerEnvelopeV6.self, from: data)
        guard let payload = envelope.payload.toDictionary else {
            throw NSError(
                domain: "WSClient",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "Message payload must be object"]
            )
        }
        try validateServerEnvelope(envelope, payload: payload)
        return DecodedServerEnvelope(
            requestID: envelope.requestID,
            seq: envelope.seq,
            domain: envelope.domain,
            action: envelope.action,
            kind: envelope.kind,
            payload: payload,
            serverTS: envelope.serverTS
        )
    }

    private func validateServerEnvelope(_ envelope: ServerEnvelopeV6, payload: [String: Any]) throws {
        if envelope.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            envelope.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(
                domain: "WSClient",
                code: -1002,
                userInfo: [NSLocalizedDescriptionKey: "Envelope missing domain/action"]
            )
        }
        if envelope.kind != "result" && envelope.kind != "event" && envelope.kind != "error" {
            throw NSError(
                domain: "WSClient",
                code: -1003,
                userInfo: [NSLocalizedDescriptionKey: "Envelope kind invalid: \(envelope.kind)"]
            )
        }
        if envelope.serverTS == 0 {
            throw NSError(
                domain: "WSClient",
                code: -1004,
                userInfo: [NSLocalizedDescriptionKey: "Envelope server_ts is required"]
            )
        }
        if payload.isEmpty && envelope.action != "hello" && envelope.action != "pong" {
            TFLog.ws.warning("Envelope payload is empty: action=\(envelope.action, privacy: .public)")
        }
    }

    /// 分发解析后的消息到对应的处理器
    private func dispatchMessage(_ envelope: DecodedServerEnvelope) {
        let type = envelope.action
        let seq = envelope.seq
        let domain = envelope.domain
        let kind = envelope.kind
        let payload = envelope.payload
        if seq <= lastServerSeq {
            TFLog.ws.warning(
                "Dropping stale envelope: seq=\(seq, privacy: .public), last=\(self.lastServerSeq, privacy: .public)"
            )
            return
        }
        lastServerSeq = seq
        onServerEnvelopeMeta?(
            ServerEnvelopeMeta(
                seq: seq,
                domain: domain,
                action: type,
                kind: kind,
                requestID: envelope.requestID,
                serverTS: envelope.serverTS
            )
        )
        var json = payload
        json["type"] = type

        // 高频消息走合并队列，避免淹没 UI 线程
        if isCoalescible(type) {
            enqueueForCoalesce(domain: domain, action: type, json: json)
            return
        }

        if routeByDomain(domain: domain, action: type, json: json) {
            return
        }
        _ = routeFallbackByAction(type, domain: domain, json: json)
    }


    /// 处理合并队列刷新后的高频消息（由 flushCoalesceQueue 调用）
    func dispatchCoalescedMessage(_ envelope: CoalescedEnvelope) {
        if routeByDomain(domain: envelope.domain, action: envelope.action, json: envelope.json) {
            return
        }
        _ = routeFallbackByAction(envelope.action, domain: envelope.domain, json: envelope.json)
    }

}

// MARK: - URLSessionWebSocketDelegate

extension WSClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard self.webSocketTask === webSocketTask else { return }
        isConnecting = false
        isIntentionalDisconnect = false
        connectionIdentity = webSocketTaskIdentity
        TFLog.ws.info("WebSocket connected to: \(self.currentURL?.absoluteString ?? "unknown", privacy: .public)")
        updateConnectionState(true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard self.webSocketTask === webSocketTask else { return }
        isConnecting = false
        self.webSocketTask = nil
        self.webSocketTaskIdentity = nil
        self.connectionIdentity = nil
        TFLog.ws.info("WebSocket disconnected. Code: \(closeCode.rawValue, privacy: .public)")
        updateConnectionState(false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === webSocketTask else { return }
        isConnecting = false
        if let error = error {
            webSocketTask = nil
            webSocketTaskIdentity = nil
            connectionIdentity = nil
            TFLog.ws.error("URLSession error: \(error.localizedDescription, privacy: .public)")
            updateConnectionState(false)
        }
    }
}
