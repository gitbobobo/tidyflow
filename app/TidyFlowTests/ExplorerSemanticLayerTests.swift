import XCTest
import SwiftUI
@testable import TidyFlow

// MARK: - ExplorerSemanticLayer 单元测试
// 覆盖：目录图标、普通文件图标、特殊文件资产、ignored、symlink、Git 状态聚合、多工作区索引隔离

final class ExplorerSemanticLayerTests: XCTestCase {

    // MARK: - 辅助工厂

    private func entry(
        name: String,
        path: String? = nil,
        isDir: Bool = false,
        isIgnored: Bool = false,
        isSymlink: Bool = false
    ) -> FileEntry {
        FileEntry(
            name: name,
            path: path ?? name,
            isDir: isDir,
            size: 0,
            isIgnored: isIgnored,
            isSymlink: isSymlink
        )
    }

    private func resolve(
        _ entry: FileEntry,
        gitIndex: GitStatusIndex = GitStatusIndex(),
        isExpanded: Bool = false,
        isSelected: Bool = false
    ) -> ExplorerItemPresentation {
        ExplorerSemanticResolver.resolve(
            entry: entry,
            gitIndex: gitIndex,
            isExpanded: isExpanded,
            isSelected: isSelected
        )
    }

    // MARK: - 目录图标

    func testDirectoryIconCollapsed() {
        let p = resolve(entry(name: "src", isDir: true), isExpanded: false)
        XCTAssertEqual(p.iconName, "folder")
        XCTAssertFalse(p.hasSpecialIcon)
    }

    func testDirectoryIconExpanded() {
        let p = resolve(entry(name: "src", isDir: true), isExpanded: true)
        XCTAssertEqual(p.iconName, "folder.fill")
    }

    // MARK: - 普通文件图标（按扩展名）

    func testSwiftFileIcon() {
        let p = resolve(entry(name: "main.swift"))
        XCTAssertEqual(p.iconName, "swift")
    }

    func testRustFileIcon() {
        let p = resolve(entry(name: "lib.rs"))
        XCTAssertEqual(p.iconName, "gear")
    }

    func testMarkdownFileIcon() {
        let p = resolve(entry(name: "README.md"))
        XCTAssertEqual(p.iconName, "doc.richtext")
    }

    func testDefaultFileIcon() {
        let p = resolve(entry(name: "unknown.xyz"))
        XCTAssertEqual(p.iconName, "doc")
    }

    // MARK: - 特殊文件资产（CLAUDE.md / AGENTS.md）

    func testClaudeMdHasSpecialIcon() {
        let p = resolve(entry(name: "CLAUDE.md"))
        XCTAssertTrue(p.hasSpecialIcon)
    }

    func testAgentsMdHasSpecialIcon() {
        let p = resolve(entry(name: "AGENTS.md"))
        XCTAssertTrue(p.hasSpecialIcon)
    }

    func testNonSpecialFileHasNoSpecialIcon() {
        let p = resolve(entry(name: "README.md"))
        XCTAssertFalse(p.hasSpecialIcon)
    }

    func testDirectoryNeverHasSpecialIcon() {
        // 目录即使名字匹配也不触发特殊图标
        let p = resolve(entry(name: "CLAUDE.md", isDir: true))
        XCTAssertFalse(p.hasSpecialIcon)
    }

    // MARK: - ignored 状态

    func testIgnoredFileHasGrayTitleColor() {
        let p = resolve(entry(name: "build.o", isIgnored: true))
        XCTAssertNotNil(p.titleColor)
        // Git 状态应为空（忽略文件无独立 git badge）
        XCTAssertNil(p.gitStatus)
    }

    func testNonIgnoredFileHasNilTitleColorWithoutGitStatus() {
        let p = resolve(entry(name: "main.swift"))
        XCTAssertNil(p.titleColor)
    }

    // MARK: - symlink 尾部图标

    func testSymlinkHasTrailingIcon() {
        let p = resolve(entry(name: "link", isSymlink: true))
        XCTAssertEqual(p.trailingIcon, "arrow.uturn.backward")
    }

    func testNonSymlinkHasNoTrailingIcon() {
        let p = resolve(entry(name: "main.swift"))
        XCTAssertNil(p.trailingIcon)
    }

    // MARK: - Git 状态展示

    func testModifiedFileShowsGitStatus() {
        let items = [
            GitStatusItem(id: "src/a.swift", path: "src/a.swift", status: "M",
                          staged: nil, renameFrom: nil, additions: nil, deletions: nil)
        ]
        let index = GitStatusIndex(fromItems: items)
        let e = entry(name: "a.swift", path: "src/a.swift")
        let p = resolve(e, gitIndex: index)
        XCTAssertEqual(p.gitStatus, "M")
        XCTAssertNotNil(p.gitStatusColor)
        XCTAssertNotNil(p.titleColor)
    }

    func testAddedFileShowsGitStatus() {
        let items = [
            GitStatusItem(id: "new.rs", path: "new.rs", status: "A",
                          staged: nil, renameFrom: nil, additions: nil, deletions: nil)
        ]
        let index = GitStatusIndex(fromItems: items)
        let p = resolve(entry(name: "new.rs"), gitIndex: index)
        XCTAssertEqual(p.gitStatus, "A")
    }

    // MARK: - 目录 Git 状态聚合

    func testDirectoryAggregatesHighestPriorityGitStatus() {
        // M 优先级 6 > A 优先级 5，目录应展示 M
        let items = [
            GitStatusItem(id: "src/a.swift", path: "src/a.swift", status: "M",
                          staged: nil, renameFrom: nil, additions: nil, deletions: nil),
            GitStatusItem(id: "src/b.swift", path: "src/b.swift", status: "A",
                          staged: nil, renameFrom: nil, additions: nil, deletions: nil)
        ]
        let index = GitStatusIndex(fromItems: items)
        let dir = entry(name: "src", path: "src", isDir: true)
        let p = resolve(dir, gitIndex: index)
        XCTAssertEqual(p.gitStatus, "M")
    }

    func testDirectoryConflictStatusHasHighestPriority() {
        let items = [
            GitStatusItem(id: "src/c.swift", path: "src/c.swift", status: "U",
                          staged: nil, renameFrom: nil, additions: nil, deletions: nil),
            GitStatusItem(id: "src/d.swift", path: "src/d.swift", status: "M",
                          staged: nil, renameFrom: nil, additions: nil, deletions: nil)
        ]
        let index = GitStatusIndex(fromItems: items)
        let dir = entry(name: "src", path: "src", isDir: true)
        let p = resolve(dir, gitIndex: index)
        XCTAssertEqual(p.gitStatus, "U")
    }

    // MARK: - 多工作区索引隔离

    func testMultiWorkspaceGitIndexIsolation() {
        let items1 = [
            GitStatusItem(id: "src/a.swift", path: "src/a.swift", status: "M",
                          staged: nil, renameFrom: nil, additions: nil, deletions: nil)
        ]
        let items2 = [
            GitStatusItem(id: "src/b.swift", path: "src/b.swift", status: "A",
                          staged: nil, renameFrom: nil, additions: nil, deletions: nil)
        ]
        let index1 = GitStatusIndex(fromItems: items1)
        let index2 = GitStatusIndex(fromItems: items2)

        // 工作区 1 的索引不包含工作区 2 的文件
        XCTAssertNil(index1.getFileStatus("src/b.swift"))
        XCTAssertNil(index2.getFileStatus("src/a.swift"))

        // 各自工作区可正常获取自己的文件状态
        XCTAssertEqual(index1.getFileStatus("src/a.swift"), "M")
        XCTAssertEqual(index2.getFileStatus("src/b.swift"), "A")
    }

    // MARK: - isSelected 传递

    func testIsSelectedPropagated() {
        let p = resolve(entry(name: "main.swift"), isSelected: true)
        XCTAssertTrue(p.isSelected)
    }

    func testIsNotSelectedByDefault() {
        let p = resolve(entry(name: "main.swift"))
        XCTAssertFalse(p.isSelected)
    }

    // MARK: - fileIconName 覆盖常用扩展名

    func testFileIconNameMapping() {
        let cases: [(String, String)] = [
            ("App.swift", "swift"),
            ("main.rs", "gear"),
            ("index.js", "j.square"),
            ("config.ts", "j.square"),
            ("data.json", "curlybraces"),
            ("README.md", "doc.richtext"),
            ("index.html", "globe"),
            ("style.css", "paintbrush"),
            ("script.py", "chevron.left.forwardslash.chevron.right"),
            ("run.sh", "terminal"),
            ("config.yml", "doc.badge.gearshape"),
            ("photo.png", "photo"),
            ("song.mp3", "music.note"),
            ("video.mp4", "video"),
            ("backup.zip", "archivebox"),
            ("doc.pdf", "doc.fill"),
            ("notes.txt", "doc.text"),
            ("deps.lock", "lock"),
            ("unknown.xyz", "doc"),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(
                ExplorerSemanticResolver.fileIconName(for: name), expected,
                "文件 \(name) 图标应为 \(expected)"
            )
        }
    }
}
