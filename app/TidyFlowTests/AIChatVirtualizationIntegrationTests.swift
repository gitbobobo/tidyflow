import XCTest
@testable import TidyFlow

// MARK: - AI 聊天虚拟化集成回归测试
// 验证虚拟化窗口模型在普通聊天、子代理会话、回放场景中的配置一致性，
// 以及 ChatScrollPolicy 与 MessageVirtualizationWindow 的参数对齐。

final class AIChatVirtualizationIntegrationTests: XCTestCase {

    // MARK: - 配置一致性：虚拟化缓冲区与滚动策略对齐

    func testBufferCount_virtualizationWindowMatchesScrollConfig() {
        let window = MessageVirtualizationWindow()
        let config = ChatScrollPlatformConfiguration.shared
        XCTAssertEqual(
            window.bufferCount,
            config.renderBufferCount,
            "MessageVirtualizationWindow.bufferCount 必须与 ChatScrollPlatformConfiguration.renderBufferCount 保持一致，" +
            "确保虚拟化范围与滚动策略预热范围协调"
        )
    }

    func testBufferCount_virtualizationWindowMatchesDefaultScrollConfiguration() {
        let window = MessageVirtualizationWindow()
        let config = ChatScrollConfiguration()
        XCTAssertEqual(window.bufferCount, config.renderBufferCount)
    }

    // MARK: - 渲染决策链：主聊天场景（AITabView.messageArea）

    func testMainChatScenario_nearBottomFullRender() {
        // 模拟主聊天：100 条消息，用户在底部（可见 85-99）
        let window = MessageVirtualizationWindow()
        let visibleIndices = Array(85...99)
        let range = window.computeFullRenderRange(visibleIndices: visibleIndices, totalCount: 100)

        // 底部消息应完整渲染
        XCTAssertTrue(window.shouldFullyRender(
            index: 99, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
        // 底部缓冲区内的消息也应完整渲染
        XCTAssertTrue(window.shouldFullyRender(
            index: 73, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }

    func testMainChatScenario_streamingTailAlwaysFullRender() {
        // 流式输出阶段：最新消息处于流式状态，无论可见索引如何都应完整渲染
        let window = MessageVirtualizationWindow()
        let range = window.computeFullRenderRange(visibleIndices: [98, 99], totalCount: 100)
        XCTAssertTrue(window.shouldFullyRender(
            index: 99, isStreaming: true, fullRenderRange: range, totalCount: 100
        ))
    }

    func testMainChatScenario_longSessionHeadIsLightweight() {
        // 长会话（100 条消息）用户在底部时，头部消息应轻量渲染（降低内存占用）
        let window = MessageVirtualizationWindow()
        let range = window.computeFullRenderRange(visibleIndices: Array(85...99), totalCount: 100)
        XCTAssertFalse(window.shouldFullyRender(
            index: 0, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }

    // MARK: - 子代理会话场景（AITabView sheet 中的 MessageListView）

    func testSubAgentScenario_sameWindowModelApplies() {
        // 子代理会话使用与主聊天相同的 MessageListView，参数语义一致
        let window = MessageVirtualizationWindow()
        let messages = 30

        // 子会话消息少（30 条），warm start 应覆盖全部
        let warmStart = window.warmStartRange(totalCount: messages)
        XCTAssertEqual(warmStart?.lowerBound, 0, "少量消息时 warm start 应覆盖全部")
        XCTAssertEqual(warmStart?.upperBound, 29)
    }

    func testSubAgentScenario_allMessagesFullRenderWithSmallList() {
        // 30 条子代理消息，所有消息都应通过 warm start 完整渲染
        let window = MessageVirtualizationWindow()
        let total = 30
        let range: ClosedRange<Int>? = nil // 初始无可见索引

        for i in 0..<total {
            XCTAssertTrue(
                window.shouldFullyRender(index: i, isStreaming: false, fullRenderRange: range, totalCount: total),
                "子代理少量消息（\(i)/\(total)）应全部完整渲染"
            )
        }
    }

    // MARK: - 回放场景（TabContentHostView 中的 evolutionReplayStore）

    func testReplayScenario_sameWindowModelApplies() {
        // 回放场景使用相同的 MessageListView，虚拟化行为一致
        let window = MessageVirtualizationWindow()

        // 回放场景通常消息较少，warm start 覆盖
        let result = window.computeFullRenderRange(visibleIndices: [], totalCount: 20)
        XCTAssertNil(result, "回放初始无可见消息时返回 nil，走 warm start")

        let warmStart = window.warmStartRange(totalCount: 20)
        XCTAssertEqual(warmStart?.lowerBound, 0)
        XCTAssertEqual(warmStart?.upperBound, 19)
    }

    // MARK: - 工作区切换后的会话重载：warm start 保证尾部可见

    func testWorkspaceSwitchReload_warmStartCoversLastMessages() {
        let window = MessageVirtualizationWindow(bufferCount: 12, warmStartMultiplier: 3)
        // 工作区切换后，新会话数据加载，visibleIDs 清空
        // 假设会话有 80 条历史消息，应预热尾部 36 条
        let total = 80
        let warmStart = window.warmStartRange(totalCount: total)
        XCTAssertEqual(warmStart?.lowerBound, 44, "80 条消息的 warm start 下界应为 44（80-36=44）")
        XCTAssertEqual(warmStart?.upperBound, 79)

        // 尾部消息通过 shouldFullyRender 检查
        XCTAssertTrue(window.shouldFullyRender(
            index: 79, isStreaming: false, fullRenderRange: nil, totalCount: total
        ))
        XCTAssertTrue(window.shouldFullyRender(
            index: 44, isStreaming: false, fullRenderRange: nil, totalCount: total
        ))
        XCTAssertFalse(window.shouldFullyRender(
            index: 43, isStreaming: false, fullRenderRange: nil, totalCount: total
        ))
    }

    // MARK: - 加载更早消息场景：加载后窗口范围仍正确

    func testLoadOlderMessages_rangeRemainedCorrectAfterPrepend() {
        let window = MessageVirtualizationWindow(bufferCount: 12)

        // 加载更早消息前：50 条，可见 40-49
        let rangeBefore = window.computeFullRenderRange(visibleIndices: [40, 45, 49], totalCount: 50)

        // 加载后消息总数变为 80，原来可见的消息索引向后移动了 30（新消息插入头部）
        // 调用方需要用新索引重新计算，这里验证模型层行为不变
        let rangeAfter = window.computeFullRenderRange(visibleIndices: [70, 75, 79], totalCount: 80)

        XCTAssertNotNil(rangeBefore)
        XCTAssertNotNil(rangeAfter)
        XCTAssertEqual(rangeAfter?.lowerBound, 58, "加载后下界应正确计算")
        XCTAssertEqual(rangeAfter?.upperBound, 79)
    }

    // MARK: - 工具卡片交互不受虚拟化影响

    func testToolCardMessage_insideWindow_alwaysFullRender() {
        // 工具卡片消息在渲染窗口内时应完整渲染（保证交互可用）
        let window = MessageVirtualizationWindow(bufferCount: 12)
        let range = window.computeFullRenderRange(visibleIndices: [90, 95, 99], totalCount: 100)

        // 工具卡片在底部附近（index=90）应完整渲染
        XCTAssertTrue(window.shouldFullyRender(
            index: 90, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }

    func testToolCardMessage_outsideWindow_lightweightPlaceholder() {
        // 工具卡片消息在渲染窗口外时降级为轻量占位（摘要显示工具名称）
        let window = MessageVirtualizationWindow(bufferCount: 12)
        let range = window.computeFullRenderRange(visibleIndices: [90, 95, 99], totalCount: 100)

        // index=0 在窗口外，轻量渲染
        XCTAssertFalse(window.shouldFullyRender(
            index: 0, isStreaming: false, fullRenderRange: range, totalCount: 100
        ))
    }
}
