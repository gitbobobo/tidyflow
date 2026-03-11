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
}
