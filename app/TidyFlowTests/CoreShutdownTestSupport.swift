import XCTest

#if os(macOS)
import Combine
@testable import TidyFlow

extension XCTestCase {
    /// 统一收尾 AppState，确保 Core 完成优雅关闭后再结束测试，避免下一个用例叠加启动新 Core。
    func tearDownAppState(
        _ appState: AppState,
        timeout: TimeInterval = AppConfig.shutdownTimeout + 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        runOnMainThread {
            appState.wsClient.disconnect()
        }

        let manager = appState.coreProcessManager
        guard !isCoreFullyStopped(manager) else { return }

        let stopped = expectation(description: "等待 Core 优雅关闭")
        stopped.assertForOverFulfill = false

        var cancellable: AnyCancellable?
        var fulfilled = false

        func fulfillIfNeeded() {
            guard !fulfilled else { return }
            fulfilled = true
            stopped.fulfill()
        }

        runOnMainThread {
            cancellable = manager.$status.sink { status in
                if case .stopped = status, !manager.isRunning {
                    fulfillIfNeeded()
                }
            }

            manager.stop()

            if isCoreFullyStopped(manager) {
                fulfillIfNeeded()
            }
        }

        let result = XCTWaiter.wait(for: [stopped], timeout: timeout)
        cancellable?.cancel()

        XCTAssertEqual(
            result,
            .completed,
            "Core 未在 \(timeout)s 内完成关闭，当前状态：\(coreShutdownDebugDescription(manager))",
            file: file,
            line: line
        )
    }

    private func runOnMainThread(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func isCoreFullyStopped(_ manager: CoreProcessManager) -> Bool {
        if case .stopped = manager.status {
            return !manager.isRunning
        }
        return false
    }

    private func coreShutdownDebugDescription(_ manager: CoreProcessManager) -> String {
        "\(manager.status.displayText), isRunning=\(manager.isRunning)"
    }
}
#endif
