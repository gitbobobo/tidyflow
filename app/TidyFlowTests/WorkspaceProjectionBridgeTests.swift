import XCTest
@testable import TidyFlow
import TidyFlowShared

/// 共享投影桥接回归测试
/// 验证 SidebarProjectionModels 与 WorkspaceOverviewProjection 中的共享语义方法：
/// - 相同输入在双端消费同一共享投影语义时结果稳定一致
/// - 投影输出保留 project/workspace 范围信息，不依赖隐式"当前项目"假设
final class WorkspaceProjectionBridgeTests: XCTestCase {

    // MARK: - SidebarProjectionSemantics 活动指示器

    func testActivityIndicators_allNil_empty() {
        let indicators = SidebarProjectionSemantics.activityIndicators(
            chatIconName: nil,
            hasActiveEvolutionLoop: false,
            taskIconName: nil
        )
        XCTAssertTrue(indicators.isEmpty)
    }

    func testActivityIndicators_chatOnly() {
        let indicators = SidebarProjectionSemantics.activityIndicators(
            chatIconName: "bubble.left.fill",
            hasActiveEvolutionLoop: false,
            taskIconName: nil
        )
        XCTAssertEqual(indicators.count, 1)
        XCTAssertEqual(indicators[0].id, "chat")
        XCTAssertEqual(indicators[0].iconName, "bubble.left.fill")
    }

    func testActivityIndicators_evolution_addsEvolutionIndicator() {
        let indicators = SidebarProjectionSemantics.activityIndicators(
            chatIconName: nil,
            hasActiveEvolutionLoop: true,
            taskIconName: nil
        )
        XCTAssertEqual(indicators.count, 1)
        XCTAssertEqual(indicators[0].id, "evolution")
        XCTAssertEqual(indicators[0].iconName, "brain.head.profile")
    }

    func testActivityIndicators_allPresent_correctOrder() {
        let indicators = SidebarProjectionSemantics.activityIndicators(
            chatIconName: "bubble.left.fill",
            hasActiveEvolutionLoop: true,
            taskIconName: "arrow.triangle.2.circlepath"
        )
        XCTAssertEqual(indicators.count, 3)
        XCTAssertEqual(indicators[0].id, "chat")
        XCTAssertEqual(indicators[1].id, "evolution")
        XCTAssertEqual(indicators[2].id, "task")
    }

    func testActivityIndicators_taskOnly() {
        let indicators = SidebarProjectionSemantics.activityIndicators(
            chatIconName: nil,
            hasActiveEvolutionLoop: false,
            taskIconName: "play.circle.fill"
        )
        XCTAssertEqual(indicators.count, 1)
        XCTAssertEqual(indicators[0].id, "task")
    }

    // MARK: - SidebarProjectionSemantics 快捷键展示文本

    func testShortcutDisplayText_nil_returnsNil() {
        XCTAssertNil(SidebarProjectionSemantics.shortcutDisplayText(nil))
    }

    func testShortcutDisplayText_number_formatsCorrectly() {
        XCTAssertEqual(SidebarProjectionSemantics.shortcutDisplayText("1"), "⌘1")
    }

    func testShortcutDisplayText_letter_formatsCorrectly() {
        XCTAssertEqual(SidebarProjectionSemantics.shortcutDisplayText("A"), "⌘A")
    }

    // MARK: - SidebarWorkspaceProjection 保留 project/workspace 范围

    func testSidebarWorkspaceProjection_preservesProjectAndWorkspaceName() {
        let proj = SidebarWorkspaceProjection(
            id: "P:W",
            projectName: "P",
            projectPath: "/path/to/P",
            workspaceName: "W",
            workspacePath: "/path/to/P/W",
            branch: "main",
            statusText: nil,
            isDefault: false,
            isSelected: true,
            globalWorkspaceKey: "P:W",
            shortcutDisplayText: "⌘1",
            terminalCount: 2,
            hasOpenTabs: true,
            isDeleting: false,
            hasUnseenCompletion: false,
            activityIndicators: []
        )
        XCTAssertEqual(proj.projectName, "P", "投影必须保留项目名")
        XCTAssertEqual(proj.workspaceName, "W", "投影必须保留工作区名")
        XCTAssertEqual(proj.globalWorkspaceKey, "P:W", "全局键必须为 project:workspace 格式")
    }

    // MARK: - WorkspaceOverviewProjection 初始值

    func testWorkspaceOverviewProjection_empty_hasNoTerminals() {
        let projection = WorkspaceOverviewProjection.empty
        XCTAssertTrue(projection.terminals.isEmpty)
        XCTAssertTrue(projection.runningTasks.isEmpty)
        XCTAssertFalse(projection.hasActiveConflicts)
        XCTAssertEqual(projection.completedTaskCount, 0)
        XCTAssertEqual(projection.pendingTodoCount, 0)
    }

    // MARK: - WorkspaceOverviewProjectionSemantics 组装

    func testWorkspaceOverviewProjectionSemantics_make_roundTrip() {
        let terminal = WorkspaceTerminalProjection(
            id: "term1",
            termId: "term1",
            title: "bash",
            shortId: "term1abc",
            iconName: "terminal",
            isPinned: false,
            aiStatus: .idle,
            hasTerminalsToRight: false
        )
        let projection = WorkspaceOverviewProjectionSemantics.make(
            gitSnapshot: .empty(),
            hasActiveConflicts: false,
            terminals: [terminal],
            runningTasks: [],
            completedTaskCount: 3,
            pendingTodoCount: 2,
            projectCommands: []
        )
        XCTAssertEqual(projection.terminals.count, 1)
        XCTAssertEqual(projection.completedTaskCount, 3)
        XCTAssertEqual(projection.pendingTodoCount, 2)
    }

    // MARK: - WorkspaceTerminalAIStatusProjection 空闲状态

    func testTerminalAIStatusProjection_idle_notVisible() {
        XCTAssertFalse(WorkspaceTerminalAIStatusProjection.idle.isVisible)
    }

    func testTerminalAIStatusProjection_idle_colorTokenIsSecondary() {
        XCTAssertEqual(WorkspaceTerminalAIStatusProjection.idle.colorToken, "secondary")
    }

    // MARK: - SidebarProjectProjection 多工作区可见性

    func testSidebarProjectProjection_visibleWorkspaces_containsProjectScope() {
        let ws1 = SidebarWorkspaceProjection(
            id: "P:feature-a",
            projectName: "P",
            projectPath: nil,
            workspaceName: "feature-a",
            workspacePath: nil,
            branch: nil,
            statusText: nil,
            isDefault: false,
            isSelected: false,
            globalWorkspaceKey: "P:feature-a",
            shortcutDisplayText: nil,
            terminalCount: 0,
            hasOpenTabs: false,
            isDeleting: false,
            hasUnseenCompletion: false,
            activityIndicators: []
        )
        let ws2 = SidebarWorkspaceProjection(
            id: "P:feature-b",
            projectName: "P",
            projectPath: nil,
            workspaceName: "feature-b",
            workspacePath: nil,
            branch: nil,
            statusText: nil,
            isDefault: false,
            isSelected: false,
            globalWorkspaceKey: "P:feature-b",
            shortcutDisplayText: nil,
            terminalCount: 0,
            hasOpenTabs: false,
            isDeleting: false,
            hasUnseenCompletion: false,
            activityIndicators: []
        )
        let projectProj = SidebarProjectProjection(
            id: "proj-P",
            projectID: nil,
            projectName: "P",
            projectPath: nil,
            primaryWorkspaceName: "default",
            defaultWorkspaceName: "default",
            defaultWorkspacePath: nil,
            defaultGlobalWorkspaceKey: "P:default",
            isSelectedDefaultWorkspace: false,
            shortcutDisplayText: nil,
            terminalCount: 0,
            hasOpenTabs: false,
            isDeleting: false,
            hasUnseenCompletion: false,
            activityIndicators: [],
            visibleWorkspaces: [ws1, ws2],
            isLoadingWorkspaces: false
        )
        XCTAssertEqual(projectProj.visibleWorkspaces.count, 2)
        // 每个可见工作区都必须带有正确的 projectName，不能省略
        for ws in projectProj.visibleWorkspaces {
            XCTAssertEqual(ws.projectName, "P", "可见工作区投影必须保留 projectName")
        }
    }

    // MARK: - 相同输入 → 相同投影（幂等性）

    func testActivityIndicators_sameInputsProduceSameOutput_idempotent() {
        let a = SidebarProjectionSemantics.activityIndicators(
            chatIconName: "bubble.left.fill",
            hasActiveEvolutionLoop: true,
            taskIconName: "play.circle"
        )
        let b = SidebarProjectionSemantics.activityIndicators(
            chatIconName: "bubble.left.fill",
            hasActiveEvolutionLoop: true,
            taskIconName: "play.circle"
        )
        XCTAssertEqual(a, b, "相同输入应产生相同投影输出")
    }
}
