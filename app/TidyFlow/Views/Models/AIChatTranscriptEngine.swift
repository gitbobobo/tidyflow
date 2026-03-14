import Foundation
import CoreGraphics
import Observation

// MARK: - 聊天转录引擎共享纯类型
//
// 将消息列表的视口状态、延迟刷新规划与渲染计划提取为纯值类型，
// 与 SwiftUI 视图解耦，可在 macOS/iOS 双端及 Evolution 回放场景共享。
// MessageListView / AIChatTranscriptContainer 消费这些类型，但不持有其实现细节。

// MARK: - AIChatTranscriptViewportState

/// 聊天转录视图的可见区与稳定渲染范围状态。
///
/// 纯值类型，无视图依赖，可在单元测试中直接验证。
/// 用于封装 `visibleMessageIDs`、稳定渲染范围与 prepend 锚点，
/// 解耦 AIChatTranscriptContainer 中的内联可见区追踪逻辑。
struct AIChatTranscriptViewportState: Equatable {
    /// 当前确认可见的消息 ID 集合（由 onAppear/onDisappear 维护）。
    var visibleMessageIDs: Set<String> = []
    /// 稳定化完整渲染范围：仅在 visibleIndices 非空时更新，
    /// 防止快速滚动导致窗口短暂清空后退回 warm start。
    var stableFullRenderRange: ClosedRange<Int>? = nil
    /// 历史 prepend 后待保持的视口锚点消息 ID。
    var pendingPrependAnchorID: String? = nil
    /// 上一帧已知的滚动内容高度，用于区分内容增长与用户主动滚动。
    var lastKnownContentHeight: CGFloat = 0

    /// 基于新的可见索引更新稳定渲染范围。
    /// 仅当 visibleIndices 非空时更新，防止瞬时清空导致范围回退。
    mutating func applyVisibleIndices(
        _ visibleIndices: [Int],
        totalCount: Int,
        window: MessageVirtualizationWindow
    ) {
        guard let newRange = window.computeFullRenderRange(
            visibleIndices: visibleIndices,
            totalCount: totalCount
        ) else { return }
        stableFullRenderRange = newRange
    }

    /// 会话切换时完全重置：清除所有跨会话残留状态。
    mutating func reset() {
        visibleMessageIDs = []
        stableFullRenderRange = nil
        pendingPrependAnchorID = nil
        lastKnownContentHeight = 0
    }
}

// MARK: - AIChatTranscriptRefreshStrategy

/// 消息列表单次刷新策略：描述本次更新应以哪种方式刷新显示缓存。
enum AIChatTranscriptRefreshStrategy: Equatable {
    /// 仅同步流式尾消息，不重算整表过滤。
    case tailSync
    /// 完整重建显示缓存（消息数变化、会话切换、流式结束）。
    case fullRefresh
    /// 历史 prepend 后保留当前锚点，不触发向下滚动。
    case preserveAnchor(anchorID: String)
    /// 无可见变化，跳过本次刷新。
    case none
}

// MARK: - AIChatTranscriptRenderPlan

/// 消息列表单次渲染计划：`AIChatTranscriptUpdatePlanner` 的纯计算结果。
///
/// 视图层只读取此结构，不直接参与刷新决策。
struct AIChatTranscriptRenderPlan {
    let displayMessages: [AIChatMessage]
    let refreshStrategy: AIChatTranscriptRefreshStrategy
    let fullRenderRange: ClosedRange<Int>?
    let pendingAnchorID: String?
}

// MARK: - AIChatTranscriptUpdatePlanner

/// 聊天转录更新规划器：给定消息列表与视口状态，计算下一次刷新所需的渲染计划。
///
/// 纯静态函数，无副作用，可在单元测试中直接调用，适用于
/// 主聊天、子代理子会话、Evolution 回放等所有消息列表场景。
enum AIChatTranscriptUpdatePlanner {

    /// 计算下一个渲染计划。
    ///
    /// - Parameters:
    ///   - sourceMessages: 当前完整消息源列表（含 pendingQuestions 过滤前的原始消息）
    ///   - pendingQuestions: 待处理工具问题集合，用于过滤显示消息
    ///   - viewportState: 当前视口状态（可见区、稳定渲染范围、prepend 锚点）
    ///   - cachedDisplayMessages: 上次已应用的显示消息缓存
    ///   - cachedSourceCount: 上次缓存时的消息源数量
    ///   - isScrollInFlight: 当前是否处于滚动状态（影响 defer 决策）
    /// - Returns: 渲染计划，含刷新策略与 displayMessages
    static func plan(
        sourceMessages: [AIChatMessage],
        pendingQuestions: [String: AIQuestionRequestInfo],
        viewportState: AIChatTranscriptViewportState,
        cachedDisplayMessages: [AIChatMessage],
        cachedSourceCount: Int,
        isScrollInFlight: Bool
    ) -> AIChatTranscriptRenderPlan {
        // 判断是否仅为尾部流式增量：消息数不变且尾消息处于流式状态
        let isTailOnlyUpdate =
            cachedSourceCount == sourceMessages.count &&
            sourceMessages.last?.isStreaming == true

        // 确定刷新策略
        let strategy: AIChatTranscriptRefreshStrategy
        if let anchorID = viewportState.pendingPrependAnchorID,
           sourceMessages.count > cachedSourceCount {
            strategy = .preserveAnchor(anchorID: anchorID)
        } else if isTailOnlyUpdate, !cachedDisplayMessages.isEmpty {
            strategy = .tailSync
        } else if cachedSourceCount != sourceMessages.count ||
                  (cachedDisplayMessages.isEmpty && !sourceMessages.isEmpty) {
            strategy = .fullRefresh
        } else {
            strategy = .none
        }

        // 计算显示消息：tailSync 路径只更新尾消息，避免整表重算
        let displayMessages: [AIChatMessage]
        if strategy == .tailSync {
            let snapshot = AIChatTranscriptDisplayCacheSemantics.synchronizeAfterTailChange(
                sourceMessages: sourceMessages,
                pendingQuestions: pendingQuestions,
                cachedDisplayMessages: cachedDisplayMessages,
                cachedSourceCount: cachedSourceCount
            )
            displayMessages = snapshot.messages
        } else {
            let snapshot = AIChatTranscriptDisplayCacheSemantics.makeSnapshot(
                sourceMessages: sourceMessages,
                pendingQuestions: pendingQuestions
            )
            displayMessages = snapshot.messages
        }

        return AIChatTranscriptRenderPlan(
            displayMessages: displayMessages,
            refreshStrategy: strategy,
            fullRenderRange: viewportState.stableFullRenderRange,
            pendingAnchorID: viewportState.pendingPrependAnchorID
        )
    }

    /// 基于消息数量变化类型推断刷新策略（不依赖缓存，用于简单场景）。
    static func strategy(
        previousSourceCount: Int,
        currentSourceCount: Int,
        isStreamingTail: Bool,
        hasPendingAnchor: Bool
    ) -> AIChatTranscriptRefreshStrategy {
        if hasPendingAnchor, currentSourceCount > previousSourceCount {
            return .preserveAnchor(anchorID: "")
        }
        if currentSourceCount == previousSourceCount, isStreamingTail {
            return .tailSync
        }
        if currentSourceCount != previousSourceCount {
            return .fullRefresh
        }
        return .none
    }
}

// MARK: - AIChatTranscriptProjection

/// 聊天转录投影：消息列表的完整显示数据，由 `AIChatTranscriptProjectionStore` 维护。
///
/// 包含 displayMessages、预计算的 messageIndexMap 和稳定化的渲染范围，
/// 使 `AIChatTranscriptContent` 不再在 body 内重复构建索引映射。
/// macOS 与 iOS 均复用同一投影类型，不存在平台分支。
struct AIChatTranscriptProjection {
    let displayMessages: [AIChatMessage]
    /// 预计算的消息 ID → 索引映射，避免 Content body 内每帧重建。
    let messageIndexMap: [String: Int]
    let fullRenderRange: ClosedRange<Int>?
    let pendingAnchorID: String?
    let refreshStrategy: AIChatTranscriptRefreshStrategy
    let sourceCount: Int

    static let empty = AIChatTranscriptProjection(
        displayMessages: [],
        messageIndexMap: [:],
        fullRenderRange: nil,
        pendingAnchorID: nil,
        refreshStrategy: .fullRefresh,
        sourceCount: 0
    )
}

// MARK: - AIChatTranscriptInvalidationSignature

/// 转录失效签名：仅包含影响整表结构的最小信号，
/// 用于判断是否需要 fullRefresh，不包含 tailRevision 等高频信号。
struct AIChatTranscriptInvalidationSignature: Equatable {
    let messageCount: Int
    let pendingQuestionVersion: Int
    let sessionToken: String?
}

// MARK: - AIChatTranscriptProjectionStore

/// 聊天转录投影 store：管理 displayMessages、messageIndexMap 与渲染范围的生命周期。
///
/// 职责：
/// - 仅在结构性变化时重建整表投影（消息数变化、会话切换、pendingQuestion 变更）
/// - tail token 更新走尾消息 patch，不重建索引映射
/// - 视口范围更新仅替换 fullRenderRange，不重建消息列表
///
/// macOS 与 iOS 共享同一实现。`AIChatTranscriptContainer` 持有此 store，
/// `AIChatTranscriptContent` 消费其产出的投影。
@Observable
final class AIChatTranscriptProjectionStore {
    private(set) var projection: AIChatTranscriptProjection = .empty
    /// 上次应用 plan 时的 source message count，用于检测结构性变化。
    private(set) var cachedSourceCount: Int = -1

    /// 应用 planner 产出的渲染计划，同步更新投影。
    ///
    /// - 当刷新策略为 tailSync 时，仅替换尾消息，复用已有 indexMap
    ///   （尾消息替换不改变索引结构）。
    /// - 其他策略完整重建 indexMap。
    @discardableResult
    func apply(plan: AIChatTranscriptRenderPlan, sourceCount: Int) -> AIChatTranscriptRefreshStrategy {
        let indexMap: [String: Int]
        switch plan.refreshStrategy {
        case .tailSync where !projection.messageIndexMap.isEmpty:
            // tailSync：消息数不变、仅尾部内容变化，复用已有 indexMap
            indexMap = projection.messageIndexMap
        default:
            indexMap = Self.buildIndexMap(plan.displayMessages)
        }
        projection = AIChatTranscriptProjection(
            displayMessages: plan.displayMessages,
            messageIndexMap: indexMap,
            fullRenderRange: plan.fullRenderRange,
            pendingAnchorID: plan.pendingAnchorID,
            refreshStrategy: plan.refreshStrategy,
            sourceCount: sourceCount
        )
        cachedSourceCount = sourceCount
        return plan.refreshStrategy
    }

    /// 仅更新稳定化的完整渲染范围，不重建消息列表与索引映射。
    func updateFullRenderRange(_ range: ClosedRange<Int>?) {
        guard range != projection.fullRenderRange else { return }
        projection = AIChatTranscriptProjection(
            displayMessages: projection.displayMessages,
            messageIndexMap: projection.messageIndexMap,
            fullRenderRange: range,
            pendingAnchorID: projection.pendingAnchorID,
            refreshStrategy: projection.refreshStrategy,
            sourceCount: projection.sourceCount
        )
    }

    /// 会话切换时完全重置。
    func reset() {
        projection = .empty
        cachedSourceCount = -1
    }

    private static func buildIndexMap(_ messages: [AIChatMessage]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($1.id, $0) })
    }
}
