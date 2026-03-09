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
}
