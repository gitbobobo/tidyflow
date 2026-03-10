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

    // MARK: - Core 耗时优先级

    func testDurationTextPrefersCoreDurationMs() {
        let now = Date()
        let started = now.addingTimeInterval(-300) // 本地计算应为 ~5m
        var item = makeItem(status: .completed, startedAt: started, completedAt: now)
        item = WorkspaceTaskItem(
            id: item.id, project: item.project, workspace: item.workspace,
            workspaceGlobalKey: item.workspaceGlobalKey, type: item.type,
            title: item.title, iconName: item.iconName, status: .completed,
            message: "", createdAt: item.createdAt,
            startedAt: started, completedAt: now,
            coreDurationMs: 42_000 // Core 权威值: 42 秒
        )
        let text = item.durationText
        // 42s → "42s"，而不是本地计算的 ~300s
        XCTAssertEqual(text, "42s", "应优先使用 coreDurationMs 而非本地计算")
    }

    func testDurationTextCoreDurationMinutes() {
        var item = makeItem(status: .completed)
        item = WorkspaceTaskItem(
            id: item.id, project: item.project, workspace: item.workspace,
            workspaceGlobalKey: item.workspaceGlobalKey, type: item.type,
            title: item.title, iconName: item.iconName, status: .completed,
            message: "", createdAt: item.createdAt,
            coreDurationMs: 125_000 // 2m 5s
        )
        XCTAssertEqual(item.durationText, "2m 5s")
    }

    // MARK: - 失败摘要

    func testFailureSummaryWithErrorCodeAndMessage() {
        let item = WorkspaceTaskItem(
            id: "f1", project: "p", workspace: "w",
            workspaceGlobalKey: "p:w", type: .projectCommand,
            title: "build", iconName: "terminal", status: .failed,
            message: "exit code 1", createdAt: Date(),
            errorCode: "command_failed", errorDetail: "line 42: error\nline 43: detail"
        )
        let summary = item.failureSummary
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("[command_failed]"), "应包含诊断码")
        XCTAssertTrue(summary!.contains("exit code 1"), "应包含 message")
    }

    func testFailureSummaryFallsBackToErrorDetailFirstLine() {
        let item = WorkspaceTaskItem(
            id: "f2", project: "p", workspace: "w",
            workspaceGlobalKey: "p:w", type: .projectCommand,
            title: "lint", iconName: "terminal", status: .failed,
            message: "", createdAt: Date(),
            errorCode: nil, errorDetail: "首行错误\n第二行详情"
        )
        let summary = item.failureSummary
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary, "首行错误", "message 为空时应回退到 errorDetail 首行")
    }

    func testFailureSummaryNilForNonFailedStatus() {
        let item = makeItem(status: .completed)
        XCTAssertNil(item.failureSummary, "非失败状态不应有失败摘要")
    }

    // MARK: - 重试描述符

    func testRetryDescriptorPresentWhenRetryable() {
        let item = WorkspaceTaskItem(
            id: "r1", project: "proj-a", workspace: "ws1",
            workspaceGlobalKey: "proj-a:ws1", type: .projectCommand,
            title: "build", iconName: "terminal", status: .failed,
            message: "err", createdAt: Date(),
            commandId: "cmd-1",
            retryable: true
        )
        let desc = item.retryDescriptor
        XCTAssertNotNil(desc)
        XCTAssertEqual(desc?.project, "proj-a")
        XCTAssertEqual(desc?.workspace, "ws1")
        XCTAssertEqual(desc?.taskType, .projectCommand)
        XCTAssertEqual(desc?.commandId, "cmd-1")
        XCTAssertEqual(desc?.workspaceGlobalKey, "proj-a:ws1")
    }

    func testRetryDescriptorNilWhenNotRetryable() {
        let item = WorkspaceTaskItem(
            id: "r2", project: "p", workspace: "w",
            workspaceGlobalKey: "p:w", type: .aiCommit,
            title: "commit", iconName: "sparkles", status: .failed,
            message: "err", createdAt: Date(),
            retryable: false
        )
        XCTAssertNil(item.retryDescriptor, "retryable=false 时不应生成重试描述符")
    }

    // MARK: - WorkspaceRunStatusGroup

    func testRunStatusGroupCategorizesCorrectly() {
        let now = Date()
        let active1 = makeItem(project: "p", workspace: "w", status: .running, startedAt: now)
        let active2 = makeItem(project: "p", workspace: "w", status: .pending, startedAt: now)
        let failed1 = WorkspaceTaskItem(
            id: UUID().uuidString, project: "p", workspace: "w",
            workspaceGlobalKey: "p:w", type: .projectCommand,
            title: "fail1", iconName: "terminal", status: .failed,
            message: "err", createdAt: now,
            retryable: true
        )
        let failed2 = WorkspaceTaskItem(
            id: UUID().uuidString, project: "p", workspace: "w",
            workspaceGlobalKey: "p:w", type: .aiCommit,
            title: "fail2", iconName: "sparkles", status: .failed,
            message: "err", createdAt: now,
            retryable: false
        )
        let completed1 = makeItem(project: "p", workspace: "w", status: .completed, completedAt: now)

        let group = WorkspaceRunStatusGroup(
            workspaceGlobalKey: "p:w",
            project: "p",
            workspace: "w",
            activeTasks: [active1, active2],
            failedTasks: [failed1, failed2],
            completedTasks: [completed1]
        )

        XCTAssertEqual(group.activeTasks.count, 2)
        XCTAssertEqual(group.failedTasks.count, 2)
        XCTAssertEqual(group.completedTasks.count, 1)
        XCTAssertTrue(group.hasFailures)
        XCTAssertEqual(group.retryableCount, 1, "仅 retryable=true 的失败任务计入")
    }

    func testRunStatusGroupNoFailures() {
        let group = WorkspaceRunStatusGroup(
            workspaceGlobalKey: "p:w",
            project: "p",
            workspace: "w",
            activeTasks: [],
            failedTasks: [],
            completedTasks: []
        )
        XCTAssertFalse(group.hasFailures)
        XCTAssertEqual(group.retryableCount, 0)
    }

    // MARK: - 排序键跨状态一致性

    func testSortKeyActiveBeforeTerminal() {
        let now = Date()
        let active = makeItem(status: .running, startedAt: now)
        let done = makeItem(status: .completed, completedAt: now)
        XCTAssertTrue(active.sortKey < done.sortKey, "活跃任务应排在已完成之前")
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
