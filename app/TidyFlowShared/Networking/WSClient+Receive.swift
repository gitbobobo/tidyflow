import Foundation

// MARK: - WSClient 接收消息扩展

extension WSClient {
    private struct ServerEnvelopeHeader: Decodable {
        let requestID: String?
        let seq: UInt64
        let domain: String
        let action: String
        let kind: String
        let serverTS: UInt64

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case seq
            case domain
            case action
            case kind
            case serverTS = "server_ts"
        }
    }

    private struct TypedServerEnvelope<Payload: Decodable>: Decodable {
        let requestID: String?
        let seq: UInt64
        let domain: String
        let action: String
        let kind: String
        let payload: Payload
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

    private struct FallbackServerEnvelope: Decodable {
        let payload: AnyCodable
    }

    private struct DecodedServerEnvelope {
        let payload: [String: Any]
    }

    private struct MessagePackBinary: Decodable {
        let bytes: [UInt8]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let data = try? container.decode(Data.self) {
                self.bytes = [UInt8](data)
                return
            }
            if let bytes = try? container.decode([UInt8].self) {
                self.bytes = bytes
                return
            }
            if let ints = try? container.decode([Int].self) {
                self.bytes = ints.compactMap { value in
                    guard value >= 0 && value <= 255 else { return nil }
                    return UInt8(value)
                }
                return
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解码二进制字段")
        }
    }

    private struct TerminalOutputBatchItemPayload: Decodable {
        let termID: String
        let data: MessagePackBinary

        enum CodingKeys: String, CodingKey {
            case termID = "term_id"
            case data
        }
    }

    private struct TerminalOutputBatchPayload: Decodable {
        let items: [TerminalOutputBatchItemPayload]
    }

    private struct FileChangedPayload: Decodable {
        let project: String
        let workspace: String
        let paths: [String]
        let kind: String
    }

    private struct GitStatusChangedPayload: Decodable {
        let project: String
        let workspace: String
    }

    private struct AIRawMessagesUpdatePayload: Decodable {
        let projectName: String
        let workspaceName: String
        let aiTool: String
        let sessionID: String
        let fromRevision: UInt64
        let toRevision: UInt64
        let isStreaming: Bool
        let selectionHint: [String: AnyCodable]?
        let messages: [[String: AnyCodable]]?
        let ops: [[String: AnyCodable]]?

        enum CodingKeys: String, CodingKey {
            case projectName = "project_name"
            case workspaceName = "workspace_name"
            case aiTool = "ai_tool"
            case sessionID = "session_id"
            case fromRevision = "from_revision"
            case toRevision = "to_revision"
            case isStreaming = "is_streaming"
            case selectionHint = "selection_hint"
            case messages
            case ops
        }
    }

    // MARK: - Receive Messages

    public func receiveMessage(for task: URLSessionWebSocketTask, identity: String) {
        task.receive { [weak self] result in
            guard let self else { return }
            guard self.webSocketTask === task, self.webSocketTaskIdentity == identity else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message, identity: identity)
                self.receiveMessage(for: task, identity: identity)
            case .failure(let error):
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
            CoreWSLog.ws.error("Received unexpected text message, protocol v9 requires binary")
        @unknown default:
            break
        }
    }

    /// 解析并分发二进制 MessagePack 消息。
    /// 高频域先做 header-first 解码，再进入 reducer 队列，最终只在主线程提交状态。
    private func parseAndDispatchBinary(_ data: Data, identity: String) {
        do {
            let header = try decodeEnvelopeHeader(data)
            try validateServerEnvelope(header)
            if tryDispatchHotEnvelope(data, header: header, identity: identity) {
                return
            }

            let envelope = try decodeServerEnvelope(data)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.acceptEnvelope(header, identity: identity) else { return }
                self.dispatchMessage(domain: header.domain, action: header.action, payload: envelope.payload)
            }
        } catch {
            CoreWSLog.ws.error("MessagePack decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func decodeEnvelopeHeader(_ data: Data) throws -> ServerEnvelopeHeader {
        try makeMessagePackDecoder().decode(ServerEnvelopeHeader.self, from: data)
    }

    private func decodeServerEnvelope(_ data: Data) throws -> DecodedServerEnvelope {
        let envelope = try makeMessagePackDecoder().decode(FallbackServerEnvelope.self, from: data)
        guard let payload = envelope.payload.toDictionary else {
            throw NSError(
                domain: "WSClient",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "Message payload must be object"]
            )
        }
        return DecodedServerEnvelope(payload: payload)
    }

    private func validateServerEnvelope(_ envelope: ServerEnvelopeHeader) throws {
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
    }

    private func acceptEnvelope(_ envelope: ServerEnvelopeHeader, identity: String) -> Bool {
        guard webSocketTaskIdentity == identity else { return false }
        if envelope.seq <= lastServerSeq {
            CoreWSLog.ws.warning(
                "Dropping stale envelope: seq=\(envelope.seq, privacy: .public), last=\(self.lastServerSeq, privacy: .public)"
            )
            return false
        }
        lastServerSeq = envelope.seq
        onServerEnvelopeMeta?(
            ServerEnvelopeMeta(
                seq: envelope.seq,
                domain: envelope.domain,
                action: envelope.action,
                kind: envelope.kind,
                requestID: envelope.requestID,
                serverTS: envelope.serverTS
            )
        )
        return true
    }

    private func tryDispatchHotEnvelope(_ data: Data, header: ServerEnvelopeHeader, identity: String) -> Bool {
        switch (header.domain, header.action) {
        case ("terminal", "output_batch"):
            terminalReducerQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let envelope = try self.makeMessagePackDecoder().decode(
                        TypedServerEnvelope<TerminalOutputBatchPayload>.self,
                        from: data
                    )
                    let items = envelope.payload.items.map {
                        TerminalOutputBatchItem(termId: $0.termID, data: $0.data.bytes)
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard self.acceptEnvelope(header, identity: identity) else { return }
                        self.dispatchTerminalOutputBatch(items)
                    }
                } catch {
                    CoreWSLog.ws.error("Terminal output_batch typed decode failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return true
        case ("ai", "ai_session_messages_update"):
            aiReducerQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let envelope = try self.makeMessagePackDecoder().decode(
                        TypedServerEnvelope<AIRawMessagesUpdatePayload>.self,
                        from: data
                    )
                    let json = self.makeAIUpdateJSON(from: envelope.payload)
                    guard let typed = AISessionMessagesUpdateV2.from(json: json) else {
                        CoreWSLog.ws.warning("Failed to convert ai_session_messages_update payload")
                        return
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard self.acceptEnvelope(header, identity: identity) else { return }
                        self.dispatchAISessionMessagesUpdate(typed)
                    }
                } catch {
                    CoreWSLog.ws.error("AI update typed decode failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return true
        case ("file", "file_changed"):
            workspaceReducerQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let envelope = try self.makeMessagePackDecoder().decode(
                        TypedServerEnvelope<FileChangedPayload>.self,
                        from: data
                    )
                    let json: [String: Any] = [
                        "project": envelope.payload.project,
                        "workspace": envelope.payload.workspace,
                        "paths": envelope.payload.paths,
                        "kind": envelope.payload.kind
                    ]
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard self.acceptEnvelope(header, identity: identity) else { return }
                        self.enqueueForCoalesce(domain: header.domain, action: header.action, json: json)
                    }
                } catch {
                    CoreWSLog.ws.error("File changed typed decode failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return true
        case ("git", "git_status_changed"):
            workspaceReducerQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let envelope = try self.makeMessagePackDecoder().decode(
                        TypedServerEnvelope<GitStatusChangedPayload>.self,
                        from: data
                    )
                    let json: [String: Any] = [
                        "project": envelope.payload.project,
                        "workspace": envelope.payload.workspace
                    ]
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard self.acceptEnvelope(header, identity: identity) else { return }
                        self.enqueueForCoalesce(domain: header.domain, action: header.action, json: json)
                    }
                } catch {
                    CoreWSLog.ws.error("Git status changed typed decode failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return true
        default:
            return false
        }
    }

    private func makeAIUpdateJSON(from payload: AIRawMessagesUpdatePayload) -> [String: Any] {
        var json: [String: Any] = [
            "project_name": payload.projectName,
            "workspace_name": payload.workspaceName,
            "ai_tool": payload.aiTool,
            "session_id": payload.sessionID,
            "from_revision": payload.fromRevision,
            "to_revision": payload.toRevision,
            "is_streaming": payload.isStreaming
        ]
        if let selectionHint = payload.selectionHint {
            json["selection_hint"] = selectionHint.mapValues(\.toAny)
        }
        if let messages = payload.messages {
            json["messages"] = messages.map { $0.mapValues(\.toAny) }
        }
        if let ops = payload.ops {
            json["ops"] = ops.map { $0.mapValues(\.toAny) }
        }
        return json
    }

    /// 分发解析后的低频消息到对应的处理器
    private func dispatchMessage(domain: String, action: String, payload: [String: Any]) {
        var json = payload
        json["type"] = action

        if isCoalescible(action) {
            enqueueForCoalesce(domain: domain, action: action, json: json)
            return
        }

        if routeByDomain(domain: domain, action: action, json: json) {
            return
        }
        _ = routeFallbackByAction(action, domain: domain, json: json)
    }

    private func dispatchTerminalOutputBatch(_ items: [TerminalOutputBatchItem]) {
        for item in items {
            if let handler = terminalMessageHandler {
                handler.handleTerminalOutput(item.termId, item.data)
            } else {
                onTerminalOutput?(item.termId, item.data)
            }
        }
    }

    private func dispatchAISessionMessagesUpdate(_ update: AISessionMessagesUpdateV2) {
        if let handler = aiMessageHandler {
            handler.handleAISessionMessagesUpdate(update)
        } else {
            onAISessionMessagesUpdate?(update)
        }
    }

    /// 处理合并队列刷新后的高频消息（由 flushCoalesceQueue 调用）
    public func dispatchCoalescedMessage(_ envelope: CoalescedEnvelope) {
        if routeByDomain(domain: envelope.domain, action: envelope.action, json: envelope.json) {
            return
        }
        _ = routeFallbackByAction(envelope.action, domain: envelope.domain, json: envelope.json)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WSClient: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard self.webSocketTask === webSocketTask else { return }
        isConnecting = false
        isIntentionalDisconnect = false
        connectionIdentity = webSocketTaskIdentity
        CoreWSLog.ws.info("WebSocket connected to: \(self.currentURL?.absoluteString ?? "unknown", privacy: .public)")
        updateConnectionState(true)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard self.webSocketTask === webSocketTask else { return }
        isConnecting = false
        self.webSocketTask = nil
        self.webSocketTaskIdentity = nil
        self.connectionIdentity = nil
        CoreWSLog.ws.info("WebSocket disconnected. Code: \(closeCode.rawValue, privacy: .public)")
        updateConnectionState(false)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === webSocketTask else { return }
        isConnecting = false
        if let error = error {
            webSocketTask = nil
            webSocketTaskIdentity = nil
            connectionIdentity = nil
            CoreWSLog.ws.error("URLSession error: \(error.localizedDescription, privacy: .public)")
            updateConnectionState(false)
        }
    }
}
