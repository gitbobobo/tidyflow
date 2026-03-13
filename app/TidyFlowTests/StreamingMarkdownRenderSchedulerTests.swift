import XCTest
import CoreFoundation
@testable import TidyFlow

/// 覆盖 StreamingMarkdownRenderScheduler 调度决策的单元测试。
final class StreamingMarkdownRenderSchedulerTests: XCTestCase {

    private let scheduler = StreamingMarkdownRenderScheduler()

    // MARK: - 非流式场景

    func testNonStreamingRendersImmediatelyWhenTextChanged() {
        let decision = scheduler.decide(
            renderedText: "old",
            incomingText: "new",
            isStreaming: false,
            lastRenderTime: CFAbsoluteTimeGetCurrent() - 100,
            now: CFAbsoluteTimeGetCurrent()
        )
        if case .renderNow(let reason) = decision {
            XCTAssertEqual(reason, .nonStreaming)
        } else {
            XCTFail("非流式文本变化应立即渲染，got \(decision)")
        }
    }

    func testNonStreamingNoopWhenTextUnchanged() {
        let text = "same text"
        let decision = scheduler.decide(
            renderedText: text,
            incomingText: text,
            isStreaming: false,
            lastRenderTime: 0,
            now: CFAbsoluteTimeGetCurrent()
        )
        XCTAssertEqual(decision, .noop)
    }

    // MARK: - 流式场景：文本未变

    func testStreamingNoopWhenTextUnchanged() {
        let text = "unchanged"
        let decision = scheduler.decide(
            renderedText: text,
            incomingText: text,
            isStreaming: true,
            lastRenderTime: 0,
            now: CFAbsoluteTimeGetCurrent()
        )
        XCTAssertEqual(decision, .noop)
    }

    // MARK: - 流式场景：小增量（不足 minInterval）

    func testSmallIncrementWithinMinIntervalDeferRender() {
        // 距上次渲染 0.01s，增量仅 1 字符 —— 应延迟
        let now = CFAbsoluteTimeGetCurrent()
        let lastRender = now - 0.01
        let decision = scheduler.decide(
            renderedText: "hello",
            incomingText: "hello!", // 1 字符增量
            isStreaming: true,
            lastRenderTime: lastRender,
            now: now
        )
        if case .deferRender = decision {
            // 正确
        } else {
            XCTFail("小增量 + 间隔不足 minInterval 应延迟，got \(decision)")
        }
    }

    // MARK: - 流式场景：有意义增量 + 超过 minInterval

    func testMeaningfulIncrementAfterMinIntervalRendersNow() {
        let now = CFAbsoluteTimeGetCurrent()
        let lastRender = now - 0.25 // > 0.20 (minInterval for short text)
        let rendered = "Hello"
        let incoming = rendered + String(repeating: "x", count: 30) // 30 char delta
        let decision = scheduler.decide(
            renderedText: rendered,
            incomingText: incoming,
            isStreaming: true,
            lastRenderTime: lastRender,
            now: now
        )
        if case .renderNow(let reason) = decision {
            XCTAssertEqual(reason, .meaningfulIncrement)
        } else {
            XCTFail("超过 minInterval 且有意义增量应立即渲染，got \(decision)")
        }
    }

    // MARK: - 流式场景：达到 maxInterval

    func testMaxIntervalElapsedAlwaysRendersNow() {
        let now = CFAbsoluteTimeGetCurrent()
        let lastRender = now - 2.0 // 超过任何预算的 maxInterval
        let decision = scheduler.decide(
            renderedText: "short",
            incomingText: "short+", // 仅 1 字符，不是有意义增量
            isStreaming: true,
            lastRenderTime: lastRender,
            now: now
        )
        if case .renderNow(let reason) = decision {
            XCTAssertEqual(reason, .maxIntervalElapsed)
        } else {
            XCTFail("超过 maxInterval 应强制渲染，got \(decision)")
        }
    }

    // MARK: - 流式结束提交

    func testStreamEndRendersWhenTextDiffers() {
        let decision = scheduler.decideOnStreamEnd(renderedText: "partial", finalText: "partial final")
        if case .renderNow(let reason) = decision {
            XCTAssertEqual(reason, .streamEnded)
        } else {
            XCTFail("流式结束且文本未渲染应立即提交，got \(decision)")
        }
    }

    func testStreamEndNoopWhenAlreadyRendered() {
        let text = "final"
        let decision = scheduler.decideOnStreamEnd(renderedText: text, finalText: text)
        XCTAssertEqual(decision, .noop)
    }

    // MARK: - 渲染预算

    func testBudgetShortTextHasSmallInterval() {
        let budget = StreamingMarkdownRenderBudget.budget(for: String(repeating: "x", count: 100))
        XCTAssertEqual(budget.minInterval, 0.20, accuracy: 0.001)
        XCTAssertEqual(budget.maxInterval, 0.45, accuracy: 0.001)
        XCTAssertEqual(budget.minimumMeaningfulDelta, 24)
    }

    func testBudgetMediumTextHasMediumInterval() {
        let budget = StreamingMarkdownRenderBudget.budget(for: String(repeating: "x", count: 2000))
        XCTAssertEqual(budget.minInterval, 0.30, accuracy: 0.001)
        XCTAssertEqual(budget.maxInterval, 0.75, accuracy: 0.001)
        XCTAssertEqual(budget.minimumMeaningfulDelta, 64)
    }

    func testBudgetLongTextHasLargeInterval() {
        let budget = StreamingMarkdownRenderBudget.budget(for: String(repeating: "x", count: 5000))
        XCTAssertEqual(budget.minInterval, 0.50, accuracy: 0.001)
        XCTAssertEqual(budget.maxInterval, 1.20, accuracy: 0.001)
        XCTAssertEqual(budget.minimumMeaningfulDelta, 120)
    }

    // MARK: - 有意义增量检测

    func testHasMeaningfulIncrementSameTextIsFalse() {
        XCTAssertFalse(StreamingMarkdownRenderScheduler.hasMeaningfulIncrement(renderedText: "abc", newText: "abc"))
    }

    func testHasMeaningfulIncrementShorterTextIsTrue() {
        XCTAssertTrue(StreamingMarkdownRenderScheduler.hasMeaningfulIncrement(renderedText: "abcdef", newText: "abc"))
    }

    func testHasMeaningfulIncrementLargeChunkIsTrue() {
        let rendered = "Hello"
        let incoming = rendered + String(repeating: "a", count: 30)
        XCTAssertTrue(StreamingMarkdownRenderScheduler.hasMeaningfulIncrement(renderedText: rendered, newText: incoming))
    }

    func testHasMeaningfulIncrementNewlineIsTrue() {
        XCTAssertTrue(StreamingMarkdownRenderScheduler.hasMeaningfulIncrement(renderedText: "hello", newText: "hello\n"))
    }

    func testHasMeaningfulIncrementSmallChunkIsFalse() {
        let rendered = "Hello"
        let incoming = rendered + "!"
        XCTAssertFalse(StreamingMarkdownRenderScheduler.hasMeaningfulIncrement(renderedText: rendered, newText: incoming))
    }
}
