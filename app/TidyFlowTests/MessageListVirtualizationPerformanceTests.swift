import XCTest
@testable import TidyFlow

// MARK: - 100 条消息内存性能测试（CHK-003）
// 验证虚拟化窗口在长会话场景下的渲染集缩减效果，
// 确保 AC-002（内存占用降低 30%+）有可执行的量化验证路径。

final class MessageListVirtualizationMemoryPerformanceTests: XCTestCase {

    private let window = MessageVirtualizationWindow()

    // MARK: - 渲染集缩减量化验证（AC-002 核心路径）

    func testRenderReduction_100Messages_atBottom_exceeds30Percent() {
        // 100 条消息，用户在底部（最后 10 条可见）
        // 完整渲染范围：max(0, 90-12)...min(99, 99+12) = 78...99 = 22 条
        // 渲染节省 = (100 - 22) / 100 = 78% >> 30% 目标
        let total = 100
        let visibleIndices = MessageListVirtualizationFixtures.bottomVisibleIndices(
            total: total, visibleCount: 10
        )

        let ratio = MessageListVirtualizationFixtures.lightweightRatio(
            window: window, visibleIndices: visibleIndices, totalCount: total
        )

        XCTAssertGreaterThanOrEqual(
            ratio, 0.30,
            "100 条消息场景下，轻量渲染占比应 ≥ 30%，实际为 \(String(format: "%.1f%%", ratio * 100))"
        )
    }

    func testRenderReduction_100Messages_atMiddle_exceeds30Percent() {
        // 用户在中部（第 50 条附近可见 10 条）
        // 完整渲染范围：38...62 = 25 条
        // 渲染节省 = (100 - 25) / 100 = 75% >> 30%
        let total = 100
        let visibleIndices = MessageListVirtualizationFixtures.middleVisibleIndices(
            total: total, center: 50, visibleCount: 10
        )

        let ratio = MessageListVirtualizationFixtures.lightweightRatio(
            window: window, visibleIndices: visibleIndices, totalCount: total
        )

        XCTAssertGreaterThanOrEqual(
            ratio, 0.30,
            "100 条消息中部滚动场景，轻量渲染占比应 ≥ 30%，实际为 \(String(format: "%.1f%%", ratio * 100))"
        )
    }

    func testRenderReduction_200Messages_atBottom_exceeds50Percent() {
        // 200 条消息，用户在底部
        // 渲染范围约 178...199 = 22 条，节省约 (200-22)/200 = 89%
        let total = 200
        let visibleIndices = MessageListVirtualizationFixtures.bottomVisibleIndices(
            total: total, visibleCount: 10
        )

        let ratio = MessageListVirtualizationFixtures.lightweightRatio(
            window: window, visibleIndices: visibleIndices, totalCount: total
        )

        XCTAssertGreaterThanOrEqual(
            ratio, 0.50,
            "200 条消息场景下，轻量渲染占比应 ≥ 50%，实际为 \(String(format: "%.1f%%", ratio * 100))"
        )
    }

    func testRenderSetSize_100Messages_atBottom_withinBudget() {
        // 完整渲染集大小应在合理范围内（不超过 buffer*2 + 可见区）
        let total = 100
        let visibleCount = 10
        let visibleIndices = MessageListVirtualizationFixtures.bottomVisibleIndices(
            total: total, visibleCount: visibleCount
        )

        let fullCount = MessageListVirtualizationFixtures.fullRenderCount(
            window: window, visibleIndices: visibleIndices, totalCount: total
        )
        let expectedMax = window.bufferCount * 2 + visibleCount

        XCTAssertLessThanOrEqual(
            fullCount, expectedMax,
            "完整渲染集大小应 ≤ buffer*2 + visibleCount = \(expectedMax)，实际为 \(fullCount)"
        )
    }

    // MARK: - 夹具一致性验证

    func testFixture_100MixedMessages_hasCorrectCount() {
        let messages = MessageListVirtualizationFixtures.make100MixedMessages()
        XCTAssertEqual(messages.count, 100, "混合夹具应包含 100 条消息")
    }

    func testFixture_100MixedMessages_hasToolCards() {
        let messages = MessageListVirtualizationFixtures.make100MixedMessages()
        let toolMessages = messages.filter { msg in
            msg.parts.contains { $0.kind == .tool }
        }
        XCTAssertGreaterThan(toolMessages.count, 0, "混合夹具应包含工具消息")
    }

    func testFixture_100MixedMessages_streamingLast_flagSet() {
        let messages = MessageListVirtualizationFixtures.make100MixedMessages(streamingLast: true)
        XCTAssertTrue(messages.last?.isStreaming == true, "streamingLast=true 时最后一条应处于流式状态")
    }

    func testFixture_100MixedMessages_streamingLast_forceFullRender() {
        // 流式消息在窗口范围外也应完整渲染（验证 AC-004 流式输出不回退）
        let messages = MessageListVirtualizationFixtures.make100MixedMessages(streamingLast: true)
        let lastIndex = messages.count - 1
        let range = window.computeFullRenderRange(
            visibleIndices: [40, 45, 50], totalCount: messages.count
        )
        // index=99 在 range 外（可见在中部），但 isStreaming=true 应完整渲染
        XCTAssertTrue(
            window.shouldFullyRender(
                index: lastIndex, isStreaming: true, fullRenderRange: range, totalCount: messages.count
            ),
            "流式尾部消息即使在渲染窗口外也应强制完整渲染"
        )
    }

    // MARK: - 内存性能基准（XCTest measure）

    func testPerformance_100Messages_computeRenderDecisions() {
        let total = 100
        let visibleIndices = MessageListVirtualizationFixtures.bottomVisibleIndices(
            total: total, visibleCount: 10
        )

        measure {
            // 模拟一帧内对 100 条消息的完整渲染决策计算
            let range = window.computeFullRenderRange(
                visibleIndices: visibleIndices, totalCount: total
            )
            var fullCount = 0
            for i in 0..<total {
                if window.shouldFullyRender(
                    index: i, isStreaming: false, fullRenderRange: range, totalCount: total
                ) {
                    fullCount += 1
                }
            }
            // 防止编译器优化消除计算
            _ = fullCount
        }
    }

    func testPerformance_100MixedMessages_buildAndClassify() {
        measure {
            let messages = MessageListVirtualizationFixtures.make100MixedMessages()
            let visibleIndices = MessageListVirtualizationFixtures.bottomVisibleIndices(
                total: messages.count, visibleCount: 10
            )
            let range = window.computeFullRenderRange(
                visibleIndices: visibleIndices, totalCount: messages.count
            )
            var fullCount = 0
            for (i, msg) in messages.enumerated() {
                if window.shouldFullyRender(
                    index: i, isStreaming: msg.isStreaming, fullRenderRange: range, totalCount: messages.count
                ) {
                    fullCount += 1
                }
            }
            _ = fullCount
        }
    }
}

// MARK: - 快速滚动性能测试（CHK-004）
// 验证虚拟化窗口在高频滚动更新场景下的计算性能，
// 确保 AC-003（60fps 近似验证）有可执行的阈值约束。

final class MessageListVirtualizationScrollPerformanceTests: XCTestCase {

    private let window = MessageVirtualizationWindow()

    // MARK: - 单帧计算时间约束（60fps = 16ms/帧）

    func testSingleFrame_100Messages_windowComputationUnder16ms() {
        // 单次窗口计算（含 100 条消息的决策循环）应在 16ms 内完成
        let total = 100
        let visibleIndices = MessageListVirtualizationFixtures.middleVisibleIndices(
            total: total, center: 50, visibleCount: 10
        )

        let start = Date()
        let range = window.computeFullRenderRange(visibleIndices: visibleIndices, totalCount: total)
        for i in 0..<total {
            _ = window.shouldFullyRender(
                index: i, isStreaming: false, fullRenderRange: range, totalCount: total
            )
        }
        let elapsed = Date().timeIntervalSince(start) * 1000 // ms

        XCTAssertLessThan(
            elapsed, 16.0,
            "单帧（100 条消息）窗口计算耗时应 < 16ms（60fps 预算），实际 \(String(format: "%.3fms", elapsed))"
        )
    }

    func testSingleFrame_1000Messages_windowComputationUnder16ms() {
        // 超长会话（1000 条消息）的单帧计算仍应满足 60fps 预算
        let total = 1000
        let visibleIndices = MessageListVirtualizationFixtures.bottomVisibleIndices(
            total: total, visibleCount: 10
        )

        let start = Date()
        let range = window.computeFullRenderRange(visibleIndices: visibleIndices, totalCount: total)
        for i in 0..<total {
            _ = window.shouldFullyRender(
                index: i, isStreaming: false, fullRenderRange: range, totalCount: total
            )
        }
        let elapsed = Date().timeIntervalSince(start) * 1000

        XCTAssertLessThan(
            elapsed, 16.0,
            "1000 条消息单帧计算耗时应 < 16ms，实际 \(String(format: "%.3fms", elapsed))"
        )
    }

    // MARK: - 快速滚动序列性能（AC-003）

    func testRapidScroll_100Messages_100Steps_allFramesInBudget() {
        // 100 步快速滚动（从顶部到底部），每步计算一次完整渲染决策
        // 每步耗时应 < 16ms
        let total = 100
        let scrollSequence = MessageListVirtualizationFixtures.rapidScrollSequence(
            total: total, visibleCount: 10, steps: 100
        )
        XCTAssertGreaterThan(scrollSequence.count, 0, "快速滚动序列不能为空")

        var maxElapsed: Double = 0
        for visibleIndices in scrollSequence {
            let start = Date()
            let range = window.computeFullRenderRange(
                visibleIndices: visibleIndices, totalCount: total
            )
            for i in 0..<total {
                _ = window.shouldFullyRender(
                    index: i, isStreaming: false, fullRenderRange: range, totalCount: total
                )
            }
            let elapsed = Date().timeIntervalSince(start) * 1000
            maxElapsed = max(maxElapsed, elapsed)
        }

        XCTAssertLessThan(
            maxElapsed, 16.0,
            "100 步快速滚动中最慢帧耗时应 < 16ms，实际最慢帧 \(String(format: "%.3fms", maxElapsed))"
        )
    }

    func testRapidScroll_rollbackSafety_windowStateIsStateless() {
        // 验证 MessageVirtualizationWindow 无状态性：快速滚动后再回顶部，决策结果与首次一致
        let total = 100
        let topIndices = Array(0...9)
        let bottomIndices = MessageListVirtualizationFixtures.bottomVisibleIndices(total: total, visibleCount: 10)

        let rangeTop1 = window.computeFullRenderRange(visibleIndices: topIndices, totalCount: total)
        // 模拟快速滚动到底部再回来
        _ = window.computeFullRenderRange(visibleIndices: bottomIndices, totalCount: total)
        let rangeTop2 = window.computeFullRenderRange(visibleIndices: topIndices, totalCount: total)

        XCTAssertEqual(rangeTop1, rangeTop2, "窗口模型应无状态：相同输入必须产生相同输出")
    }

    // MARK: - 快速滚动性能基准（XCTest measure）

    func testPerformance_rapidScroll_100Messages_100Steps() {
        let total = 100
        let scrollSequence = MessageListVirtualizationFixtures.rapidScrollSequence(
            total: total, visibleCount: 10, steps: 100
        )

        measure {
            for visibleIndices in scrollSequence {
                let range = window.computeFullRenderRange(
                    visibleIndices: visibleIndices, totalCount: total
                )
                var count = 0
                for i in 0..<total {
                    if window.shouldFullyRender(
                        index: i, isStreaming: false, fullRenderRange: range, totalCount: total
                    ) { count += 1 }
                }
                _ = count
            }
        }
    }

    func testPerformance_warmStartFallback_100Messages_1000Iterations() {
        // warm start 路径（visibleIndices 为空）的性能基准
        measure {
            for _ in 0..<1000 {
                let range = window.computeFullRenderRange(visibleIndices: [], totalCount: 100)
                XCTAssertNil(range)
                _ = window.warmStartRange(totalCount: 100)
            }
        }
    }

    // MARK: - 可见窗口缩减量化（验证非全量渲染）

    func testScrolledToBottom_renderWindowIsSubset_notFullList() {
        // 快速滚动到底部后，完整渲染集应明显小于总量
        let total = 100
        let visibleIndices = MessageListVirtualizationFixtures.bottomVisibleIndices(
            total: total, visibleCount: 10
        )
        let renderCount = MessageListVirtualizationFixtures.fullRenderCount(
            window: window, visibleIndices: visibleIndices, totalCount: total
        )

        XCTAssertLessThan(renderCount, total, "完整渲染集（\(renderCount)）必须小于总消息数（\(total)）")
    }

    func testScrolledToTop_renderWindowIsSubset_notFullList() {
        let total = 100
        let visibleIndices = Array(0..<10)
        let renderCount = MessageListVirtualizationFixtures.fullRenderCount(
            window: window, visibleIndices: visibleIndices, totalCount: total
        )

        XCTAssertLessThan(renderCount, total, "滚动到顶部时完整渲染集（\(renderCount)）应小于总消息数（\(total)）")
    }
}
