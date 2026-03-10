import Foundation

// MARK: - AI 会话共享语义层
//
// 跨平台共享的 AI 会话语义工具层，提供统一的 selection hint 合并与推导、
// pending question request 重建、消息 part 去重规则，以及分页默认值。
// macOS 与 iOS 通过此层共享规则，不再各自维护同义私有实现。

// MARK: - AI 会话上下文快照

/// AI 会话上下文快照（可跨工作区复用的会话知识摘要）
/// 与 Core 协议中 `AiSessionContextSnapshot` 对应。
struct AISessionContextSnapshot: Equatable {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let snapshotAtMs: Int64
    let messageCount: Int
    let contextSummary: String?
    let selectionHint: AISessionSelectionHint?
    let contextRemainingPercent: Double?

    static func from(json: [String: Any]) -> AISessionContextSnapshot? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiToolRaw = json["ai_tool"] as? String,
              let aiTool = AIChatTool(rawValue: aiToolRaw),
              let sessionId = json["session_id"] as? String else { return nil }
        let snapshotAtMs: Int64
        switch json["snapshot_at_ms"] {
        case let v as Int64: snapshotAtMs = v
        case let v as Int: snapshotAtMs = Int64(v)
        case let v as NSNumber: snapshotAtMs = v.int64Value
        default: snapshotAtMs = 0
        }
        let messageCount = json["message_count"] as? Int ?? 0
        let contextSummary = json["context_summary"] as? String
        let selectionHint: AISessionSelectionHint?
        if let hintJson = json["selection_hint"] as? [String: Any] {
            let hint = AISessionSelectionHint(
                agent: hintJson["agent"] as? String,
                modelProviderID: hintJson["model_provider_id"] as? String,
                modelID: hintJson["model_id"] as? String,
                configOptions: nil
            )
            selectionHint = hint.isEmpty ? nil : hint
        } else {
            selectionHint = nil
        }
        let contextRemainingPercent = (json["context_remaining_percent"] as? NSNumber)?.doubleValue
        return AISessionContextSnapshot(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            snapshotAtMs: snapshotAtMs,
            messageCount: messageCount,
            contextSummary: contextSummary,
            selectionHint: selectionHint,
            contextRemainingPercent: contextRemainingPercent
        )
    }
}

enum AISessionSemantics {

    // MARK: - 分页常量

    /// 双端统一默认分页大小，历史加载和流式快照均使用此值。
    static let defaultMessagesPageSize: Int = 50

    // MARK: - 会话键

    /// 统一四元组会话键：`project::workspace::aiTool::sessionId`。
    /// macOS 与 iOS 必须通过此工厂方法生成会话键，确保双端格式完全一致。
    static func sessionKey(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> String {
        "\(project)::\(workspace)::\(aiTool.rawValue)::\(sessionId)"
    }

    // MARK: - 列表可见性

    /// 判断会话是否应出现在默认会话列表中。
    /// `evolutionSystem` 来源的会话隐藏（由自动化循环创建），其他来源（`user`）可见。
    /// 双端共用同一规则，不在视图层各自判断。
    static func isSessionVisibleInDefaultList(origin: AISessionOrigin) -> Bool {
        origin != .evolutionSystem
    }

    // MARK: - 消息流归一化

    /// 共享消息流归一化结果，供历史加载（`ai_session_messages`）与
    /// 流式快照（`ai_session_messages_update` 含 messages）统一复用。
    struct MessageStreamNormalizationOutput {
        /// 从消息列表重建的未完成 pending question requests
        let pendingQuestionRequests: [AIQuestionRequestInfo]
        /// 合并后的 selection hint（primary 优先，推导值兜底）
        let effectiveSelectionHint: AISessionSelectionHint?
    }

    /// 共享消息流归一化入口：
    /// 1. 重建 pending question requests（跳过 completed/error 状态）
    /// 2. 从消息列表推导 selection hint
    /// 3. 将协议携带的 primarySelectionHint 与推导值合并（primary 优先）
    ///
    /// `ai_session_messages`、`ai_session_messages_update`（含 messages 快照）
    /// 都必须经过此入口，不再各自做三步重复操作。
    static func normalizeMessageStream(
        sessionId: String,
        messages: [AIProtocolMessageInfo],
        primarySelectionHint: AISessionSelectionHint?
    ) -> MessageStreamNormalizationOutput {
        let pendingQuestions = rebuildPendingQuestionRequests(sessionId: sessionId, messages: messages)
        let inferredHint = inferSelectionHintFromMessages(messages)
        let effectiveHint = mergedSelectionHint(primary: primarySelectionHint, fallback: inferredHint)
        return MessageStreamNormalizationOutput(
            pendingQuestionRequests: pendingQuestions,
            effectiveSelectionHint: effectiveHint
        )
    }

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
    /// 最后回退到 part 级别的 source 字段提取。
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

    /// 从单个消息 part 的 source 推导 selection hint。
    static func inferSelectionHintFromPart(_ part: AIProtocolPartInfo) -> AISessionSelectionHint? {
        var resolvedAgent: String?
        var resolvedProvider: String?
        var resolvedModel: String?

        let sources: [[String: Any]] = [part.source].compactMap { $0 }
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
                guard let question = part.toolView?.question else { continue }
                let status = part.toolView?.status ?? .unknown
                if status == .completed || status == .error {
                    continue
                }
                let questions = question.promptItems
                guard !questions.isEmpty else { continue }

                let requestId = question.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !requestId.isEmpty else { continue }
                guard !seenRequestIDs.contains(requestId) else { continue }
                seenRequestIDs.insert(requestId)

                requests.append(
                    AIQuestionRequestInfo(
                        id: requestId,
                        sessionId: sessionId,
                        questions: questions,
                        toolMessageId: question.toolMessageID ?? part.id,
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

    // MARK: - 上下文快照缓存键

    /// 会话上下文快照缓存键：`project::workspace::aiTool::sessionId`
    /// 与 sessionKey 格式一致，确保跨端缓存格式完全统一。
    static func contextSnapshotKey(
        project: String,
        workspace: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> String {
        sessionKey(project: project, workspace: workspace, aiTool: aiTool, sessionId: sessionId)
    }

    /// 从上下文快照恢复 selection hint。
    /// 优先使用快照中的 selection_hint，fallback 到推导逻辑。
    static func selectionHintFromSnapshot(
        _ snapshot: AISessionContextSnapshot?,
        fallback: AISessionSelectionHint?
    ) -> AISessionSelectionHint? {
        guard let snapshot = snapshot else { return fallback }
        return mergedSelectionHint(primary: snapshot.selectionHint, fallback: fallback)
    }
}

// MARK: - AI 会话列表共享语义层
//
// 会话列表项的可见性过滤、当前选中判定、分页防重入等规则
// 下沉到此枚举，macOS 与 iOS 视图层直接调用，不再各自推导。

enum AISessionListSemantics {

    /// 判断某会话是否为当前选中会话。
    /// 双端统一规则：session.id 与 currentSessionId 匹配，且 aiTool 与 currentTool 匹配。
    static func isSessionSelected(
        session: AISessionInfo,
        currentSessionId: String?,
        currentTool: AIChatTool
    ) -> Bool {
        session.id == currentSessionId && session.aiTool == currentTool
    }

    /// 生成会话列表分页缓存键，格式 "project::workspace::filterId"。
    /// macOS/iOS 共用同一键格式，确保跨端语义一致。
    static func pageKey(project: String, workspace: String, filter: AISessionListFilter) -> String {
        "\(project)::\(workspace)::\(filter.id)"
    }
}

// MARK: - 会话列表展示状态

/// AI 会话列表的展示阶段，双端共享判断逻辑。
/// 视图通过此枚举决定呈现 loading / empty / content，不再在 View body 中内联 if-else 判断。
enum AISessionListDisplayPhase {
    /// 初次加载中且无缓存会话
    case loading
    /// 加载完成但会话列表为空
    case empty
    /// 有会话可展示（含分页加载更多状态）
    case content

    /// 从分页状态和会话列表推导展示阶段。
    static func from(isLoadingInitial: Bool, sessions: [AISessionInfo]) -> AISessionListDisplayPhase {
        if isLoadingInitial && sessions.isEmpty { return .loading }
        if sessions.isEmpty { return .empty }
        return .content
    }
}
