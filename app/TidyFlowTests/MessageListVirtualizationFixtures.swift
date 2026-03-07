import Foundation
@testable import TidyFlow

// MARK: - 消息列表虚拟化测试夹具
// 提供可重复生成的 100 条消息测试数据集，覆盖纯文本、工具卡片、流式消息和混合内容，
// 作为内存与滚动性能基准测试的标准输入。

/// 描述一条测试用消息的轻量数据载体（不含 SwiftUI 视图依赖）
struct VirtualizationTestMessage {
    let index: Int
    let role: AIChatRole
    let isStreaming: Bool
    let hasToolCard: Bool
    let hasReasoning: Bool
    let textLength: Int
}

enum MessageListVirtualizationFixtures {

    // MARK: - 轻量夹具生成（不需要实例化 AIChatPart/AIChatMessage）

    /// 生成 N 条纯文本消息描述（role 交替）
    static func makeTextMessageDescriptors(count: Int) -> [VirtualizationTestMessage] {
        (0..<count).map { i in
            VirtualizationTestMessage(
                index: i,
                role: i % 2 == 0 ? .user : .assistant,
                isStreaming: false,
                hasToolCard: false,
                hasReasoning: false,
                textLength: 80 + (i % 5) * 40
            )
        }
    }

    /// 生成混合内容消息描述（每 5 条插入一条工具消息，可选最后一条为流式）
    static func make100MixedDescriptors(streamingLast: Bool = false) -> [VirtualizationTestMessage] {
        (0..<100).map { i in
            let isLast = (i == 99)
            return VirtualizationTestMessage(
                index: i,
                role: isLast || i % 2 == 1 ? .assistant : .user,
                isStreaming: streamingLast && isLast,
                hasToolCard: i % 5 == 4,
                hasReasoning: false,
                textLength: 80 + (i % 6) * 30
            )
        }
    }

    /// 生成含 reasoning 的消息描述（模拟 thinking 模式，N 条）
    static func makeReasoningMessageDescriptors(count: Int) -> [VirtualizationTestMessage] {
        (0..<count).map { i in
            VirtualizationTestMessage(
                index: i,
                role: .assistant,
                isStreaming: false,
                hasToolCard: false,
                hasReasoning: true,
                textLength: 120 + (i % 4) * 60
            )
        }
    }

    // MARK: - AIChatMessage 夹具生成

    /// 生成 N 条纯文本 AIChatMessage
    static func makeTextMessages(count: Int) -> [AIChatMessage] {
        (0..<count).map { i in
            let part = AIChatPart(
                id: "text-part-\(i)",
                kind: .text,
                text: String(repeating: "消息\(i) ", count: 10)
            )
            return AIChatMessage(
                id: "text-msg-\(i)",
                messageId: "srv-\(i)",
                role: i % 2 == 0 ? .user : .assistant,
                parts: [part],
                isStreaming: false,
                timestamp: Date(timeIntervalSinceReferenceDate: Double(i) * 60)
            )
        }
    }

    /// 生成标准 100 条混合内容 AIChatMessage（纯文本 + 工具消息，可选最后一条流式）
    static func make100MixedMessages(streamingLast: Bool = false) -> [AIChatMessage] {
        (0..<100).map { i in
            let isLast = (i == 99)
            let streaming = streamingLast && isLast
            let parts: [AIChatPart]
            if i % 5 == 4 {
                // 工具消息：一个 text part + 一个 tool part
                parts = [
                    AIChatPart(id: "p-\(i)-0", kind: .text, text: "正在调用工具…"),
                    AIChatPart(id: "p-\(i)-1", kind: .tool, text: nil, toolName: "bash", toolState: nil)
                ]
            } else if streaming {
                parts = [AIChatPart(id: "p-\(i)-0", kind: .text, text: "正在生成…")]
            } else {
                parts = [AIChatPart(id: "p-\(i)-0", kind: .text, text: "消息 \(i + 1) 内容")]
            }
            return AIChatMessage(
                id: "msg-\(i)",
                messageId: "srv-\(i)",
                role: (isLast || i % 2 == 1) ? .assistant : .user,
                parts: parts,
                isStreaming: streaming,
                timestamp: Date(timeIntervalSinceReferenceDate: Double(i) * 60)
            )
        }
    }

    // MARK: - 虚拟化场景辅助

    /// 模拟用户停留在底部时的可见索引集合
    static func bottomVisibleIndices(total: Int, visibleCount: Int = 10) -> [Int] {
        let start = max(0, total - visibleCount)
        return Array(start..<total)
    }

    /// 模拟用户在中部滚动时的可见索引集合
    static func middleVisibleIndices(total: Int, center: Int? = nil, visibleCount: Int = 10) -> [Int] {
        let mid = center ?? (total / 2)
        let halfV = visibleCount / 2
        let start = max(0, mid - halfV)
        let end = min(total - 1, start + visibleCount - 1)
        guard start <= end else { return [] }
        return Array(start...end)
    }

    /// 计算在给定场景下的完整渲染消息数（用于量化虚拟化带来的渲染集缩减）
    static func fullRenderCount(
        window: MessageVirtualizationWindow,
        visibleIndices: [Int],
        totalCount: Int
    ) -> Int {
        if let range = window.computeFullRenderRange(
            visibleIndices: visibleIndices,
            totalCount: totalCount
        ) {
            return range.count
        }
        return window.warmStartRange(totalCount: totalCount).map { $0.count } ?? 0
    }

    /// 计算虚拟化后的渲染节省比例（完整渲染比例 vs 总数）
    /// 返回值：被降级为轻量渲染的消息占比（越高越好）
    static func lightweightRatio(
        window: MessageVirtualizationWindow,
        visibleIndices: [Int],
        totalCount: Int
    ) -> Double {
        guard totalCount > 0 else { return 0 }
        let full = fullRenderCount(window: window, visibleIndices: visibleIndices, totalCount: totalCount)
        let lightweight = totalCount - full
        return Double(lightweight) / Double(totalCount)
    }

    /// 生成快速滚动场景下的可见索引序列（从顶部滚动到底部，每次滑动 visibleCount/2 条）
    static func rapidScrollSequence(total: Int, visibleCount: Int = 10, steps: Int = 100) -> [[Int]] {
        guard total > 0, steps > 0 else { return [] }
        let step = max(1, total / steps)
        var result: [[Int]] = []
        var position = 0
        while position < total {
            let end = min(total - 1, position + visibleCount - 1)
            if position <= end {
                result.append(Array(position...end))
            }
            position += step
        }
        return result
    }
}
