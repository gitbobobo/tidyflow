import Foundation

// MARK: - 流式事件批处理调度策略
//
// 将 AIChatStore 的 flush 调度策略从固定 50ms 常量改为自适应批处理决策。
// 纯类型（无副作用），可独立单测。

// MARK: - AIChatStreamBatchInput

/// 批处理决策的输入上下文
struct AIChatStreamBatchInput {
    /// 积压中的原始事件数量
    let pendingEventCount: Int
    /// 积压中纯文本 partDelta 的累计 UTF16 字符增量
    let pendingUTF16Delta: Int
    /// 是否包含结构性事件（messageUpdated、partUpdated）
    let containsStructuralEvent: Bool
    /// 是否是流结束信号触发的调度
    let isStreamEnding: Bool
}

// MARK: - AIChatStreamBatchDecision

/// 批处理调度决策
struct AIChatStreamBatchDecision {
    /// 是否立即刷新（true = 不等待，直接在当前上下文执行 flush）
    let shouldFlushImmediately: Bool
    /// 下一次等待间隔（秒）；仅在 shouldFlushImmediately == false 时有意义
    let nextFlushDelay: TimeInterval
    /// 决策原因（用于日志与调试）
    let reason: String
}

// MARK: - AIChatStreamingBatchScheduler

/// 流式事件批处理调度策略：纯决策层，无状态，无副作用。
///
/// 默认策略：
/// - 结构性事件（messageUpdated / partUpdated）或流结束 → 立即 flush
/// - 纯文本 partDelta 允许延迟合批；积压越深、文本越多，允许更长延迟
/// - 任意情况下等待不超过 `maxStaleness` 上限
enum AIChatStreamingBatchScheduler {

    /// 纯 delta 批次的绝对陈旧上限（秒）
    static let maxStaleness: TimeInterval = 0.20

    /// 计算当前积压的批处理决策。
    static func decide(_ input: AIChatStreamBatchInput) -> AIChatStreamBatchDecision {
        // 结构性事件或流结束：必须立即刷新
        if input.containsStructuralEvent || input.isStreamEnding {
            let reason = input.isStreamEnding ? "stream_end" : "structural_event"
            return AIChatStreamBatchDecision(
                shouldFlushImmediately: true,
                nextFlushDelay: 0,
                reason: reason
            )
        }

        // 纯文本 delta：根据积压深度与文本量自适应延迟
        let delay = adaptiveDelay(
            eventCount: input.pendingEventCount,
            utf16Delta: input.pendingUTF16Delta
        )
        return AIChatStreamBatchDecision(
            shouldFlushImmediately: false,
            nextFlushDelay: delay,
            reason: "delta_batch"
        )
    }

    /// 根据积压深度与文本量计算自适应延迟。
    ///
    /// - 小积压（事件少、文本短）：短等待，保证低延迟
    /// - 中等积压：中等等待，提升合批率
    /// - 大积压：更长等待，进一步减少 UI 刷新频率，但不超过 `maxStaleness`
    private static func adaptiveDelay(eventCount: Int, utf16Delta: Int) -> TimeInterval {
        if eventCount < 5 && utf16Delta < 200 {
            return 0.04
        }
        if eventCount < 20 && utf16Delta < 2_000 {
            return 0.08
        }
        return min(maxStaleness, 0.15)
    }
}
