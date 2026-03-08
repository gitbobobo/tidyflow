import XCTest
@testable import TidyFlow
import TidyFlowShared

final class SharedProtocolModelsTests: XCTestCase {
    func testWorkspaceSidebarStatusInfoEmpty() {
        let info = WorkspaceSidebarStatusInfo.empty
        XCTAssertNil(info.taskIcon)
        XCTAssertFalse(info.chatActive)
        XCTAssertFalse(info.evolutionActive)
    }

    func testProjectInfoFromJson() {
        let json: [String: Any] = [
            "name": "my-project",
            "root": "/Users/test/project",
            "workspace_count": 2
        ]
        let info = ProjectInfo.from(json: json)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.name, "my-project")
        XCTAssertEqual(info?.workspaceCount, 2)
    }

    func testWorkspaceInfoFromJson() {
        let json: [String: Any] = [
            "name": "default",
            "root": "/Users/test/project",
            "branch": "main",
            "status": "idle"
        ]
        let info = WorkspaceInfo.from(json: json)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.branch, "main")
    }

    func testTerminalSessionInfoFromJson() {
        let json: [String: Any] = [
            "term_id": "term-001",
            "project": "my-project",
            "workspace": "default",
            "cwd": "/Users/test",
            "shell": "/bin/zsh",
            "status": "running"
        ]
        let info = TerminalSessionInfo.from(json: json)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.termId, "term-001")
        XCTAssertTrue(info?.isRunning ?? false)
    }
}
