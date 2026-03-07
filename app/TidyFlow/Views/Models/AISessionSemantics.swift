import Foundation

// MARK: - AI 会话共享语义层
//
// 跨平台共享的 AI 会话语义工具层，提供统一的 selection hint 合并与推导、
// pending question request 重建、消息 part 去重规则，以及分页默认值。
// macOS 与 iOS 通过此层共享规则，不再各自维护同义私有实现。

enum AISessionSemantics {

    // MARK: - 分页常量

    /// 双端统一默认分页大小，历史加载和流式快照均使用此值。
    static let defaultMessagesPageSize: Int = 50

    // MARK: - Selection Hint 合并

    /// 合并两个 selection hint：primary 优先，fallback 补全缺失字段。
    /// configOptions 取 primary 覆盖 fallback 的联合集。
    static func mergedSelectionHint(
        primary: AISessionSelectionHint?,
        fallback: AISessionSelectionHint?
    ) -> AISessionSelectionHint? {
        if primary == nil { return fallback }
        if fallback == nil { return primary }
        var mergedConfigOptions: [String: Any] = fallback?.configOptions ?? [:]
        if let primaryConfig = primary?.configOptions {
            for (optionID, value) in primaryConfig {
                mergedConfigOptions[optionID] = value
            }
        }
        let merged = AISessionSelectionHint(
            agent: primary?.agent ?? fallback?.agent,
            modelProviderID: primary?.modelProviderID ?? fallback?.modelProviderID,
            modelID: primary?.modelID ?? fallback?.modelID,
            configOptions: mergedConfigOptions.isEmpty ? nil : mergedConfigOptions
        )
        return merged.isEmpty ? nil : merged
    }

    // MARK: - Selection Hint 推导

    /// 从消息列表推导 selection hint。
    /// 优先从最新的 user 消息顶层字段提取，再从任意最新消息提取，
    /// 最后回退到 part 级别的 source / metadata / toolState 字段提取。
    static func inferSelectionHintFromMessages(_ messages: [AIProtocolMessageInfo]) -> AISessionSelectionHint? {
        // 优先从 user 消息的顶层字段推导
        for message in messages.reversed() where message.role.caseInsensitiveCompare("user") == .orderedSame {
            let hint = AISessionSelectionHint(
                agent: message.agent,
                modelProviderID: message.modelProviderID,
                modelID: message.modelID,
                configOptions: nil
            )
            if !hint.isEmpty { return hint }
        }
        // 回退：从任意最新消息的顶层字段
        for message in messages.reversed() {
            let hint = AISessionSelectionHint(
                agent: message.agent,
                modelProviderID: message.modelProviderID,
                modelID: message.modelID,
                configOptions: nil
            )
            if !hint.isEmpty { return hint }
        }
        // 回退：从 user 消息的 part 级别元数据推导
        for message in messages.reversed() where message.role.caseInsensitiveCompare("user") == .orderedSame {
            for part in message.parts.reversed() {
                if let hint = inferSelectionHintFromPart(part), !hint.isEmpty { return hint }
            }
        }
        // 回退：从任意消息的 part 级别元数据推导
        for message in messages.reversed() {
            for part in message.parts.reversed() {
                if let hint = inferSelectionHintFromPart(part), !hint.isEmpty { return hint }
            }
        }
        return nil
    }

    /// 从单个消息 part 的 source / toolPartMetadata / toolState 推导 selection hint。
    static func inferSelectionHintFromPart(_ part: AIProtocolPartInfo) -> AISessionSelectionHint? {
        var resolvedAgent: String?
        var resolvedProvider: String?
        var resolvedModel: String?

        let sources: [[String: Any]] = [part.source, part.toolPartMetadata, part.toolState].compactMap { $0 }
        for source in sources {
            if resolvedAgent == nil {
                resolvedAgent = findSelectionHintValue(
                    in: source,
                    keys: [
                        "agent", "agent_name", "selected_agent", "current_agent",
                        "mode", "mode_id", "current_mode_id", "selected_mode_id", "collaboration_mode",
                    ]
                )
            }
            if resolvedProvider == nil {
                resolvedProvider = findSelectionHintValue(
                    in: source,
                    keys: ["model_provider_id", "provider_id", "provider", "model_provider"]
                )
            }
            if resolvedModel == nil {
                resolvedModel = findSelectionHintValue(
                    in: source,
                    keys: ["model_id", "model", "current_model_id", "selected_model_id"]
                )
            }
            if resolvedAgent != nil && resolvedModel != nil { break }
        }

        let hint = AISessionSelectionHint(
            agent: resolvedAgent,
            modelProviderID: resolvedProvider,
            modelID: resolvedModel,
            configOptions: nil
        )
        return hint.isEmpty ? nil : hint
    }

    // MARK: - Pending Question Request 重建

    /// 从消息列表重建未完成的 pending question requests。
    /// 跳过 completed / error / failed / done 状态，避免把已完成历史误判为待处理。
    static func rebuildPendingQuestionRequests(
        sessionId: String,
        messages: [AIProtocolMessageInfo]
    ) -> [AIQuestionRequestInfo] {
        var requests: [AIQuestionRequestInfo] = []
        var seenRequestIDs: Set<String> = []

        for message in messages {
            for part in message.parts {
                guard part.partType == "tool" else { continue }
                let toolName = (part.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard toolName == "question" else { continue }
                guard let stateDict = part.toolState else { continue }

                let status = ((stateDict["status"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if status == "completed" || status == "error" || status == "failed" || status == "done" {
                    continue
                }

                let input = stateDict["input"] as? [String: Any]
                let questionsValue = input?["questions"] ?? stateDict["questions"]
                let questions = parseQuestionInfos(from: questionsValue)
                guard !questions.isEmpty else { continue }

                let metadata = part.toolPartMetadata ?? [:]
                let requestId =
                    stringValue(metadata["request_id"]) ??
                    stringValue(metadata["requestId"]) ??
                    stringValue(stateDict["request_id"]) ??
                    stringValue(stateDict["requestId"]) ??
                    stringValue((stateDict["metadata"] as? [String: Any])?["request_id"]) ??
                    stringValue((stateDict["metadata"] as? [String: Any])?["requestId"]) ??
                    part.toolCallId
                guard let requestId, !requestId.isEmpty else { continue }
                guard !seenRequestIDs.contains(requestId) else { continue }
                seenRequestIDs.insert(requestId)

                let toolMessageId =
                    stringValue(metadata["tool_message_id"]) ??
                    stringValue(metadata["toolMessageId"]) ??
                    part.id

                requests.append(
                    AIQuestionRequestInfo(
                        id: requestId,
                        sessionId: sessionId,
                        questions: questions,
                        toolMessageId: toolMessageId,
                        toolCallId: part.toolCallId
                    )
                )
            }
        }

        return requests
    }

    // MARK: - 消息 Part 归一化与去重

    /// 将协议消息 part 列表归一化并去重。
    /// 同一 part id 只保留最后一次（最完整合并状态），供历史页（session/load）
    /// 与流式快照（session/update snapshot）共用，不再各维护一套去重规则。
    static func normalizeAndDedupParts(_ protoParts: [AIProtocolPartInfo]) -> [AIChatPart] {
        var dedupedParts: [AIChatPart] = []
        var seenPartIds: [String: Int] = [:]
        for protoPart in protoParts {
            let chatPart = AIChatPartNormalization.makeChatPart(from: protoPart)
            if let existing = seenPartIds[chatPart.id] {
                dedupedParts[existing] = chatPart
            } else {
                seenPartIds[chatPart.id] = dedupedParts.count
                dedupedParts.append(chatPart)
            }
        }
        return dedupedParts
    }

    // MARK: - 公开辅助工具

    /// 解析 question infos 列表（支持 [[String:Any]] / [Any] / 嵌套 dict）。
    static func parseQuestionInfos(from value: Any?) -> [AIQuestionInfo] {
        if let array = value as? [[String: Any]] {
            return array.compactMap { AIQuestionInfo.from(json: $0) }
        }
        if let array = value as? [Any] {
            return array.compactMap { item in
                guard let dict = item as? [String: Any] else { return nil }
                return AIQuestionInfo.from(json: dict)
            }
        }
        if let dict = value as? [String: Any], let nested = dict["questions"] {
            return parseQuestionInfos(from: nested)
        }
        return []
    }

    /// 将任意值转换为非空字符串；NSNumber 转为字符串表示。
    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    // MARK: - 私有辅助

    private static func findSelectionHintValue(in source: [String: Any], keys: [String]) -> String? {
        let normalizedKeys = Set(keys.map(normalizeSelectionHintKey))
        var queue: [Any] = [source]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            if let dict = current as? [String: Any] {
                for (key, nested) in dict {
                    if normalizedKeys.contains(normalizeSelectionHintKey(key)),
                       let parsed = parseSelectionHintScalar(nested) {
                        return parsed
                    }
                    queue.append(nested)
                }
                continue
            }
            if let array = current as? [Any] {
                queue.append(contentsOf: array)
            }
        }
        return nil
    }

    private static func parseSelectionHintScalar(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            let text = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    static func normalizeSelectionHintKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
           .lowercased()
           .filter { $0.isLetter || $0.isNumber }
    }
}
