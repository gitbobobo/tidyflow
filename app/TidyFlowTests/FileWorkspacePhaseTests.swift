import XCTest
@testable import TidyFlow
@testable import TidyFlowShared

/// 验证文件工作区相位（FileWorkspacePhase）的语义正确性：
/// 枚举变体、辅助属性、FileChangeKind 解析规则。
/// 与 Core 的 `FileWorkspacePhase` / `FileChangeKind` 契约保持对齐。
final class FileWorkspacePhaseTests: XCTestCase {

    // MARK: - FileWorkspacePhase 基本语义

    func testAllVariantsExist() {
        let variants: [FileWorkspacePhase] = [.idle, .indexing, .watching, .degraded, .error, .recovering]
        XCTAssertEqual(variants.count, 6, "FileWorkspacePhase 应有 6 个变体")
    }

    func testRawValueRoundtrip() {
        let variants: [(String, FileWorkspacePhase)] = [
            ("idle", .idle),
            ("indexing", .indexing),
            ("watching", .watching),
            ("degraded", .degraded),
            ("error", .error),
            ("recovering", .recovering),
        ]
        for (raw, expected) in variants {
            XCTAssertEqual(FileWorkspacePhase(rawValue: raw), expected, "\(raw) 应解析为 \(expected)")
            XCTAssertEqual(expected.rawValue, raw, "\(expected) 的 rawValue 应为 \(raw)")
        }
    }

    func testUnknownRawValueReturnsNil() {
        XCTAssertNil(FileWorkspacePhase(rawValue: "unknown"))
        XCTAssertNil(FileWorkspacePhase(rawValue: ""))
    }

    // MARK: - allowsWrite

    func testErrorPhaseBlocksWrite() {
        XCTAssertFalse(FileWorkspacePhase.error.allowsWrite)
    }

    func testNonErrorPhasesAllowWrite() {
        let nonError: [FileWorkspacePhase] = [.idle, .indexing, .watching, .degraded, .recovering]
        for phase in nonError {
            XCTAssertTrue(phase.allowsWrite, "\(phase) 应允许写操作")
        }
    }

    // MARK: - isReady

    func testOnlyWatchingIsReady() {
        XCTAssertTrue(FileWorkspacePhase.watching.isReady)
        let notReady: [FileWorkspacePhase] = [.idle, .indexing, .degraded, .error, .recovering]
        for phase in notReady {
            XCTAssertFalse(phase.isReady, "\(phase) 不应处于就绪状态")
        }
    }

    // MARK: - needsAttention

    func testNeedsAttentionPhases() {
        let attention: [FileWorkspacePhase] = [.degraded, .error, .recovering]
        for phase in attention {
            XCTAssertTrue(phase.needsAttention, "\(phase) 应需要关注")
        }
        let noAttention: [FileWorkspacePhase] = [.idle, .indexing, .watching]
        for phase in noAttention {
            XCTAssertFalse(phase.needsAttention, "\(phase) 不应需要关注")
        }
    }

    // MARK: - FileChangeKind 基本语义

    func testFileChangeKindAllVariants() {
        let variants: [FileChangeKind] = [.created, .modified, .removed, .renamed]
        XCTAssertEqual(variants.count, 4)
    }

    func testFileChangeKindRawStringAliases() {
        // 标准值
        XCTAssertEqual(FileChangeKind(rawString: "created"), .created)
        XCTAssertEqual(FileChangeKind(rawString: "modified"), .modified)
        XCTAssertEqual(FileChangeKind(rawString: "removed"), .removed)
        XCTAssertEqual(FileChangeKind(rawString: "renamed"), .renamed)

        // 别名（与 Core watcher 输出兼容）
        XCTAssertEqual(FileChangeKind(rawString: "create"), .created)
        XCTAssertEqual(FileChangeKind(rawString: "deleted"), .removed)
        XCTAssertEqual(FileChangeKind(rawString: "delete"), .removed)
        XCTAssertEqual(FileChangeKind(rawString: "remove"), .removed)
        XCTAssertEqual(FileChangeKind(rawString: "rename"), .renamed)
    }

    func testFileChangeKindUnknownFallsBackToModified() {
        XCTAssertEqual(FileChangeKind(rawString: "unknown"), .modified)
        XCTAssertEqual(FileChangeKind(rawString: ""), .modified)
    }

    // MARK: - 多工作区相位隔离

    func testPhaseIsolationByGlobalKey() {
        let cache = FileCacheState()

        cache.setPhase(.watching, for: "projA:ws1")
        cache.setPhase(.indexing, for: "projB:ws1")

        XCTAssertEqual(cache.phase(for: "projA:ws1"), .watching)
        XCTAssertEqual(cache.phase(for: "projB:ws1"), .indexing)
        XCTAssertEqual(cache.phase(for: "projC:ws1"), .idle, "不存在的键应返回 idle")
    }

    func testWatchSubscribedSetsWatching() {
        let cache = FileCacheState()
        cache.onWatchSubscribed(globalKey: "proj:ws")
        XCTAssertEqual(cache.phase(for: "proj:ws"), .watching)
    }

    func testWatchUnsubscribedResetsToIdle() {
        let cache = FileCacheState()
        cache.onWatchSubscribed(globalKey: "proj:ws")
        cache.onWatchUnsubscribed(globalKey: "proj:ws")
        XCTAssertEqual(cache.phase(for: "proj:ws"), .idle)
    }

    func testResetAllPhasesOnDisconnect() {
        let cache = FileCacheState()
        cache.onWatchSubscribed(globalKey: "proj:ws1")
        cache.onWatchSubscribed(globalKey: "proj:ws2")

        cache.resetAllPhasesOnDisconnect()

        XCTAssertEqual(cache.phase(for: "proj:ws1"), .idle)
        XCTAssertEqual(cache.phase(for: "proj:ws2"), .idle)
    }

    // MARK: - 恢复路径相位迁移语义（与 Core FileWorkspacePhaseTracker.on_reconnect_recovery 对齐）

    func testRecoveryPhaseAllowsWrite() {
        // recovering 相位下仍允许写操作（与 degraded 一致，非 error）
        XCTAssertTrue(FileWorkspacePhase.recovering.allowsWrite)
        XCTAssertFalse(FileWorkspacePhase.error.allowsWrite)
    }

    func testRecoveryPhaseNeedsAttention() {
        // recovering 相位需要关注（用户可能需要等待恢复完成）
        XCTAssertTrue(FileWorkspacePhase.recovering.needsAttention)
    }

    func testRecoveringPhaseNotReady() {
        // recovering 相位未就绪，不能作为 watching 的等价状态
        XCTAssertFalse(FileWorkspacePhase.recovering.isReady)
    }

    func testDegradedToIdleTransition() {
        // 测试 degraded → idle（断连重置路径）
        let cache = FileCacheState()
        cache.setPhase(.degraded, for: "proj:ws")
        cache.resetAllPhasesOnDisconnect()
        XCTAssertEqual(cache.phase(for: "proj:ws"), .idle)
    }

    func testMultiProjectRecoveryPhaseIsolation() {
        // 验证多项目并行时恢复相位互不干扰
        let cache = FileCacheState()
        cache.setPhase(.recovering, for: "proj-a:ws")
        cache.setPhase(.watching, for: "proj-b:ws")
        cache.setPhase(.error, for: "proj-c:ws")

        // 断连只重置全部相位，不做跨项目合并
        cache.resetAllPhasesOnDisconnect()

        XCTAssertEqual(cache.phase(for: "proj-a:ws"), .idle)
        XCTAssertEqual(cache.phase(for: "proj-b:ws"), .idle)
        XCTAssertEqual(cache.phase(for: "proj-c:ws"), .idle)
    }

    func testRecoveryPhaseTransition_degradedToRecovering() {
        let cache = FileCacheState()
        cache.setPhase(.degraded, for: "proj:ws")
        // 模拟 Core 发来 recovering 相位（on_recovery_started 触发）
        cache.setPhase(.recovering, for: "proj:ws")
        XCTAssertEqual(cache.phase(for: "proj:ws"), .recovering)
    }

    func testRecoveryPhaseTransition_recoveringToWatching() {
        let cache = FileCacheState()
        cache.setPhase(.recovering, for: "proj:ws")
        // 模拟 Core on_recovery_succeeded → Watching
        cache.onWatchSubscribed(globalKey: "proj:ws")
        XCTAssertEqual(cache.phase(for: "proj:ws"), .watching)
    }

    func testRecoveryPhaseTransition_recoveringToError() {
        let cache = FileCacheState()
        cache.setPhase(.recovering, for: "proj:ws")
        // 模拟 Core on_recovery_failed → Error
        cache.setPhase(.error, for: "proj:ws")
        XCTAssertEqual(cache.phase(for: "proj:ws"), .error)
        XCTAssertFalse(cache.phase(for: "proj:ws").allowsWrite)
    }
}
