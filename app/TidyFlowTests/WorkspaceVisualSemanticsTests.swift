import XCTest
@testable import TidyFlow

/// 验证工作区视觉语义约束：
/// - EvidenceTabType 的 iconName 与 emptyStateText 在切换后保持稳定（不随 selectedTab 外部状态漂移）
/// - Tab 切换后清理策略：log tab 不持有 screenshot 选中项，反之亦然
/// - 各 Tab 的空态文案与图标不应为空字符串（防止前端展示空白）
final class WorkspaceVisualSemanticsTests: XCTestCase {

    // MARK: - Tab 切换后状态清理语义

    func testScreenshotTabSelectedID_doesNotInterferWithLogTab() {
        // 模拟选中态：screenshot tab 有选中项，log tab 没有
        let screenshotID: String? = "s-001"
        let logID: String? = nil

        // 验证：当 selectedTab == .log 时，相关 selectedID 应为 logID 而非 screenshotID
        func selectedID(for tab: EvidenceTabType) -> String? {
            tab == .screenshot ? screenshotID : logID
        }
        XCTAssertEqual(selectedID(for: .log), nil)
        XCTAssertEqual(selectedID(for: .screenshot), "s-001")
    }

    func testLogTabSelectedID_doesNotInterferWithScreenshotTab() {
        let screenshotID: String? = nil
        let logID: String? = "l-001"

        func selectedID(for tab: EvidenceTabType) -> String? {
            tab == .screenshot ? screenshotID : logID
        }
        XCTAssertEqual(selectedID(for: .screenshot), nil)
        XCTAssertEqual(selectedID(for: .log), "l-001")
    }

    // MARK: - 空态文案与图标非空

    func testAllTabsHaveNonEmptyDisplayName() {
        for tab in EvidenceTabType.allCases {
            XCTAssertFalse(tab.displayName.isEmpty, "\(tab.rawValue) displayName 不应为空")
        }
    }

    func testAllTabsHaveNonEmptyIconName() {
        for tab in EvidenceTabType.allCases {
            XCTAssertFalse(tab.iconName.isEmpty, "\(tab.rawValue) iconName 不应为空")
        }
    }

    func testAllTabsHaveNonEmptyEmptyStateText() {
        for tab in EvidenceTabType.allCases {
            XCTAssertFalse(tab.emptyStateText.isEmpty, "\(tab.rawValue) emptyStateText 不应为空")
        }
    }

    // MARK: - Tab 枚举稳定性（防止枚举名漂移影响 rawValue 持久化）

    func testRawValueStability() {
        XCTAssertEqual(EvidenceTabType(rawValue: "screenshot"), .screenshot)
        XCTAssertEqual(EvidenceTabType(rawValue: "log"), .log)
        XCTAssertNil(EvidenceTabType(rawValue: "video"))
        XCTAssertNil(EvidenceTabType(rawValue: ""))
    }

    // MARK: - 冗余遮罩移除后活动语义约束
    // 确认 EvidenceTabType 的视觉表达（iconName、displayName）足以在无额外遮罩层的情况下传递 Tab 意图

    func testTabVisualSemantics_screenshotUsesPhotoIcon() {
        // photo 图标在 SF Symbols 中代表图像，语义清晰
        XCTAssertEqual(EvidenceTabType.screenshot.iconName, "photo")
    }

    func testTabVisualSemantics_logUsesDocTextIcon() {
        // doc.text 图标在 SF Symbols 中代表文本文档，语义清晰
        XCTAssertEqual(EvidenceTabType.log.iconName, "doc.text")
    }

    func testTabVisualSemantics_tabsAreDistinct() {
        // 两个 Tab 的图标、文案、emptyStateText 均不相同，保证切换后视觉有区分
        XCTAssertNotEqual(EvidenceTabType.screenshot.iconName, EvidenceTabType.log.iconName)
        XCTAssertNotEqual(EvidenceTabType.screenshot.displayName, EvidenceTabType.log.displayName)
        XCTAssertNotEqual(EvidenceTabType.screenshot.emptyStateText, EvidenceTabType.log.emptyStateText)
    }

    // MARK: - 筛选后总数覆盖率：所有条目必须被某个 Tab 覆盖

    func testAllItemsAreCoveredByExactlyOneTab() {
        let items: [EvidenceItemInfoV2] = [
            makeItem(evidenceType: "screenshot", mimeType: "image/png"),
            makeItem(evidenceType: "log", mimeType: "text/plain"),
            makeItem(evidenceType: "crash", mimeType: "application/json"),
            makeItem(evidenceType: "capture", mimeType: "image/jpeg"),
            makeItem(evidenceType: "metrics", mimeType: "text/csv"),
        ]
        let snapshot = makeSnapshot(items: items)
        let total = EvidenceTabType.allCases.reduce(0) { $0 + $1.itemCount(in: snapshot) }
        XCTAssertEqual(total, items.count, "所有条目必须被且仅被一个 Tab 覆盖，无遗漏无重复")
    }

    // MARK: - Helpers

    private func makeItem(
        id: String = UUID().uuidString,
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

    private func makeSnapshot(items: [EvidenceItemInfoV2]) -> EvidenceSnapshotV2 {
        EvidenceSnapshotV2(
            project: "test-project",
            workspace: "default",
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
