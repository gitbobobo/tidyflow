import Foundation
import CoreFoundation

// MARK: - Markdown 流式渲染策略共享纯类型
//
// 将 MarkdownTextView 内嵌的流式节流规则提取为可单测的纯策略类型，
// 保留 MarkdownTextView 调用面兼容（throttledRender 语义不变）。
// MarkdownFinalStateCache 保留在 MarkdownTextView.swift 以维持缓存 key 逻辑一致性。

// MARK: - StreamingMarkdownRenderBudget

/// Markdown 流式渲染时间预算：由当前文本体积决定渲染频率约束。
///
/// 文本越长，解析开销越大，节流间隔随之拉长，避免长消息流式输出时过度重绘。
struct StreamingMarkdownRenderBudget: Equatable {
    /// 最小渲染间隔：有意义增量存在时最快也需等待此时间
    let minInterval: CFAbsoluteTime
    /// 最大渲染间隔：无意义增量也会在此时间到达后强制渲染
    let maxInterval: CFAbsoluteTime
    /// 最小有意义字符增量（utf16 字符数）：不足此增量视为无意义
    let minimumMeaningfulDelta: Int

    /// 根据当前文本体积计算适合的渲染预算。
    static func budget(for text: String) -> StreamingMarkdownRenderBudget {
        let length = text.utf16.count
        switch length {
        case 0..<1_200:
            return StreamingMarkdownRenderBudget(minInterval: 0.20, maxInterval: 0.45, minimumMeaningfulDelta: 24)
        case 1_200..<4_000:
            return StreamingMarkdownRenderBudget(minInterval: 0.30, maxInterval: 0.75, minimumMeaningfulDelta: 64)
        default:
            return StreamingMarkdownRenderBudget(minInterval: 0.50, maxInterval: 1.20, minimumMeaningfulDelta: 120)
        }
    }
}

// MARK: - StreamingMarkdownRenderDecision

/// Markdown 流式渲染调度决策
enum StreamingMarkdownRenderDecision: Equatable {
    /// 立即渲染，附带渲染原因标记（用于调试日志）
    case renderNow(reason: RenderNowReason)
    /// 延迟渲染，等待 interval 秒后重试
    case deferRender(interval: CFAbsoluteTime)
    /// 无需渲染（文本未变化）
    case noop

    enum RenderNowReason: Equatable {
        case meaningfulIncrement   // 有意义增量 + 已超过 minInterval
        case maxIntervalElapsed    // 达到最大渲染间隔，强制刷新
        case streamEnded           // 流式结束，立即提交最终态
        case nonStreaming           // 非流式场景，直接渲染
    }
}

// MARK: - StreamingMarkdownRenderScheduler

/// Markdown 流式渲染调度器：给定渲染上下文，决定是否立即渲染或延迟。
///
/// 纯函数型，无副作用，可在单元测试中直接验证各场景的调度决策。
/// MarkdownTextView 持有调度器实例，把所有节流决策委托给此类型，
/// 避免 View 自身积累复杂调度状态。
struct StreamingMarkdownRenderScheduler {

    /// 计算本次是否有意义的文本增量。
    static func hasMeaningfulIncrement(renderedText: String, newText: String) -> Bool {
        guard renderedText != newText else { return false }
        guard newText.count >= renderedText.count else { return true }

        let budget = StreamingMarkdownRenderBudget.budget(for: newText)
        let delta = newText.utf16.count - renderedText.utf16.count
        if delta >= budget.minimumMeaningfulDelta {
            return true
        }

        return newText.last == "\n" ||
            newText.hasSuffix("```") ||
            newText.last == "." ||
            newText.last == "。" ||
            newText.last == ":" ||
            newText.last == "："
    }

    /// 给定当前渲染上下文，计算调度决策。
    ///
    /// - Parameters:
    ///   - renderedText: 已提交给 StructuredText 的文本
    ///   - incomingText: 收到的最新文本
    ///   - isStreaming: 当前是否处于流式输出状态
    ///   - lastRenderTime: 上次渲染时的绝对时间
    ///   - now: 当前绝对时间
    /// - Returns: 渲染调度决策
    func decide(
        renderedText: String,
        incomingText: String,
        isStreaming: Bool,
        lastRenderTime: CFAbsoluteTime,
        now: CFAbsoluteTime
    ) -> StreamingMarkdownRenderDecision {
        guard isStreaming else {
            if renderedText != incomingText {
                return .renderNow(reason: .nonStreaming)
            }
            return .noop
        }

        guard incomingText != renderedText else { return .noop }

        let elapsed = now - lastRenderTime
        let budget = StreamingMarkdownRenderBudget.budget(for: incomingText)
        let hasMeaningful = Self.hasMeaningfulIncrement(renderedText: renderedText, newText: incomingText)

        if elapsed >= budget.maxInterval {
            return .renderNow(reason: .maxIntervalElapsed)
        }
        if hasMeaningful && elapsed >= budget.minInterval {
            return .renderNow(reason: .meaningfulIncrement)
        }

        let remaining = max(0, (hasMeaningful ? budget.minInterval : budget.maxInterval) - elapsed)
        return .deferRender(interval: remaining)
    }

    /// 流式结束时的特殊决策：无论当前状态，若文本未渲染则立即提交。
    func decideOnStreamEnd(renderedText: String, finalText: String) -> StreamingMarkdownRenderDecision {
        guard renderedText != finalText else { return .noop }
        return .renderNow(reason: .streamEnded)
    }
}
