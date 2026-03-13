import Foundation

extension Collection {
    subscript(safe index: Index) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

// MARK: - 流式增量聚合共享类型
//
// 将 AIChatStore 内的流式事件聚合与尾部变化摘要逻辑提取为纯类型，
// 保持 AIChatStore 对外接口（messages、tailRevision、isStreaming）不变，
// 同时使聚合语义可独立单元测试、可跨场景复用。

// MARK: - AIChatTailChangeSummary

/// 一次 flush 后尾部可见内容发生了什么变化的摘要。
///
/// 用于判断是否值得推进 tailRevision：只有发生可见变化时才需要通知 UI 刷新。
/// AIChatStore.publishTailSignals 可基于此摘要做条件发布。
enum AIChatTailChangeSummary: Equatable {
    /// 追加了新消息（消息数增加）
    case appendedNewMessage
    /// 尾消息文本增长（流式 token 到达）
    case grewTailText
    /// 工具 part 状态变化（running/done/error）
    case changedToolPartStatus
    /// 尾消息的流式状态发生变化。
    case changedStreamingState
    /// 尾部内容被替换、删除或截断。
    case replacedTailContent
    /// 无可见变化（纯索引维护或不可见字段变动）
    case noMeaningfulChange

    /// 是否需要触发 UI 刷新
    var hasMeaningfulChange: Bool {
        self != .noMeaningfulChange
    }
}

// MARK: - AIChatStreamCoalescer

/// 流式事件聚合器：将连续同类型增量合并为最小有效事件集。
///
/// 从 `AIChatStore` 内提取，使聚合逻辑可独立验证。
/// 语义不变：只合并同一 partId/field 的连续 delta，不跨 session 或 workspace 合并。
enum AIChatStreamCoalescer {
    private static func stableMessageIdentity(for message: AIChatMessage) -> String {
        if let messageId = message.messageId, !messageId.isEmpty {
            return "remote:\(messageId)"
        }
        return "local:\(message.id)"
    }

    /// 将一批流式事件聚合为最小有效事件集。
    ///
    /// 策略：
    /// - 同一 messageId 的连续 messageUpdated 合并为最后一条
    /// - 同一 (messageId, partId, field) 的连续 partDelta 文本追加合并
    /// - partUpdated 不合并，保留原位序
    ///
    /// - Parameter events: 原始事件序列
    /// - Returns: 聚合后的最小事件集
    static func coalesce(_ events: [AIChatStreamEvent]) -> [AIChatStreamEvent] {
        guard !events.isEmpty else { return [] }

        var result: [AIChatStreamEvent] = []
        var pendingMessageUpdates: [String: String] = [:]
        var pendingMessageOrder: [String] = []
        var pendingDelta: AIChatStreamEvent?

        func flushMessageUpdates() {
            guard !pendingMessageOrder.isEmpty else { return }
            for messageId in pendingMessageOrder {
                if let role = pendingMessageUpdates.removeValue(forKey: messageId) {
                    result.append(.messageUpdated(messageId: messageId, role: role))
                }
            }
            pendingMessageOrder.removeAll(keepingCapacity: true)
        }

        func flushPendingDelta() {
            if let d = pendingDelta {
                result.append(d)
            }
            pendingDelta = nil
        }

        for event in events {
            switch event {
            case .messageUpdated(let messageId, let role):
                flushPendingDelta()
                if pendingMessageUpdates[messageId] == nil {
                    pendingMessageOrder.append(messageId)
                }
                pendingMessageUpdates[messageId] = role
            case .partUpdated:
                flushMessageUpdates()
                flushPendingDelta()
                result.append(event)
            case .partDelta(let messageId, let partId, let partType, let field, let delta):
                flushMessageUpdates()
                if case let .partDelta(eMessageId, ePartId, ePartType, eField, eD)? = pendingDelta,
                   eMessageId == messageId,
                   ePartId == partId,
                   ePartType == partType,
                   eField == field {
                    pendingDelta = .partDelta(
                        messageId: messageId,
                        partId: partId,
                        partType: partType,
                        field: field,
                        delta: eD + delta
                    )
                } else {
                    flushPendingDelta()
                    pendingDelta = event
                }
            }
        }

        flushMessageUpdates()
        flushPendingDelta()
        return result
    }

    /// 基于消息列表前后快照计算尾部变化摘要。
    ///
    /// 用于 AIChatStore.publishTailSignals 判断是否需要推进 tailRevision。
    /// 比较最后一条 assistant 消息的变化，而不是整表扫描。
    ///
    /// - Parameters:
    ///   - before: flush 前的消息列表
    ///   - after: flush 后的消息列表
    /// - Returns: 尾部变化摘要
    static func summarizeTailChange(
        before: [AIChatMessage],
        after: [AIChatMessage]
    ) -> AIChatTailChangeSummary {
        if before.isEmpty && after.isEmpty {
            return .noMeaningfulChange
        }
        if before.isEmpty && !after.isEmpty {
            return .appendedNewMessage
        }
        if !before.isEmpty && after.isEmpty {
            return .replacedTailContent
        }

        // 消息数增加：追加了新消息
        if after.count > before.count {
            return .appendedNewMessage
        }
        if after.count < before.count {
            return .replacedTailContent
        }

        // 尾部消息变化：比较最后一条消息
        guard let afterTail = after.last,
              let beforeTail = before.last,
              stableMessageIdentity(for: afterTail) == stableMessageIdentity(for: beforeTail) else {
            return .replacedTailContent
        }
        if afterTail.isStreaming != beforeTail.isStreaming {
            return .changedStreamingState
        }

        // 比较 parts：工具状态变化
        if afterTail.parts.count != beforeTail.parts.count {
            return .replacedTailContent
        }

        // 文本增长检测
        for (aPart, bPart) in zip(afterTail.parts, beforeTail.parts) {
            if aPart.kind != bPart.kind || aPart.id != bPart.id {
                return .replacedTailContent
            }
            if aPart.kind == .tool && aPart.toolView?.status != bPart.toolView?.status {
                return .changedToolPartStatus
            }
            if let beforeText = bPart.text, let afterText = aPart.text, beforeText != afterText {
                return afterText.hasPrefix(beforeText) ? .grewTailText : .replacedTailContent
            }
            if let afterText = aPart.text, bPart.text == nil {
                return afterText.isEmpty ? .noMeaningfulChange : .grewTailText
            }
            if aPart.text == nil && bPart.text != nil {
                return .replacedTailContent
            }
            if aPart.mime != bPart.mime || aPart.filename != bPart.filename || aPart.url != bPart.url {
                return .replacedTailContent
            }
            if aPart.toolName != bPart.toolName || aPart.toolKind != bPart.toolKind {
                return .replacedTailContent
            }
        }

        return .noMeaningfulChange
    }
}
