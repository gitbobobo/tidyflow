import XCTest
@testable import TidyFlow

/// 验证共享工作区任务语义层的核心行为：
/// 状态归一化、终态判定、排序键、展示派生，以及跨端 WorkspaceTaskItem 创建。
final class WorkspaceTaskSemanticLayerTests: XCTestCase {

    // MARK: - WorkspaceTaskStatus 归一化

    func testActiveStatuses() {
        XCTAssertTrue(WorkspaceTaskStatus.pending.isActive)
        XCTAssertTrue(WorkspaceTaskStatus.running.isActive)
        XCTAssertFalse(WorkspaceTaskStatus.completed.isActive)
        XCTAssertFalse(WorkspaceTaskStatus.failed.isActive)
        XCTAssertFalse(WorkspaceTaskStatus.unknown.isActive)
        XCTAssertFalse(WorkspaceTaskStatus.cancelled.isActive)
    }

    func testTerminalStatuses() {
        XCTAssertFalse(WorkspaceTaskStatus.pending.isTerminal)
        XCTAssertFalse(WorkspaceTaskStatus.running.isTerminal)
        XCTAssertTrue(WorkspaceTaskStatus.completed.isTerminal)
        XCTAssertTrue(WorkspaceTaskStatus.failed.isTerminal)
        XCTAssertTrue(WorkspaceTaskStatus.unknown.isTerminal)
        XCTAssertTrue(WorkspaceTaskStatus.cancelled.isTerminal)
    }

    func testActiveMutuallyExclusiveWithTerminal() {
        for status in [WorkspaceTaskStatus.pending, .running, .completed, .failed, .unknown, .cancelled] {
            XCTAssertNotEqual(status.isActive, status.isTerminal,
                "Status \(status.rawValue): isActive and isTerminal should not be equal")
        }
    }

    // MARK: - 排序权重

    func testSortWeightOrderingActiveBeforeTerminal() {
        let activeWeight = WorkspaceTaskStatus.running.sortWeight
        let terminalWeight = WorkspaceTaskStatus.completed.sortWeight
        XCTAssertLessThan(activeWeight, terminalWeight)
    }

    func testRunningBeforePending() {
        XCTAssertLessThan(WorkspaceTaskStatus.running.sortWeight, WorkspaceTaskStatus.pending.sortWeight)
    }

    // MARK: - 展示属性

    func testStatusTextNotEmpty() {
        for status in [WorkspaceTaskStatus.pending, .running, .completed, .failed, .unknown, .cancelled] {
            XCTAssertFalse(status.statusText.isEmpty, "statusText should not be empty for \(status)")
        }
    }

    func testSectionTitleNotEmpty() {
        for status in [WorkspaceTaskStatus.pending, .running, .completed, .failed, .unknown, .cancelled] {
            XCTAssertFalse(status.sectionTitle.isEmpty, "sectionTitle should not be empty for \(status)")
        }
    }

    func testCompletedIconNameNotEmpty() {
        for status in [WorkspaceTaskStatus.pending, .running, .completed, .failed, .unknown, .cancelled] {
            XCTAssertFalse(status.completedIconName.isEmpty, "completedIconName should not be empty for \(status)")
        }
    }

    // MARK: - WorkspaceTaskType 属性

    func testTaskTypeBlockingByDefault() {
        XCTAssertTrue(WorkspaceTaskType.aiCommit.isBlockingByDefault)
        XCTAssertTrue(WorkspaceTaskType.aiMerge.isBlockingByDefault)
        XCTAssertFalse(WorkspaceTaskType.projectCommand.isBlockingByDefault)
    }

    func testTaskTypeDefaultIconNotEmpty() {
        for type_ in WorkspaceTaskType.allCases {
            XCTAssertFalse(type_.defaultIconName.isEmpty)
        }
    }

    // MARK: - WorkspaceTaskItem 展示派生

    func testDurationTextWithStartedAt() {
        let now = Date()
        let started = now.addingTimeInterval(-90) // 90s ago
        let item = makeItem(status: .running, startedAt: started, completedAt: nil)
        let text = item.durationText
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("m") || text.contains("s"), "Expected formatted duration: \(text)")
    }

    func testDurationTextWithoutStartedAt() {
        let item = makeItem(status: .pending, startedAt: nil, completedAt: nil)
        XCTAssertTrue(item.durationText.isEmpty)
    }

    func testStatusSummaryTextIncludesStatus() {
        let item = makeItem(status: .completed, startedAt: nil, completedAt: Date())
        let summary = item.statusSummaryText()
        XCTAssertFalse(summary.isEmpty)
    }

    func testStatusSummaryTextIncludesMessage() {
        var item = makeItem(status: .failed, startedAt: nil, completedAt: Date())
        item = WorkspaceTaskItem(
            id: item.id, project: item.project, workspace: item.workspace,
            workspaceGlobalKey: item.workspaceGlobalKey, type: item.type,
            title: item.title, iconName: item.iconName, status: .failed,
            message: "编译错误", createdAt: item.createdAt,
            startedAt: nil, completedAt: Date()
        )
        let summary = item.statusSummaryText()
        XCTAssertTrue(summary.contains("编译错误"), "Expected message in summary: \(summary)")
    }

    // MARK: - 相对时间字符串

    func testRelativeTimeJustNow() {
        let now = Date()
        let result = WorkspaceTaskItem.relativeTimeString(from: now.addingTimeInterval(-10), now: now)
        XCTAssertEqual(result, "刚刚")
    }

    func testRelativeTimeMinutesAgo() {
        let now = Date()
        let result = WorkspaceTaskItem.relativeTimeString(from: now.addingTimeInterval(-120), now: now)
        XCTAssertTrue(result.contains("分钟前"), "Expected 分钟前 in: \(result)")
    }

    // MARK: - 工作区隔离键

    func testWorkspaceGlobalKeyFormat() {
        let item = makeItem(project: "myproject", workspace: "dev")
        XCTAssertEqual(item.workspaceGlobalKey, "myproject:dev")
    }

    // MARK: - 辅助

    private func makeItem(
        project: String = "proj",
        workspace: String = "default",
        status: WorkspaceTaskStatus = .running,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> WorkspaceTaskItem {
        WorkspaceTaskItem(
            id: UUID().uuidString,
            project: project,
            workspace: workspace,
            workspaceGlobalKey: "\(project):\(workspace)",
            type: .aiCommit,
            title: "测试任务",
            iconName: "sparkles",
            status: status,
            message: "",
            createdAt: Date(),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
