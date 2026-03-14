import XCTest
@testable import TidyFlowShared

// MARK: - 测试辅助类型

/// 同步调度器 — 测试中立即执行，无需等待异步调度
private struct SynchronousDispatcher: MainThreadMessageDispatching {
    func dispatch(_ work: @escaping @MainActor () -> Void) {
        MainActor.assumeIsolated { work() }
    }
}

/// 模拟目标对象，用于验证共享适配器的弱引用持有与回调转发
private class MockTarget {
    var lastReceivedMessage: String?
    var callCount = 0

    func handleMessage(_ message: String) {
        lastReceivedMessage = message
        callCount += 1
    }
}

/// 继承 WeakTargetMessageAdapter 的具体适配器，模拟领域适配器
private final class MockAdapter: WeakTargetMessageAdapter<MockTarget> {
    func simulateMessage(_ message: String) {
        dispatchToTarget { $0.handleMessage(message) }
    }
}

// MARK: - WeakTargetMessageAdapter 测试

final class WeakTargetMessageAdapterTests: XCTestCase {

    // MARK: - 基础功能

    func testDispatchToTargetForwardsToLiveTarget() {
        let target = MockTarget()
        let adapter = MockAdapter(target: target, dispatcher: SynchronousDispatcher())

        adapter.simulateMessage("hello")

        XCTAssertEqual(target.lastReceivedMessage, "hello")
        XCTAssertEqual(target.callCount, 1)
    }

    func testDispatchToTargetSilentlyDiscardsWhenTargetReleased() {
        var target: MockTarget? = MockTarget()
        let adapter = MockAdapter(target: target!, dispatcher: SynchronousDispatcher())

        // 释放目标对象
        target = nil

        // 消息到达时不应崩溃
        adapter.simulateMessage("should be discarded")

        // adapter 的 target 已为 nil
        XCTAssertNil(adapter.target)
    }

    func testMultipleDispatchesAccumulate() {
        let target = MockTarget()
        let adapter = MockAdapter(target: target, dispatcher: SynchronousDispatcher())

        adapter.simulateMessage("first")
        adapter.simulateMessage("second")
        adapter.simulateMessage("third")

        XCTAssertEqual(target.callCount, 3)
        XCTAssertEqual(target.lastReceivedMessage, "third")
    }

    func testWeakReferenceDoesNotPreventDeallocation() {
        var target: MockTarget? = MockTarget()
        weak var weakTarget = target
        let adapter = MockAdapter(target: target!, dispatcher: SynchronousDispatcher())

        // adapter 持有 weak reference，不应阻止 target 释放
        target = nil
        XCTAssertNil(weakTarget)
        XCTAssertNil(adapter.target)
    }

    // MARK: - 主线程调度语义

    func testDefaultDispatcherUsesMainThread() {
        let expectation = self.expectation(description: "dispatched on main thread")
        let target = MockTarget()
        // 使用默认调度器（DefaultMainThreadDispatcher）
        let adapter = MockAdapter(target: target)

        adapter.dispatchToTarget { target in
            XCTAssertTrue(Thread.isMainThread)
            target.handleMessage("from main")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
        XCTAssertEqual(target.lastReceivedMessage, "from main")
    }

    func testDefaultDispatcherDiscardsAfterTargetRelease() {
        let expectation = self.expectation(description: "dispatch completes without crash")
        var target: MockTarget? = MockTarget()
        let adapter = MockAdapter(target: target!)

        // 释放 target
        target = nil

        // 调度应该安全完成（静默丢弃）
        adapter.dispatchToTarget { _ in
            XCTFail("不应执行到这里 — target 已释放")
        }

        // 给足够时间让 DispatchQueue.main.async 执行
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - 适配器强引用持有验证

    func testAdapterStaysAliveWhenStronglyHeld() {
        let target = MockTarget()
        var adapter: MockAdapter? = MockAdapter(target: target, dispatcher: SynchronousDispatcher())

        // 模拟 AppState/MobileAppState 强持有 adapter
        let strongRef: Any = adapter!

        adapter?.simulateMessage("via strong ref")
        XCTAssertEqual(target.callCount, 1)

        // 即使局部变量置 nil，强引用仍保持 adapter 存活
        adapter = nil
        XCTAssertNotNil(strongRef as? MockAdapter)
    }

    // MARK: - DefaultMainThreadDispatcher 独立验证

    func testDefaultMainThreadDispatcherExecutesOnMainThread() {
        let expectation = self.expectation(description: "dispatched on main thread")
        let dispatcher = DefaultMainThreadDispatcher()

        dispatcher.dispatch {
            XCTAssertTrue(Thread.isMainThread)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - SynchronousDispatcher 独立验证

    func testSynchronousDispatcherExecutesImmediately() {
        let dispatcher = SynchronousDispatcher()
        var executed = false

        dispatcher.dispatch {
            executed = true
        }

        XCTAssertTrue(executed, "同步调度器应立即执行工作")
    }
}

// MARK: - AI / Evolution 热路径领域适配器模式验证

/// 模拟 AI 领域目标，验证热路径消息能正确送达
private class MockAITarget {
    var sessionStartedCount = 0
    var lastSessionId: String?
    var chatDoneCount = 0
    var messagesUpdateCount = 0

    func handleAISessionStarted(sessionId: String) {
        sessionStartedCount += 1
        lastSessionId = sessionId
    }

    func handleAIChatDone() {
        chatDoneCount += 1
    }

    func handleAISessionMessagesUpdate() {
        messagesUpdateCount += 1
    }
}

/// 模拟 AI 适配器，验证共享骨架在高频消息路径上的行为
private final class MockAIAdapter: WeakTargetMessageAdapter<MockAITarget> {
    func simulateSessionStarted(sessionId: String) {
        dispatchToTarget { $0.handleAISessionStarted(sessionId: sessionId) }
    }

    func simulateChatDone() {
        dispatchToTarget { $0.handleAIChatDone() }
    }

    func simulateMessagesUpdate() {
        dispatchToTarget { $0.handleAISessionMessagesUpdate() }
    }
}

/// 模拟 Evolution 领域目标
private class MockEvolutionTarget {
    var snapshotCount = 0
    var cycleUpdatedCount = 0
    var errorMessages: [String] = []

    func handleEvolutionSnapshot() {
        snapshotCount += 1
    }

    func handleEvolutionCycleUpdated() {
        cycleUpdatedCount += 1
    }

    func handleEvolutionError(message: String) {
        errorMessages.append(message)
    }
}

/// 模拟 Evolution 适配器
private final class MockEvolutionAdapter: WeakTargetMessageAdapter<MockEvolutionTarget> {
    func simulateSnapshot() {
        dispatchToTarget { $0.handleEvolutionSnapshot() }
    }

    func simulateCycleUpdated() {
        dispatchToTarget { $0.handleEvolutionCycleUpdated() }
    }

    func simulateError(message: String) {
        dispatchToTarget { $0.handleEvolutionError(message: message) }
    }
}

final class MessageHandlerAdapterHotPathTests: XCTestCase {

    // MARK: - AI 热路径

    func testAIAdapterForwardsSessionStarted() {
        let target = MockAITarget()
        let adapter = MockAIAdapter(target: target, dispatcher: SynchronousDispatcher())

        adapter.simulateSessionStarted(sessionId: "session-001")

        XCTAssertEqual(target.sessionStartedCount, 1)
        XCTAssertEqual(target.lastSessionId, "session-001")
    }

    func testAIAdapterForwardsMultipleMessagesInOrder() {
        let target = MockAITarget()
        let adapter = MockAIAdapter(target: target, dispatcher: SynchronousDispatcher())

        adapter.simulateSessionStarted(sessionId: "s1")
        adapter.simulateMessagesUpdate()
        adapter.simulateMessagesUpdate()
        adapter.simulateChatDone()

        XCTAssertEqual(target.sessionStartedCount, 1)
        XCTAssertEqual(target.messagesUpdateCount, 2)
        XCTAssertEqual(target.chatDoneCount, 1)
    }

    func testAIAdapterDiscardsAfterTargetRelease() {
        var target: MockAITarget? = MockAITarget()
        let adapter = MockAIAdapter(target: target!, dispatcher: SynchronousDispatcher())

        target = nil

        // 不应崩溃
        adapter.simulateSessionStarted(sessionId: "orphan")
        adapter.simulateChatDone()
        XCTAssertNil(adapter.target)
    }

    // MARK: - Evolution 热路径

    func testEvolutionAdapterForwardsMessages() {
        let target = MockEvolutionTarget()
        let adapter = MockEvolutionAdapter(target: target, dispatcher: SynchronousDispatcher())

        adapter.simulateSnapshot()
        adapter.simulateCycleUpdated()
        adapter.simulateError(message: "test error")

        XCTAssertEqual(target.snapshotCount, 1)
        XCTAssertEqual(target.cycleUpdatedCount, 1)
        XCTAssertEqual(target.errorMessages, ["test error"])
    }

    func testEvolutionAdapterDiscardsAfterTargetRelease() {
        var target: MockEvolutionTarget? = MockEvolutionTarget()
        let adapter = MockEvolutionAdapter(target: target!, dispatcher: SynchronousDispatcher())

        target = nil

        adapter.simulateSnapshot()
        adapter.simulateError(message: "orphan error")
        XCTAssertNil(adapter.target)
    }

    // MARK: - 并发安全验证

    func testAsyncDispatchDeliversToMainThread() {
        let expectation = self.expectation(description: "AI message delivered on main thread")
        let target = MockAITarget()
        let adapter = MockAIAdapter(target: target) // 使用默认调度器

        // 从后台队列发送消息（模拟 WS 解码队列）
        DispatchQueue.global(qos: .userInitiated).async {
            adapter.simulateSessionStarted(sessionId: "bg-session")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(target.sessionStartedCount, 1)
            XCTAssertEqual(target.lastSessionId, "bg-session")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }
}
