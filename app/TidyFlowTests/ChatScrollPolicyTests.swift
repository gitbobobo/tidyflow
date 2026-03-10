import XCTest
@testable import TidyFlow

// MARK: - ChatScrollPolicy 单元测试
// 覆盖计划定义的四类场景：状态机、自动跟随、手动恢复、流式增量

final class ChatScrollPolicyTests: XCTestCase {

    // MARK: - 执行闸门测试

    func testExecutionGate_allowsAutoScrollImmediatelyWhenNoManualJump() {
        var gate = ChatScrollExecutionGate()

        XCTAssertTrue(gate.consumeAutoScrollRequest(), "无手动回底时应立即执行自动贴底")
        XCTAssertFalse(gate.isManualJumpToBottomInFlight)
        XCTAssertFalse(gate.hasDeferredAutoScroll)
    }

    func testExecutionGate_defersAutoScrollDuringManualJump() {
        var gate = ChatScrollExecutionGate()
        gate.beginManualJumpToBottom()

        XCTAssertFalse(gate.consumeAutoScrollRequest(), "手动回底进行中应延后自动贴底")
        XCTAssertTrue(gate.isManualJumpToBottomInFlight)
        XCTAssertTrue(gate.hasDeferredAutoScroll)
    }

    func testExecutionGate_completesManualJumpWithSingleDeferredCorrection() {
        var gate = ChatScrollExecutionGate()
        gate.beginManualJumpToBottom()
        XCTAssertFalse(gate.consumeAutoScrollRequest())
        XCTAssertFalse(gate.consumeAutoScrollRequest(), "多个自动贴底请求在手动回底期间应继续合并")

        XCTAssertTrue(gate.completeManualJumpToBottom(), "手动回底结束后应补一次合并后的自动贴底")
        XCTAssertFalse(gate.isManualJumpToBottomInFlight)
        XCTAssertFalse(gate.hasDeferredAutoScroll)
        XCTAssertFalse(gate.completeManualJumpToBottom(), "重复结束不应再次触发补偿滚动")
    }

    // MARK: - 初始化状态测试

    func testInitialState_autoFollowTrue() {
        let policy = ChatScrollPolicy()
        XCTAssertTrue(policy.autoFollow, "初始状态应为 autoFollow=true")
        XCTAssertTrue(policy.nearBottom, "初始状态应为 nearBottom=true")
    }

    func testInitialState_customValues() {
        let policy = ChatScrollPolicy(initialAutoFollow: false, initialNearBottom: false)
        XCTAssertFalse(policy.autoFollow, "自定义初始 autoFollow=false 应生效")
        XCTAssertFalse(policy.nearBottom, "自定义初始 nearBottom=false 应生效")
    }

    // MARK: - T9 自动跟随/手动切换场景

    /// 自动跟随 -> 手动模式：用户上滑后 nearBottom=false 时切到手动
    func testAutoToManual_userScrolledUp() {
        let policy = ChatScrollPolicy()
        XCTAssertTrue(policy.autoFollow)

        let decision = policy.reduce(event: .userScrolled(nearBottom: false))

        XCTAssertFalse(policy.autoFollow, "用户上滑（nearBottom=false）应切到手动模式")
        XCTAssertFalse(policy.nearBottom)
        XCTAssertEqual(decision.action, .none, "切换手动时不应触发滚动")
    }

    /// 手动模式 -> 自动跟随：用户滚回底部时自动恢复
    func testManualToAuto_userScrolledBackToBottom() {
        let policy = ChatScrollPolicy(initialAutoFollow: false, initialNearBottom: false)

        let decision = policy.reduce(event: .userScrolled(nearBottom: true))

        XCTAssertTrue(policy.autoFollow, "用户滚回底部（nearBottom=true）应恢复自动跟随")
        XCTAssertTrue(policy.nearBottom)
        XCTAssertEqual(decision.action, .none)
    }

    /// 自动跟随保持：用户在底部附近滚动，nearBottom 仍为 true 时不切换
    func testAutoFollowMaintained_userScrolledNearBottom() {
        let policy = ChatScrollPolicy()

        let decision = policy.reduce(event: .userScrolled(nearBottom: true))

        XCTAssertTrue(policy.autoFollow, "用户在底部附近滚动时应保持自动跟随")
        XCTAssertEqual(decision.action, .none)
    }

    /// 非用户触发不应切到手动：messageAppended/Incremented 不改变 autoFollow
    func testIgnoreProgrammatic_messageAppendedKeepsAutoFollow() {
        let policy = ChatScrollPolicy()

        _ = policy.reduce(event: .messageAppended)
        XCTAssertTrue(policy.autoFollow, "messageAppended 不应改变 autoFollow")
    }

    func testIgnoreProgrammatic_messageIncrementedKeepsAutoFollow() {
        let policy = ChatScrollPolicy()

        _ = policy.reduce(event: .messageIncremented)
        XCTAssertTrue(policy.autoFollow, "messageIncremented 不应改变 autoFollow")
    }

    // MARK: - T10 回底按钮场景

    /// 回底按钮点击后恢复自动跟随并触发滚动
    func testJumpToBottom_restoresAutoFollowAndScrolls() {
        let policy = ChatScrollPolicy(initialAutoFollow: false, initialNearBottom: false)

        let decision = policy.reduce(event: .jumpToBottomClicked)

        XCTAssertTrue(policy.autoFollow, "jumpToBottomClicked 应恢复 autoFollow=true")
        XCTAssertTrue(policy.nearBottom, "jumpToBottomClicked 应设置 nearBottom=true")
        XCTAssertEqual(decision.action, .scrollToBottom, "jumpToBottomClicked 应触发滚动")
        XCTAssertTrue(decision.shouldScrollToBottom)
    }

    // MARK: - T11 流式增量场景

    /// 自动跟随模式下流式增量触发节流滚动
    func testStreamFollowWhenAuto_throttledScroll() {
        let policy = ChatScrollPolicy()

        let decision = policy.reduce(event: .messageIncremented)

        XCTAssertEqual(decision.action, .throttledScrollToBottom,
                       "autoFollow=true 时 messageIncremented 应触发节流滚动")
        XCTAssertTrue(decision.shouldScrollToBottom)
    }

    /// 手动模式下流式增量不触发滚动
    func testStreamNoFollowWhenManual_noScroll() {
        let policy = ChatScrollPolicy(initialAutoFollow: false)

        let decision = policy.reduce(event: .messageIncremented)

        XCTAssertEqual(decision.action, .none,
                       "autoFollow=false 时 messageIncremented 不应触发滚动")
        XCTAssertFalse(decision.shouldScrollToBottom)
    }

    /// 自动跟随模式下新消息追加触发滚动
    func testMessageAppended_scrollsWhenAutoFollow() {
        let policy = ChatScrollPolicy()

        let decision = policy.reduce(event: .messageAppended)

        XCTAssertEqual(decision.action, .scrollToBottom,
                       "autoFollow=true 时 messageAppended 应触发滚动")
    }

    /// 手动模式下新消息追加不触发滚动
    func testMessageAppended_noScrollWhenManual() {
        let policy = ChatScrollPolicy(initialAutoFollow: false)

        let decision = policy.reduce(event: .messageAppended)

        XCTAssertEqual(decision.action, .none,
                       "autoFollow=false 时 messageAppended 不应触发滚动")
    }

    // MARK: - 节流测试

    /// 流式增量节流：短时间内多次调用只触发一次（首次）然后静默
    func testIncrementThrottle_suppressesDuplicateScrolls() {
        let config = ChatScrollConfiguration(incrementThrottleInterval: 0.5)
        let policy = ChatScrollPolicy(configuration: config)

        let baseTime = Date()
        let first = policy.reduce(event: .messageIncremented, now: baseTime)
        // 50ms 后的第二次，在 500ms 节流窗口内
        let second = policy.reduce(event: .messageIncremented, now: baseTime.addingTimeInterval(0.05))

        XCTAssertEqual(first.action, .throttledScrollToBottom, "首次增量应触发节流滚动")
        XCTAssertEqual(second.action, .none, "节流窗口内的后续增量应被抑制")
    }

    /// 节流间隔过后恢复触发
    func testIncrementThrottle_resumesAfterInterval() {
        let config = ChatScrollConfiguration(incrementThrottleInterval: 0.1)
        let policy = ChatScrollPolicy(configuration: config)

        let baseTime = Date()
        _ = policy.reduce(event: .messageIncremented, now: baseTime)
        // 200ms 后（超过 100ms 节流窗口）
        let second = policy.reduce(event: .messageIncremented, now: baseTime.addingTimeInterval(0.2))

        XCTAssertEqual(second.action, .throttledScrollToBottom, "节流间隔后应恢复触发")
    }

    // MARK: - 会话切换场景

    func testSessionSwitched_resetsToAutoFollow() {
        let policy = ChatScrollPolicy(initialAutoFollow: false, initialNearBottom: false)

        let decision = policy.reduce(event: .sessionSwitched)

        XCTAssertTrue(policy.autoFollow, "sessionSwitched 应重置 autoFollow=true")
        XCTAssertTrue(policy.nearBottom, "sessionSwitched 应重置 nearBottom=true")
        XCTAssertEqual(decision.action, .scrollToBottom, "sessionSwitched 应触发滚动到底部")
    }

    // MARK: - 配置测试

    func testConfiguration_defaultThresholds() {
        let config = ChatScrollConfiguration()
        XCTAssertEqual(config.bottomTolerance, 36, "默认 bottomTolerance 应为 36")
        XCTAssertEqual(config.nearBottomThreshold, 36, "默认 nearBottomThreshold 应为 36")
        XCTAssertEqual(config.autoResumeThreshold, 36, "默认 autoResumeThreshold 应为 36")
        XCTAssertEqual(config.autoFollowBreakThreshold, 200, "默认 autoFollowBreakThreshold 应为 200")
        XCTAssertEqual(config.renderBufferCount, 12, "默认 renderBufferCount 应为 12")
    }

    func testPlatformConfiguration_macOSiOSSameValues() {
        let config = ChatScrollPlatformConfiguration.shared
        XCTAssertEqual(config.bottomTolerance, 36, "平台配置 bottomTolerance 应一致为 36")
        XCTAssertEqual(config.nearBottomThreshold, 36, "平台配置 nearBottomThreshold 应一致为 36")
    }

    // MARK: - Decision states 测试

    func testDecision_containsExpectedStates() {
        let policy = ChatScrollPolicy()

        let decision = policy.reduce(event: .messageAppended)

        XCTAssertTrue(decision.states.contains(.autoFollow(true)))
        XCTAssertTrue(decision.states.contains(.nearBottom(true)))
    }

    // MARK: - WS coalesce 规则测试

    func testWSCoalescibleTypes_shouldExcludeFileListAndIndexResults() {
        let client = WSClient()

        XCTAssertTrue(client.isCoalescible("file_changed"))
        XCTAssertTrue(client.isCoalescible("git_status_changed"))
        XCTAssertFalse(client.isCoalescible("file_list_result"))
        XCTAssertFalse(client.isCoalescible("file_index_result"))
    }

    func testWSCoalesceKey_shouldIncludePathToAvoidCrossPathOverwrite() {
        let client = WSClient()
        let a = WSClient.CoalescedEnvelope(
            domain: "file",
            action: "file_list_result",
            json: [
                "project": "demo",
                "workspace": "main",
                "path": "/a"
            ]
        )
        let b = WSClient.CoalescedEnvelope(
            domain: "file",
            action: "file_list_result",
            json: [
                "project": "demo",
                "workspace": "main",
                "path": "/b"
            ]
        )

        XCTAssertNotEqual(client.coalesceKey(for: a), client.coalesceKey(for: b))
    }
}
