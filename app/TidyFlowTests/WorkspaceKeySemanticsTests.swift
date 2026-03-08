import XCTest
@testable import TidyFlow

/// 工作区键语义单元测试
/// 覆盖 default/(default) 归一化、多项目同名工作区隔离、文件缓存键与前缀生成规则
final class WorkspaceKeySemanticsTests: XCTestCase {

    // MARK: - 工作区名称归一化

    func testNormalizeWorkspaceName_default_lowercase() {
        XCTAssertEqual(WorkspaceKeySemantics.normalizeWorkspaceName("default"), "default")
    }

    func testNormalizeWorkspaceName_default_uppercase() {
        XCTAssertEqual(WorkspaceKeySemantics.normalizeWorkspaceName("DEFAULT"), "default")
    }

    func testNormalizeWorkspaceName_default_mixed() {
        XCTAssertEqual(WorkspaceKeySemantics.normalizeWorkspaceName("Default"), "default")
    }

    func testNormalizeWorkspaceName_parenDefault_lowercase() {
        XCTAssertEqual(WorkspaceKeySemantics.normalizeWorkspaceName("(default)"), "default")
    }

    func testNormalizeWorkspaceName_parenDefault_uppercase() {
        XCTAssertEqual(WorkspaceKeySemantics.normalizeWorkspaceName("(DEFAULT)"), "default")
    }

    func testNormalizeWorkspaceName_parenDefault_mixed() {
        XCTAssertEqual(WorkspaceKeySemantics.normalizeWorkspaceName("(Default)"), "default")
    }

    func testNormalizeWorkspaceName_custom_preserved() {
        XCTAssertEqual(WorkspaceKeySemantics.normalizeWorkspaceName("main"), "main")
    }

    func testNormalizeWorkspaceName_trimWhitespace() {
        XCTAssertEqual(WorkspaceKeySemantics.normalizeWorkspaceName("  main  "), "main")
    }

    func testNormalizeWorkspaceName_default_withWhitespace_normalized() {
        XCTAssertEqual(WorkspaceKeySemantics.normalizeWorkspaceName("  default  "), "default")
    }

    // MARK: - 全局工作区键

    func testGlobalKey_basicFormat() {
        XCTAssertEqual(WorkspaceKeySemantics.globalKey(project: "MyProject", workspace: "main"), "MyProject:main")
    }

    func testGlobalKey_trimsWhitespace() {
        XCTAssertEqual(
            WorkspaceKeySemantics.globalKey(project: "  MyProject  ", workspace: "  main  "),
            "MyProject:main"
        )
    }

    func testGlobalKey_differentProjectsSameWorkspaceName_notEqual() {
        let key1 = WorkspaceKeySemantics.globalKey(project: "ProjectA", workspace: "default")
        let key2 = WorkspaceKeySemantics.globalKey(project: "ProjectB", workspace: "default")
        XCTAssertNotEqual(key1, key2, "不同项目同名工作区的全局键必须不同，防止缓存串扰")
    }

    func testGlobalKey_sameProjectDifferentWorkspace_notEqual() {
        let key1 = WorkspaceKeySemantics.globalKey(project: "MyProject", workspace: "main")
        let key2 = WorkspaceKeySemantics.globalKey(project: "MyProject", workspace: "dev")
        XCTAssertNotEqual(key1, key2)
    }

    func testGlobalKey_sameProjectSameWorkspace_equal() {
        let key1 = WorkspaceKeySemantics.globalKey(project: "MyProject", workspace: "main")
        let key2 = WorkspaceKeySemantics.globalKey(project: "MyProject", workspace: "main")
        XCTAssertEqual(key1, key2)
    }

    // MARK: - 文件缓存键

    func testFileCacheKey_basicFormat() {
        XCTAssertEqual(
            WorkspaceKeySemantics.fileCacheKey(project: "P", workspace: "W", path: "."),
            "P:W:."
        )
    }

    func testFileCacheKey_differentPaths_notEqual() {
        let key1 = WorkspaceKeySemantics.fileCacheKey(project: "P", workspace: "W", path: ".")
        let key2 = WorkspaceKeySemantics.fileCacheKey(project: "P", workspace: "W", path: "src")
        XCTAssertNotEqual(key1, key2, "不同 path 的文件缓存键必须不同，防止目录展开状态互相覆盖")
    }

    func testFileCacheKey_differentProjectsSameWorkspacePath_notEqual() {
        let key1 = WorkspaceKeySemantics.fileCacheKey(project: "A", workspace: "default", path: "src")
        let key2 = WorkspaceKeySemantics.fileCacheKey(project: "B", workspace: "default", path: "src")
        XCTAssertNotEqual(key1, key2, "不同项目同名工作区相同路径的文件缓存键必须不同")
    }

    // MARK: - 文件缓存键前缀

    func testFileCachePrefix_basicFormat() {
        XCTAssertEqual(
            WorkspaceKeySemantics.fileCachePrefix(project: "P", workspace: "W"),
            "P:W:"
        )
    }

    func testFileCachePrefix_endsWithColon() {
        let prefix = WorkspaceKeySemantics.fileCachePrefix(project: "MyProject", workspace: "main")
        XCTAssertTrue(prefix.hasSuffix(":"), "前缀必须以 ':' 结尾，保证前缀扫描不会误命中子串")
    }

    func testFileCachePrefix_isActualPrefixOfFileCacheKey() {
        let prefix = WorkspaceKeySemantics.fileCachePrefix(project: "P", workspace: "W")
        let key = WorkspaceKeySemantics.fileCacheKey(project: "P", workspace: "W", path: "src/main.swift")
        XCTAssertTrue(key.hasPrefix(prefix), "fileCacheKey 必须以对应的 fileCachePrefix 开头，保证前缀扫描正确")
    }

    func testFileCachePrefix_doesNotMatchOtherProject() {
        let prefix = WorkspaceKeySemantics.fileCachePrefix(project: "A", workspace: "default")
        let key = WorkspaceKeySemantics.fileCacheKey(project: "B", workspace: "default", path: ".")
        XCTAssertFalse(key.hasPrefix(prefix), "不同项目的键不能被另一项目的前缀命中")
    }

    // MARK: - default/(default) 别名隔离

    func testDefaultAliasConsistency_defaultAndParenDefault_sameGlobalKey() {
        let key1 = WorkspaceKeySemantics.globalKey(
            project: "P",
            workspace: WorkspaceKeySemantics.normalizeWorkspaceName("default")
        )
        let key2 = WorkspaceKeySemantics.globalKey(
            project: "P",
            workspace: WorkspaceKeySemantics.normalizeWorkspaceName("(default)")
        )
        XCTAssertEqual(key1, key2, "default 与 (default) 归一化后应生成相同的全局键")
    }

    func testDefaultAliasConsistency_differentProjects_stillIsolated() {
        let key1 = WorkspaceKeySemantics.globalKey(
            project: "ProjectA",
            workspace: WorkspaceKeySemantics.normalizeWorkspaceName("(default)")
        )
        let key2 = WorkspaceKeySemantics.globalKey(
            project: "ProjectB",
            workspace: WorkspaceKeySemantics.normalizeWorkspaceName("default")
        )
        XCTAssertNotEqual(key1, key2, "即使工作区都是 default，不同项目的全局键也必须不同")
    }
}

// MARK: - WorkspaceIdentity 身份标识测试

final class WorkspaceIdentityTests: XCTestCase {

    func testGlobalKey_matchesWorkspaceKeySemantics() {
        let identity = WorkspaceIdentity(
            projectId: UUID(),
            projectName: "MyProject",
            workspaceName: "main"
        )
        let expected = WorkspaceKeySemantics.globalKey(project: "MyProject", workspace: "main")
        XCTAssertEqual(identity.globalKey, expected, "WorkspaceIdentity.globalKey 应委托到 WorkspaceKeySemantics")
    }

    func testFileCachePrefix_matchesWorkspaceKeySemantics() {
        let identity = WorkspaceIdentity(
            projectId: UUID(),
            projectName: "P",
            workspaceName: "W"
        )
        let expected = WorkspaceKeySemantics.fileCachePrefix(project: "P", workspace: "W")
        XCTAssertEqual(identity.fileCachePrefix, expected)
    }

    func testFileCacheKey_matchesWorkspaceKeySemantics() {
        let identity = WorkspaceIdentity(
            projectId: UUID(),
            projectName: "P",
            workspaceName: "W"
        )
        let expected = WorkspaceKeySemantics.fileCacheKey(project: "P", workspace: "W", path: "src")
        XCTAssertEqual(identity.fileCacheKey(path: "src"), expected)
    }

    func testEquality_sameValues() {
        let id = UUID()
        let a = WorkspaceIdentity(projectId: id, projectName: "P", workspaceName: "W")
        let b = WorkspaceIdentity(projectId: id, projectName: "P", workspaceName: "W")
        XCTAssertEqual(a, b)
    }

    func testEquality_differentProjectName() {
        let id = UUID()
        let a = WorkspaceIdentity(projectId: id, projectName: "P1", workspaceName: "W")
        let b = WorkspaceIdentity(projectId: id, projectName: "P2", workspaceName: "W")
        XCTAssertNotEqual(a, b, "项目名不同应视为不同身份")
    }

    func testEquality_differentWorkspace() {
        let id = UUID()
        let a = WorkspaceIdentity(projectId: id, projectName: "P", workspaceName: "W1")
        let b = WorkspaceIdentity(projectId: id, projectName: "P", workspaceName: "W2")
        XCTAssertNotEqual(a, b, "工作区名不同应视为不同身份")
    }

    func testHashable_usableInSet() {
        let id = UUID()
        let a = WorkspaceIdentity(projectId: id, projectName: "P", workspaceName: "W")
        let b = WorkspaceIdentity(projectId: id, projectName: "P", workspaceName: "W")
        let set: Set<WorkspaceIdentity> = [a, b]
        XCTAssertEqual(set.count, 1, "相同身份应合并")
    }

    func testDifferentProjectId_sameNamesDifferentIdentity() {
        let a = WorkspaceIdentity(projectId: UUID(), projectName: "P", workspaceName: "W")
        let b = WorkspaceIdentity(projectId: UUID(), projectName: "P", workspaceName: "W")
        XCTAssertNotEqual(a, b, "不同 projectId 即使名称相同也应视为不同身份")
    }
}

// MARK: - WorkspaceSelectionSemantics 选择匹配测试

final class WorkspaceSelectionSemanticsTests: XCTestCase {

    func testMatches_nilIdentity_returnsFalse() {
        let result = WorkspaceSelectionSemantics.matches(
            identity: nil,
            projectName: "P",
            workspaceName: "W"
        )
        XCTAssertFalse(result, "无选中状态时应返回 false")
    }

    func testMatches_exactMatch_returnsTrue() {
        let identity = WorkspaceIdentity(projectId: UUID(), projectName: "P", workspaceName: "W")
        XCTAssertTrue(WorkspaceSelectionSemantics.matches(
            identity: identity, projectName: "P", workspaceName: "W"
        ))
    }

    func testMatches_differentProject_returnsFalse() {
        let identity = WorkspaceIdentity(projectId: UUID(), projectName: "P1", workspaceName: "W")
        XCTAssertFalse(WorkspaceSelectionSemantics.matches(
            identity: identity, projectName: "P2", workspaceName: "W"
        ))
    }

    func testMatches_differentWorkspace_returnsFalse() {
        let identity = WorkspaceIdentity(projectId: UUID(), projectName: "P", workspaceName: "W1")
        XCTAssertFalse(WorkspaceSelectionSemantics.matches(
            identity: identity, projectName: "P", workspaceName: "W2"
        ))
    }

    func testMatchesGlobalKey_nilIdentity_returnsFalse() {
        XCTAssertFalse(WorkspaceSelectionSemantics.matchesGlobalKey(identity: nil, globalKey: "P:W"))
    }

    func testMatchesGlobalKey_correctKey_returnsTrue() {
        let identity = WorkspaceIdentity(projectId: UUID(), projectName: "P", workspaceName: "W")
        XCTAssertTrue(WorkspaceSelectionSemantics.matchesGlobalKey(
            identity: identity, globalKey: "P:W"
        ))
    }

    func testMatchesGlobalKey_wrongKey_returnsFalse() {
        let identity = WorkspaceIdentity(projectId: UUID(), projectName: "P", workspaceName: "W")
        XCTAssertFalse(WorkspaceSelectionSemantics.matchesGlobalKey(
            identity: identity, globalKey: "P:OtherW"
        ))
    }

    // MARK: - 工作区列表排序

    private struct MockWorkspace: WorkspaceSortable {
        let name: String
        let isDefaultWorkspace: Bool
        var workspaceSortName: String { name }
    }

    func testSortedWorkspaces_defaultFirst() {
        let workspaces = [
            MockWorkspace(name: "feature", isDefaultWorkspace: false),
            MockWorkspace(name: "default", isDefaultWorkspace: true),
            MockWorkspace(name: "alpha", isDefaultWorkspace: false),
        ]
        let sorted = WorkspaceSelectionSemantics.sortedWorkspaces(workspaces)
        XCTAssertEqual(sorted.map(\.name), ["default", "alpha", "feature"],
                       "默认工作区应排在最前，其余按名称字母序")
    }

    func testSortedWorkspaces_multipleDefaults_bothFirst() {
        let workspaces = [
            MockWorkspace(name: "z-feature", isDefaultWorkspace: false),
            MockWorkspace(name: "default-b", isDefaultWorkspace: true),
            MockWorkspace(name: "default-a", isDefaultWorkspace: true),
        ]
        let sorted = WorkspaceSelectionSemantics.sortedWorkspaces(workspaces)
        XCTAssertTrue(sorted[0].isDefaultWorkspace && sorted[1].isDefaultWorkspace)
    }

    func testSortedWorkspaces_empty() {
        let sorted = WorkspaceSelectionSemantics.sortedWorkspaces([MockWorkspace]())
        XCTAssertTrue(sorted.isEmpty)
    }

    // MARK: - resolveProjectName

    private struct MockProject: ProjectIdentifiable {
        let projectUUID: UUID
        let projectDisplayName: String
    }

    func testResolveProjectName_found() {
        let id = UUID()
        let projects = [MockProject(projectUUID: id, projectDisplayName: "Found")]
        XCTAssertEqual(
            WorkspaceSelectionSemantics.resolveProjectName(projectId: id, in: projects, fallback: "FB"),
            "Found"
        )
    }

    func testResolveProjectName_notFound_returnsFallback() {
        let projects = [MockProject(projectUUID: UUID(), projectDisplayName: "Other")]
        XCTAssertEqual(
            WorkspaceSelectionSemantics.resolveProjectName(projectId: UUID(), in: projects, fallback: "Fallback"),
            "Fallback"
        )
    }
}

// MARK: - ProjectSortingSemantics 项目排序测试

final class ProjectSortingSemanticsTests: XCTestCase {

    private struct TestProject {
        let name: String
        let shortcutKey: Int
        let terminalTime: Date?
    }

    func testSortedProjects_shortcutFirst() {
        let projects = [
            TestProject(name: "Zebra", shortcutKey: Int.max, terminalTime: nil),
            TestProject(name: "Alpha", shortcutKey: 1, terminalTime: nil),
        ]
        let sorted = ProjectSortingSemantics.sortedProjects(
            projects,
            shortcutKeyFinder: { $0.shortcutKey },
            earliestTerminalTimeFinder: { $0.terminalTime },
            nameExtractor: { $0.name }
        )
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "Zebra"],
                       "有快捷键的项目应排在无快捷键项目之前")
    }

    func testSortedProjects_sameShortcutStatus_alphabetical() {
        let projects = [
            TestProject(name: "Charlie", shortcutKey: Int.max, terminalTime: nil),
            TestProject(name: "Alpha", shortcutKey: Int.max, terminalTime: nil),
            TestProject(name: "Bravo", shortcutKey: Int.max, terminalTime: nil),
        ]
        let sorted = ProjectSortingSemantics.sortedProjects(
            projects,
            shortcutKeyFinder: { $0.shortcutKey },
            earliestTerminalTimeFinder: { $0.terminalTime },
            nameExtractor: { $0.name }
        )
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "Bravo", "Charlie"])
    }

    func testSortedProjects_bothShortcutted_earlierTerminalFirst() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        let projects = [
            TestProject(name: "B", shortcutKey: 2, terminalTime: later),
            TestProject(name: "A", shortcutKey: 1, terminalTime: earlier),
        ]
        let sorted = ProjectSortingSemantics.sortedProjects(
            projects,
            shortcutKeyFinder: { $0.shortcutKey },
            earliestTerminalTimeFinder: { $0.terminalTime },
            nameExtractor: { $0.name }
        )
        XCTAssertEqual(sorted.map(\.name), ["A", "B"],
                       "两个有快捷键的项目按终端首次打开时间排序")
    }

    func testSortedIndices_matchesSortedProjects() {
        let projects = [
            TestProject(name: "Charlie", shortcutKey: Int.max, terminalTime: nil),
            TestProject(name: "Alpha", shortcutKey: 1, terminalTime: nil),
            TestProject(name: "Bravo", shortcutKey: Int.max, terminalTime: nil),
        ]
        let indices = ProjectSortingSemantics.sortedIndices(
            projects,
            shortcutKeyFinder: { $0.shortcutKey },
            earliestTerminalTimeFinder: { $0.terminalTime },
            nameExtractor: { $0.name }
        )
        let sorted = ProjectSortingSemantics.sortedProjects(
            projects,
            shortcutKeyFinder: { $0.shortcutKey },
            earliestTerminalTimeFinder: { $0.terminalTime },
            nameExtractor: { $0.name }
        )
        let fromIndices = indices.map { projects[$0].name }
        let fromSorted = sorted.map(\.name)
        XCTAssertEqual(fromIndices, fromSorted,
                       "sortedIndices 的顺序应与 sortedProjects 一致")
    }

    func testSortedIndices_emptyInput() {
        let indices = ProjectSortingSemantics.sortedIndices(
            [TestProject](),
            shortcutKeyFinder: { $0.shortcutKey },
            earliestTerminalTimeFinder: { $0.terminalTime },
            nameExtractor: { $0.name }
        )
        XCTAssertTrue(indices.isEmpty)
    }

    func testSortedIndices_preservesOriginalArrayMapping() {
        let projects = [
            TestProject(name: "Z", shortcutKey: Int.max, terminalTime: nil),
            TestProject(name: "A", shortcutKey: Int.max, terminalTime: nil),
        ]
        let indices = ProjectSortingSemantics.sortedIndices(
            projects,
            shortcutKeyFinder: { $0.shortcutKey },
            earliestTerminalTimeFinder: { $0.terminalTime },
            nameExtractor: { $0.name }
        )
        XCTAssertEqual(indices, [1, 0], "索引应指向原数组中 A（idx=1）和 Z（idx=0）的位置")
    }
}
