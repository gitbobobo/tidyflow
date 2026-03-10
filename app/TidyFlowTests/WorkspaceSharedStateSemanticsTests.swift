import XCTest
@testable import TidyFlow

/// 共享状态机语义回归测试
/// 覆盖工作区视图状态机在多项目、多工作区下的选中态、默认工作区和恢复语义，
/// 验证共享状态机不发生状态串台，同一组输入在 macOS/iOS 场景下语义一致。
final class WorkspaceSharedStateSemanticsTests: XCTestCase {

    // MARK: - 选中态基础行为

    func testSelect_setsSelectedState() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "ProjectA", workspaceName: "main", projectId: nil))
        XCTAssertNotNil(machine.selected)
        XCTAssertEqual(machine.selected?.projectName, "ProjectA")
        XCTAssertEqual(machine.selected?.workspaceName, "main")
    }

    func testSelect_updatesGlobalKey() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "P", workspaceName: "W", projectId: nil))
        XCTAssertEqual(machine.selected?.globalKey, "P:W")
    }

    func testSelect_notRestoredFlag() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "P", workspaceName: "W", projectId: nil))
        XCTAssertFalse(machine.selected?.isRestored == true, "主动选择时 isRestored 应为 false")
    }

    func testSelect_withProjectId_preservesId() {
        let id = UUID()
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "P", workspaceName: "W", projectId: id))
        XCTAssertEqual(machine.selected?.projectId, id)
    }

    // MARK: - 清除状态

    func testClear_resetsSelected() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "P", workspaceName: "W", projectId: nil))
        machine.apply(.clear)
        XCTAssertNil(machine.selected, "clear 后 selected 应为 nil")
    }

    // MARK: - 恢复语义

    func testRestore_setsIsRestoredTrue() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.restore(projectName: "P", workspaceName: "W"))
        XCTAssertTrue(machine.selected?.isRestored == true, "restore 后 isRestored 应为 true")
    }

    func testRestore_nilProjectId() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.restore(projectName: "P", workspaceName: "W"))
        XCTAssertNil(machine.selected?.projectId, "restore 不携带 UUID（兼容 iOS）")
    }

    // MARK: - 多项目隔离：同名工作区不串台

    func testMultiProject_sameWorkspaceName_differentProjectsIsolated() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "ProjectA", workspaceName: "default", projectId: nil))

        XCTAssertTrue(machine.isSelected(projectName: "ProjectA", workspaceName: "default"))
        XCTAssertFalse(machine.isSelected(projectName: "ProjectB", workspaceName: "default"),
                       "ProjectB:default 不应与 ProjectA:default 共享同一选中槽位")
    }

    func testMultiProject_switchProject_updateSelection() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "ProjectA", workspaceName: "main", projectId: nil))
        machine.apply(.select(projectName: "ProjectB", workspaceName: "main", projectId: nil))

        XCTAssertFalse(machine.isSelected(projectName: "ProjectA", workspaceName: "main"),
                       "切换到 ProjectB 后 ProjectA 不应再为选中态")
        XCTAssertTrue(machine.isSelected(projectName: "ProjectB", workspaceName: "main"))
    }

    // MARK: - isSelected 接口（多种入参形式）

    func testIsSelected_byProjectAndWorkspaceName_match() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "P", workspaceName: "W", projectId: nil))
        XCTAssertTrue(machine.isSelected(projectName: "P", workspaceName: "W"))
    }

    func testIsSelected_byGlobalKey_match() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "P", workspaceName: "W", projectId: nil))
        XCTAssertTrue(machine.isSelected(globalKey: "P:W"))
    }

    func testIsSelected_byGlobalKey_mismatch() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "P", workspaceName: "W", projectId: nil))
        XCTAssertFalse(machine.isSelected(globalKey: "P:Other"))
    }

    func testIsSelected_nilState_returnsFalse() {
        let machine = WorkspaceViewStateMachine()
        XCTAssertFalse(machine.isSelected(projectName: "P", workspaceName: "W"))
        XCTAssertFalse(machine.isSelected(globalKey: "P:W"))
    }

    func testSelectedState_ifGlobalKey_matchFound() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "P", workspaceName: "W", projectId: nil))
        XCTAssertNotNil(machine.selectedState(ifGlobalKey: "P:W"))
    }

    func testSelectedState_ifGlobalKey_noMatch() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "P", workspaceName: "W", projectId: nil))
        XCTAssertNil(machine.selectedState(ifGlobalKey: "P:Other"))
    }

    // MARK: - 全局键唯一性

    func testGlobalKey_differentProjectsSameWorkspace_notEqual() {
        let stateA = WorkspaceViewState(projectName: "ProjectA", workspaceName: "default")
        let stateB = WorkspaceViewState(projectName: "ProjectB", workspaceName: "default")
        XCTAssertNotEqual(stateA.globalKey, stateB.globalKey,
                          "不同项目的同名工作区全局键必须不同，防止状态串台")
    }

    func testGlobalKey_format() {
        let state = WorkspaceViewState(projectName: "MyProject", workspaceName: "main")
        XCTAssertEqual(state.globalKey, "MyProject:main")
    }

    // MARK: - WorkspaceViewState 等值与哈希

    func testEquality_sameValues() {
        let a = WorkspaceViewState(projectName: "P", workspaceName: "W", projectId: nil)
        let b = WorkspaceViewState(projectName: "P", workspaceName: "W", projectId: nil)
        XCTAssertEqual(a, b)
    }

    func testEquality_differentProject() {
        let a = WorkspaceViewState(projectName: "P1", workspaceName: "W")
        let b = WorkspaceViewState(projectName: "P2", workspaceName: "W")
        XCTAssertNotEqual(a, b)
    }

    func testEquality_differentWorkspace() {
        let a = WorkspaceViewState(projectName: "P", workspaceName: "W1")
        let b = WorkspaceViewState(projectName: "P", workspaceName: "W2")
        XCTAssertNotEqual(a, b)
    }

    func testHashable_usableInSet() {
        let a = WorkspaceViewState(projectName: "P", workspaceName: "W")
        let b = WorkspaceViewState(projectName: "P", workspaceName: "W")
        let set: Set<WorkspaceViewState> = [a, b]
        XCTAssertEqual(set.count, 1, "相同状态应合并")
    }

    // MARK: - 恢复后再主动选择可覆盖

    func testRestore_thenSelect_overridesIsRestored() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.restore(projectName: "P", workspaceName: "W"))
        machine.apply(.select(projectName: "P", workspaceName: "W", projectId: nil))
        XCTAssertFalse(machine.selected?.isRestored == true,
                       "主动选择应覆盖恢复态标记")
    }

    // MARK: - 多工作区下不同工作区不互相影响

    func testMultiWorkspace_switchWorkspace_onlyCurrentSelected() {
        let machine = WorkspaceViewStateMachine()
        machine.apply(.select(projectName: "P", workspaceName: "feature-a", projectId: nil))
        machine.apply(.select(projectName: "P", workspaceName: "feature-b", projectId: nil))

        XCTAssertFalse(machine.isSelected(projectName: "P", workspaceName: "feature-a"),
                       "切换工作区后旧工作区不应为选中态")
        XCTAssertTrue(machine.isSelected(projectName: "P", workspaceName: "feature-b"))
    }

    // MARK: - WI-005: 门禁生命周期与一致性回归

    /// 验证多项目场景下 clear + restore 不会把旧项目状态带入新项目
    func testClearAndRestore_doesNotLeakOldProjectState() {
        let machine = WorkspaceViewStateMachine()

        // 旧项目状态
        let oldId = UUID()
        machine.apply(.select(projectName: "OldProject", workspaceName: "main", projectId: oldId))
        XCTAssertTrue(machine.isSelected(projectName: "OldProject", workspaceName: "main"))

        // 切换项目：clear + restore 新项目
        machine.apply(.clear)
        machine.apply(.restore(projectName: "NewProject", workspaceName: "main"))

        XCTAssertFalse(machine.isSelected(projectName: "OldProject", workspaceName: "main"),
                       "clear 后旧项目不应为选中态")
        XCTAssertTrue(machine.isSelected(projectName: "NewProject", workspaceName: "main"),
                      "restore 后新项目应为选中态")
        XCTAssertNil(machine.selected?.projectId,
                     "restore 不应继承旧项目的 UUID")
    }

    /// 验证多工作区快速切换的状态一致性：
    /// 连续切换多个工作区后，只有最后一个应处于选中态
    func testRapidWorkspaceSwitching_onlyLastSelected() {
        let machine = WorkspaceViewStateMachine()
        let workspaces = (1...10).map { "ws-\($0)" }

        for ws in workspaces {
            machine.apply(.select(projectName: "P", workspaceName: ws, projectId: nil))
        }

        // 只有最后一个应选中
        for ws in workspaces.dropLast() {
            XCTAssertFalse(machine.isSelected(projectName: "P", workspaceName: ws),
                           "快速切换后只有最后工作区应选中，但 \(ws) 仍为选中态")
        }
        XCTAssertTrue(machine.isSelected(projectName: "P", workspaceName: "ws-10"))
    }

    /// 验证 globalKey 在跨项目跨工作区场景下的唯一性
    func testGlobalKey_uniquenessAcrossProjectsAndWorkspaces() {
        let combinations = [
            ("P1", "W1"), ("P1", "W2"), ("P2", "W1"), ("P2", "W2"),
            ("P1:W", "1"), // 测试包含分隔符的项目名
        ]
        var keys = Set<String>()
        for (proj, ws) in combinations {
            let state = WorkspaceViewState(projectName: proj, workspaceName: ws)
            let inserted = keys.insert(state.globalKey).inserted
            XCTAssertTrue(inserted, "globalKey '\(state.globalKey)' 不应与其他组合碰撞")
        }
    }

    /// 验证恢复状态在门禁周期结束后可被完全清除
    func testGateLifecycle_restoreAndClear_fullCleanup() {
        let machine = WorkspaceViewStateMachine()

        // 模拟 verify 阶段的恢复
        machine.apply(.restore(projectName: "Proj", workspaceName: "verify-ws"))
        XCTAssertTrue(machine.selected?.isRestored == true)

        // 门禁通过后 clear
        machine.apply(.clear)
        XCTAssertNil(machine.selected, "门禁通过后 clear 应完全清除状态")

        // 进入下一阶段
        machine.apply(.select(projectName: "Proj", workspaceName: "next-ws", projectId: nil))
        XCTAssertFalse(machine.selected?.isRestored == true,
                       "新阶段不应继承上一阶段的 isRestored 标记")
    }
}
