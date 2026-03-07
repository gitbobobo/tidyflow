import XCTest
@testable import TidyFlow

/// 验证证据页 Tab 的共享语义：
/// - EvidenceTabType 枚举值、displayName、iconName、emptyStateText
/// - matchesItem 分类规则（截图 vs 日志）
/// - filteredItems 从快照中正确筛选并按 order 排序
/// - itemCount 统计与 filteredItems.count 一致
/// - 多工作区快照不互相影响（纯函数语义）
final class WorkspaceEvidenceTabPresentationTests: XCTestCase {

    // MARK: - 枚举基本语义

    func testEvidenceTabTypeHasTwoCases() {
        XCTAssertEqual(EvidenceTabType.allCases.count, 2)
    }

    func testDisplayNames() {
        XCTAssertEqual(EvidenceTabType.screenshot.displayName, "截图")
        XCTAssertEqual(EvidenceTabType.log.displayName, "日志")
    }

    func testIconNames() {
        XCTAssertEqual(EvidenceTabType.screenshot.iconName, "photo")
        XCTAssertEqual(EvidenceTabType.log.iconName, "doc.text")
    }

    func testEmptyStateTexts() {
        XCTAssertEqual(EvidenceTabType.screenshot.emptyStateText, "暂无截图数据")
        XCTAssertEqual(EvidenceTabType.log.emptyStateText, "暂无日志数据")
    }

    func testRawValues() {
        XCTAssertEqual(EvidenceTabType.screenshot.rawValue, "screenshot")
        XCTAssertEqual(EvidenceTabType.log.rawValue, "log")
    }

    // MARK: - matchesItem 分类规则

    func testMatchesItem_screenshotByEvidenceType() {
        let item = makeItem(evidenceType: "screenshot", mimeType: "image/png")
        XCTAssertTrue(EvidenceTabType.screenshot.matchesItem(item))
        XCTAssertFalse(EvidenceTabType.log.matchesItem(item))
    }

    func testMatchesItem_screenshotByMimeType() {
        // evidenceType 为其他值但 mimeType 以 image/ 开头 → 归入截图
        let item = makeItem(evidenceType: "capture", mimeType: "image/jpeg")
        XCTAssertTrue(EvidenceTabType.screenshot.matchesItem(item))
        XCTAssertFalse(EvidenceTabType.log.matchesItem(item))
    }

    func testMatchesItem_logByEvidenceType() {
        let item = makeItem(evidenceType: "log", mimeType: "text/plain")
        XCTAssertTrue(EvidenceTabType.log.matchesItem(item))
        XCTAssertFalse(EvidenceTabType.screenshot.matchesItem(item))
    }

    func testMatchesItem_logByNonImageMimeType() {
        // evidenceType 不是 screenshot 且 mimeType 不以 image/ 开头 → 归入日志
        let item = makeItem(evidenceType: "crash", mimeType: "application/octet-stream")
        XCTAssertTrue(EvidenceTabType.log.matchesItem(item))
        XCTAssertFalse(EvidenceTabType.screenshot.matchesItem(item))
    }

    func testMatchesItem_screenshotEvidenceTypeNotMatchLog() {
        // evidenceType == "screenshot" 且 mimeType 不以 image/ 开头，也不应归入日志
        let item = makeItem(evidenceType: "screenshot", mimeType: "application/octet-stream")
        XCTAssertTrue(EvidenceTabType.screenshot.matchesItem(item))
        XCTAssertFalse(EvidenceTabType.log.matchesItem(item))
    }

    func testMatchesItem_noDuplication() {
        // 每个条目只属于一个 Tab
        let items = [
            makeItem(evidenceType: "screenshot", mimeType: "image/png"),
            makeItem(evidenceType: "log", mimeType: "text/plain"),
            makeItem(evidenceType: "capture", mimeType: "image/jpeg"),
            makeItem(evidenceType: "crash", mimeType: "application/json"),
        ]
        for item in items {
            let matchCount = EvidenceTabType.allCases.filter { $0.matchesItem(item) }.count
            XCTAssertEqual(matchCount, 1, "条目 \(item.evidenceType)/\(item.mimeType) 应只属于一个 Tab")
        }
    }

    // MARK: - filteredItems 排序与筛选

    func testFilteredItems_returnsOnlyMatchingItems() {
        let snapshot = makeSnapshot(items: [
            makeItem(id: "s1", evidenceType: "screenshot", mimeType: "image/png", order: 2),
            makeItem(id: "l1", evidenceType: "log", mimeType: "text/plain", order: 1),
            makeItem(id: "s2", evidenceType: "screenshot", mimeType: "image/png", order: 0),
        ])
        let screenshots = EvidenceTabType.screenshot.filteredItems(from: snapshot)
        XCTAssertEqual(screenshots.count, 2)
        XCTAssertTrue(screenshots.allSatisfy { $0.evidenceType == "screenshot" })
    }

    func testFilteredItems_sortedByOrder() {
        let snapshot = makeSnapshot(items: [
            makeItem(id: "s3", evidenceType: "screenshot", mimeType: "image/png", order: 10),
            makeItem(id: "s1", evidenceType: "screenshot", mimeType: "image/png", order: 1),
            makeItem(id: "s2", evidenceType: "screenshot", mimeType: "image/png", order: 5),
        ])
        let items = EvidenceTabType.screenshot.filteredItems(from: snapshot)
        XCTAssertEqual(items.map { $0.order }, [1, 5, 10])
    }

    func testFilteredItems_emptySnapshotReturnsEmpty() {
        let snapshot = makeSnapshot(items: [])
        XCTAssertTrue(EvidenceTabType.screenshot.filteredItems(from: snapshot).isEmpty)
        XCTAssertTrue(EvidenceTabType.log.filteredItems(from: snapshot).isEmpty)
    }

    // MARK: - itemCount 一致性

    func testItemCount_matchesFilteredItemsCount() {
        let snapshot = makeSnapshot(items: [
            makeItem(id: "s1", evidenceType: "screenshot", mimeType: "image/png", order: 0),
            makeItem(id: "s2", evidenceType: "screenshot", mimeType: "image/png", order: 1),
            makeItem(id: "l1", evidenceType: "log", mimeType: "text/plain", order: 2),
        ])
        for tab in EvidenceTabType.allCases {
            XCTAssertEqual(tab.itemCount(in: snapshot), tab.filteredItems(from: snapshot).count,
                           "\(tab.rawValue) 的 itemCount 与 filteredItems.count 必须一致")
        }
    }

    // MARK: - 多工作区纯函数行为

    func testFilteredItems_isStateless_multipleSnapshots() {
        // 两个不同工作区的快照互不影响
        let snapshotA = makeSnapshot(project: "proj-a", workspace: "ws-a", items: [
            makeItem(id: "a1", evidenceType: "screenshot", mimeType: "image/png", order: 0),
        ])
        let snapshotB = makeSnapshot(project: "proj-b", workspace: "ws-b", items: [
            makeItem(id: "b1", evidenceType: "log", mimeType: "text/plain", order: 0),
            makeItem(id: "b2", evidenceType: "log", mimeType: "text/plain", order: 1),
        ])
        XCTAssertEqual(EvidenceTabType.screenshot.filteredItems(from: snapshotA).count, 1)
        XCTAssertEqual(EvidenceTabType.log.filteredItems(from: snapshotA).count, 0)
        XCTAssertEqual(EvidenceTabType.screenshot.filteredItems(from: snapshotB).count, 0)
        XCTAssertEqual(EvidenceTabType.log.filteredItems(from: snapshotB).count, 2)
    }

    // MARK: - Helpers

    private func makeItem(
        id: String = "item",
        evidenceType: String,
        mimeType: String,
        order: Int = 0,
        deviceType: String = "iPhone"
    ) -> EvidenceItemInfoV2 {
        EvidenceItemInfoV2(
            itemID: id,
            deviceType: deviceType,
            evidenceType: evidenceType,
            order: order,
            path: "/tmp/\(id)",
            title: id,
            description: "",
            scenario: nil,
            subsystem: nil,
            createdAt: nil,
            sizeBytes: 0,
            exists: true,
            mimeType: mimeType
        )
    }

    private func makeSnapshot(
        project: String = "test-project",
        workspace: String = "default",
        items: [EvidenceItemInfoV2]
    ) -> EvidenceSnapshotV2 {
        EvidenceSnapshotV2(
            project: project,
            workspace: workspace,
            evidenceRoot: "/tmp/evidence",
            indexFile: "/tmp/evidence/index.json",
            indexExists: true,
            detectedSubsystems: [],
            detectedDeviceTypes: [],
            items: items,
            issues: [],
            updatedAt: "2026-01-01T00:00:00Z"
        )
    }
}
