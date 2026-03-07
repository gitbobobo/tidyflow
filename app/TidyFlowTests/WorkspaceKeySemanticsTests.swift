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
