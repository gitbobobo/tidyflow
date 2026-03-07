import XCTest
@testable import TidyFlow

/// 验证共享工作区任务存储（WorkspaceTaskStore）的队列状态机语义：
/// 活跃/完成分离、多工作区隔离、阻塞队列调度规则、未读完成标记、历史裁剪、取消清理。
final class WorkspaceTaskQueueSemanticsTests: XCTestCase {

    var store: WorkspaceTaskStore!

    override func setUp() {
        super.setUp()
        store = WorkspaceTaskStore(maxCompletedPerWorkspace: 3)
    }

    // MARK: - 基本插入与查询

    func testUpsertAndQuery() {
        let item = makeItem(key: "proj:ws1", status: .running)
        store.upsert(item)

        XCTAssertEqual(store.activeTasks(for: "proj:ws1").count, 1)
        XCTAssertEqual(store.completedTasks(for: "proj:ws1").count, 0)
    }

    func testUpsertUpdatesExisting() {
        var item = makeItem(key: "proj:ws1", status: .running)
        store.upsert(item)

        item.status = .completed
        item.completedAt = Date()
        store.upsert(item)

        XCTAssertEqual(store.activeTasks(for: "proj:ws1").count, 0)
        XCTAssertEqual(store.completedTasks(for: "proj:ws1").count, 1)
    }

    // MARK: - 多工作区隔离

    func testMultipleWorkspacesIsolated() {
        let item1 = makeItem(key: "proj:ws1", status: .running)
        let item2 = makeItem(key: "proj:ws2", status: .running)
        store.upsert(item1)
        store.upsert(item2)

        XCTAssertEqual(store.activeTasks(for: "proj:ws1").count, 1)
        XCTAssertEqual(store.activeTasks(for: "proj:ws2").count, 1)
        XCTAssertEqual(store.activeTasks(for: "proj:ws3").count, 0)
    }

    func testTaskIDsNotCrossContaminated() {
        let id = UUID().uuidString
        let item1 = makeItem(id: id, key: "proj:ws1", status: .running)
        let item2 = makeItem(key: "proj:ws2", status: .running)
        store.upsert(item1)
        store.upsert(item2)

        // ws2 不应包含 ws1 的任务 id
        XCTAssertFalse(store.allTasks(for: "proj:ws2").contains { $0.id == id })
    }

    func testMultiProjectIsolation() {
        let item1 = makeItem(project: "projA", workspace: "default", status: .running)
        let item2 = makeItem(project: "projB", workspace: "default", status: .running)
        store.upsert(item1)
        store.upsert(item2)

        XCTAssertEqual(store.activeTasks(for: "projA:default").count, 1)
        XCTAssertEqual(store.activeTasks(for: "projB:default").count, 1)
    }

    // MARK: - 活跃与完成分离

    func testActiveCountExcludesTerminal() {
        store.upsert(makeItem(key: "proj:ws1", status: .running))
        store.upsert(makeItem(key: "proj:ws1", status: .pending))
        store.upsert(makeItem(key: "proj:ws1", status: .completed))
        store.upsert(makeItem(key: "proj:ws1", status: .failed))

        XCTAssertEqual(store.activeCount(for: "proj:ws1"), 2)
        XCTAssertEqual(store.completedTasks(for: "proj:ws1").count, 2)
    }

    // MARK: - 排序规则

    func testActiveTasksSortedRunningBeforePending() {
        let pending = makeItem(key: "proj:ws1", status: .pending)
        let running = makeItem(key: "proj:ws1", status: .running)
        store.upsert(pending)
        store.upsert(running)

        let active = store.activeTasks(for: "proj:ws1")
        XCTAssertEqual(active.first?.status, .running)
        XCTAssertEqual(active.last?.status, .pending)
    }

    func testCompletedTasksSortedNewestFirst() {
        let older = makeItem(key: "proj:ws1", status: .completed,
                             completedAt: Date().addingTimeInterval(-100))
        let newer = makeItem(key: "proj:ws1", status: .completed,
                             completedAt: Date().addingTimeInterval(-10))
        store.upsert(older)
        store.upsert(newer)

        let completed = store.completedTasks(for: "proj:ws1")
        XCTAssertEqual(completed.first?.id, newer.id)
    }

    // MARK: - 历史裁剪（maxCompletedPerWorkspace = 3）

    func testTrimCompletedKeepsMax() {
        for _ in 0..<5 {
            store.upsert(makeItem(key: "proj:ws1", status: .completed, completedAt: Date()))
        }
        store.trimCompleted(for: "proj:ws1")

        XCTAssertEqual(store.completedTasks(for: "proj:ws1").count, 3)
    }

    func testTrimCompletedPreservesActive() {
        store.upsert(makeItem(key: "proj:ws1", status: .running))
        for _ in 0..<5 {
            store.upsert(makeItem(key: "proj:ws1", status: .completed, completedAt: Date()))
        }
        store.trimCompleted(for: "proj:ws1")

        XCTAssertEqual(store.activeCount(for: "proj:ws1"), 1)
        XCTAssertEqual(store.completedTasks(for: "proj:ws1").count, 3)
    }

    // MARK: - 取消清理

    func testRemoveById() {
        let item = makeItem(key: "proj:ws1", status: .pending)
        store.upsert(item)
        XCTAssertEqual(store.allTasks(for: "proj:ws1").count, 1)

        store.remove(id: item.id)
        XCTAssertEqual(store.allTasks(for: "proj:ws1").count, 0)
    }

    func testRemoveNonexistentIdIsSafe() {
        store.remove(id: UUID().uuidString) // should not crash
    }

    func testClearCompleted() {
        store.upsert(makeItem(key: "proj:ws1", status: .running))
        store.upsert(makeItem(key: "proj:ws1", status: .completed))
        store.upsert(makeItem(key: "proj:ws1", status: .failed))
        store.clearCompleted(for: "proj:ws1")

        XCTAssertEqual(store.activeCount(for: "proj:ws1"), 1)
        XCTAssertEqual(store.completedTasks(for: "proj:ws1").count, 0)
    }

    // MARK: - 未读完成标记

    func testUnseenMarkedWhenCompletedInOtherWorkspace() {
        var item = makeItem(key: "proj:ws1", status: .running)
        store.upsert(item)

        item.status = .completed
        item.completedAt = Date()
        store.upsert(item, currentWorkspaceKey: "proj:ws2") // 当前在 ws2，ws1 完成 → 标记未读

        XCTAssertTrue(store.unseenCompletionKeys.contains("proj:ws1"))
    }

    func testUnseenNotMarkedWhenCompletedInCurrentWorkspace() {
        var item = makeItem(key: "proj:ws1", status: .running)
        store.upsert(item)

        item.status = .completed
        item.completedAt = Date()
        store.upsert(item, currentWorkspaceKey: "proj:ws1") // 当前就在 ws1 → 不标记未读

        XCTAssertFalse(store.unseenCompletionKeys.contains("proj:ws1"))
    }

    func testMarkSeenClearsUnseen() {
        var item = makeItem(key: "proj:ws1", status: .running)
        store.upsert(item)
        item.status = .completed
        item.completedAt = Date()
        store.upsert(item, currentWorkspaceKey: "proj:ws2")

        XCTAssertTrue(store.unseenCompletionKeys.contains("proj:ws1"))
        store.markSeen(for: "proj:ws1")
        XCTAssertFalse(store.unseenCompletionKeys.contains("proj:ws1"))
    }

    // MARK: - 侧边栏活动图标

    func testSidebarIconNilWhenNoActiveTasks() {
        XCTAssertNil(store.sidebarActiveIconName(for: "proj:ws1"))
    }

    func testSidebarIconReturnsRunningFirst() {
        store.upsert(makeItem(key: "proj:ws1", status: .running, iconName: "sparkles"))
        store.upsert(makeItem(key: "proj:ws1", status: .pending, iconName: "terminal"))

        let icon = store.sidebarActiveIconName(for: "proj:ws1")
        XCTAssertEqual(icon, "sparkles")
    }

    func testSidebarIconReturnsPendingWhenNoRunning() {
        store.upsert(makeItem(key: "proj:ws1", status: .pending, iconName: "terminal"))

        let icon = store.sidebarActiveIconName(for: "proj:ws1")
        XCTAssertEqual(icon, "terminal")
    }

    // MARK: - replaceAll

    func testReplaceAllReplacesCorrectWorkspace() {
        store.upsert(makeItem(key: "proj:ws1", status: .running))
        store.upsert(makeItem(key: "proj:ws2", status: .running))

        let newItems = [makeItem(key: "proj:ws1", status: .completed)]
        store.replaceAll(for: "proj:ws1", with: newItems)

        XCTAssertEqual(store.allTasks(for: "proj:ws1").count, 1)
        XCTAssertEqual(store.allTasks(for: "proj:ws2").count, 1) // ws2 不受影响
    }

    // MARK: - 辅助

    private func makeItem(
        id: String = UUID().uuidString,
        project: String = "proj",
        workspace: String = "ws1",
        key: String? = nil,
        status: WorkspaceTaskStatus,
        iconName: String = "sparkles",
        completedAt: Date? = nil
    ) -> WorkspaceTaskItem {
        let resolvedKey = key ?? "\(project):\(workspace)"
        let parts = resolvedKey.split(separator: ":", maxSplits: 1)
        let p = parts.count >= 1 ? String(parts[0]) : project
        let w = parts.count >= 2 ? String(parts[1]) : workspace
        return WorkspaceTaskItem(
            id: id,
            project: p,
            workspace: w,
            workspaceGlobalKey: resolvedKey,
            type: .aiCommit,
            title: "测试任务",
            iconName: iconName,
            status: status,
            message: "",
            createdAt: Date(),
            startedAt: status == .running ? Date() : nil,
            completedAt: completedAt
        )
    }
}
