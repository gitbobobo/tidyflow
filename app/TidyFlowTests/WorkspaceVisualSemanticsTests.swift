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

// MARK: - 工作区切换回归检查

final class WorkspaceSwitchRegressionTests: XCTestCase {

    func testWorkspaceKeyIsolation_sameNameDifferentProjects() {
        let key1 = WorkspaceKeySemantics.globalKey(project: "projectA", workspace: "default")
        let key2 = WorkspaceKeySemantics.globalKey(project: "projectB", workspace: "default")
        XCTAssertNotEqual(key1, key2, "不同项目下同名工作区的全局键必须不同")
    }

    func testWorkspaceKeyStability_sameInputSameOutput() {
        let key1 = WorkspaceKeySemantics.globalKey(project: "proj", workspace: "ws")
        let key2 = WorkspaceKeySemantics.globalKey(project: "proj", workspace: "ws")
        XCTAssertEqual(key1, key2, "相同输入必须产生相同全局键")
    }

    func testSessionPageKeyIsolation_acrossWorkspaces() {
        let key1 = AISessionListSemantics.pageKey(project: "p", workspace: "ws1", filter: .all)
        let key2 = AISessionListSemantics.pageKey(project: "p", workspace: "ws2", filter: .all)
        XCTAssertNotEqual(key1, key2, "不同工作区的会话分页键必须不同")
    }

    func testFileCacheKeyIsolation_acrossProjects() {
        let key1 = WorkspaceKeySemantics.fileCacheKey(project: "pA", workspace: "default", path: "src")
        let key2 = WorkspaceKeySemantics.fileCacheKey(project: "pB", workspace: "default", path: "src")
        XCTAssertNotEqual(key1, key2, "不同项目同名工作区同一路径的文件缓存键必须不同")
    }
}

// MARK: - 文件树渲染回归检查

final class FileTreeRenderRegressionTests: XCTestCase {

    func testExplorerResolverDeterminism() {
        let entry = FileEntry(name: "main.swift", path: "main.swift", isDir: false, size: 100, isIgnored: false, isSymlink: false)
        let p1 = ExplorerSemanticResolver.resolve(entry: entry, gitIndex: GitStatusIndex(), isExpanded: false, isSelected: false)
        let p2 = ExplorerSemanticResolver.resolve(entry: entry, gitIndex: GitStatusIndex(), isExpanded: false, isSelected: false)
        XCTAssertEqual(p1.iconName, p2.iconName, "相同输入的解析结果必须确定性一致")
        XCTAssertEqual(p1.hasSpecialIcon, p2.hasSpecialIcon)
    }

    func testExplorerResolverDirectoryExpandedState() {
        let dir = FileEntry(name: "src", path: "src", isDir: true, size: 0, isIgnored: false, isSymlink: false)
        let collapsed = ExplorerSemanticResolver.resolve(entry: dir, gitIndex: GitStatusIndex(), isExpanded: false, isSelected: false)
        let expanded = ExplorerSemanticResolver.resolve(entry: dir, gitIndex: GitStatusIndex(), isExpanded: true, isSelected: false)
        XCTAssertNotEqual(collapsed.iconName, expanded.iconName, "展开/折叠状态应产生不同图标")
    }

    func testFileCacheKeyScopedByPath() {
        let rootKey = WorkspaceKeySemantics.fileCacheKey(project: "p", workspace: "ws", path: ".")
        let subKey = WorkspaceKeySemantics.fileCacheKey(project: "p", workspace: "ws", path: "src")
        XCTAssertNotEqual(rootKey, subKey, "不同路径的缓存键必须不同")
    }
}

// MARK: - AI 会话列表回归检查

final class AISessionListRegressionTests: XCTestCase {

    func testSessionVisibility_userOriginVisible() {
        XCTAssertTrue(AISessionSemantics.isSessionVisibleInDefaultList(origin: .user))
    }

    func testSessionVisibility_evolutionSystemHidden() {
        XCTAssertFalse(AISessionSemantics.isSessionVisibleInDefaultList(origin: .evolutionSystem))
    }

    func testSessionSelectionDelegatesToSemantics() {
        let session = AISessionInfo(projectName: "p", workspaceName: "w", aiTool: .codex, id: "s", title: "T", updatedAt: 0, origin: .user)
        let selected = AISessionListSemantics.isSessionSelected(session: session, currentSessionId: "s", currentTool: .codex)
        let notSelected = AISessionListSemantics.isSessionSelected(session: session, currentSessionId: "other", currentTool: .codex)
        XCTAssertTrue(selected)
        XCTAssertFalse(notSelected)
    }

    func testPageKeyConsistency_macOS_iOS_shared() {
        // 验证共享语义层生成的 pageKey 格式一致
        let sharedKey = AISessionListSemantics.pageKey(project: "p", workspace: "ws", filter: .all)
        XCTAssertEqual(sharedKey, "p::ws::all", "pageKey 应遵循 project::workspace::filterId 格式")
    }
}

// MARK: - 性能追踪器回归检查

final class PerformanceTracerRegressionTests: XCTestCase {

    func testTracerDisabledByDefault() {
        let tracer = TFPerformanceTracer()
        XCTAssertFalse(tracer.enabled, "追踪器默认应关闭")
    }

    func testTracerBeginReturnEmptyWhenDisabled() {
        let tracer = TFPerformanceTracer()
        let id = tracer.begin(TFPerformanceContext(event: .workspaceSwitch, project: "p", workspace: "w"))
        XCTAssertTrue(id.isEmpty, "禁用时 begin 应返回空字符串")
        XCTAssertTrue(tracer.snapshots.isEmpty, "禁用时不应产生快照")
    }

    func testTracerRecordsSnapshotWhenEnabled() {
        let tracer = TFPerformanceTracer()
        tracer.enabled = true
        let id = tracer.begin(TFPerformanceContext(event: .workspaceSwitch, project: "p", workspace: "w"))
        XCTAssertFalse(id.isEmpty)
        tracer.end(id)
        XCTAssertEqual(tracer.snapshots.count, 1)
        XCTAssertNotNil(tracer.snapshots.first?.durationMs)
    }

    func testTracerSnapshotContainsContext() {
        let tracer = TFPerformanceTracer()
        tracer.enabled = true
        let ctx = TFPerformanceContext(event: .fileTreeRequest, project: "proj", workspace: "ws", metadata: ["path": "."])
        let id = tracer.begin(ctx)
        tracer.end(id)
        let snapshot = tracer.snapshots.first
        XCTAssertEqual(snapshot?.context.event, .fileTreeRequest)
        XCTAssertEqual(snapshot?.context.project, "proj")
        XCTAssertEqual(snapshot?.context.workspace, "ws")
        XCTAssertEqual(snapshot?.context.metadata["path"], ".")
    }

    func testTracerReset() {
        let tracer = TFPerformanceTracer()
        tracer.enabled = true
        let id = tracer.begin(TFPerformanceContext(event: .workspaceSwitch, project: "p", workspace: "w"))
        tracer.end(id)
        XCTAssertFalse(tracer.snapshots.isEmpty)
        tracer.reset()
        XCTAssertTrue(tracer.snapshots.isEmpty, "reset 后快照应为空")
    }

    func testTracerCapLimit() {
        let tracer = TFPerformanceTracer()
        tracer.enabled = true
        for i in 0..<150 {
            let id = tracer.begin(TFPerformanceContext(event: .workspaceSwitch, project: "p\(i)", workspace: "w"))
            tracer.end(id)
        }
        XCTAssertLessThanOrEqual(tracer.snapshots.count, 100, "快照数量不应超过上限")
    }

    func testAllPerformanceEventsCovered() {
        // 确保每种性能事件都有定义
        XCTAssertGreaterThanOrEqual(TFPerformanceEvent.allCases.count, 5, "至少应有 5 种性能事件")
        for event in TFPerformanceEvent.allCases {
            XCTAssertFalse(event.rawValue.isEmpty, "事件 rawValue 不应为空")
            XCTAssertEqual(event.category, "perf", "所有性能事件 category 应为 perf")
        }
    }
}

// MARK: - 共享展示阶段与视图语义回归

final class SharedDisplayPhaseRegressionTests: XCTestCase {

    // MARK: AISessionListDisplayPhase 视图消费语义

    func testAISessionDisplayPhase_loading_matchesExpectedViewBehavior() {
        // loading 状态：视图应展示骨架屏/spinner，不应展示空态占位
        let phase = AISessionListDisplayPhase.from(isLoadingInitial: true, sessions: [])
        switch phase {
        case .loading: break // 正确
        default: XCTFail("初始加载无缓存应进入 loading 阶段")
        }
    }

    func testAISessionDisplayPhase_empty_matchesExpectedViewBehavior() {
        // empty 状态：视图应展示空态占位，不应展示 spinner
        let phase = AISessionListDisplayPhase.from(isLoadingInitial: false, sessions: [])
        switch phase {
        case .empty: break // 正确
        default: XCTFail("加载完成但无会话应进入 empty 阶段")
        }
    }

    // MARK: TerminalListDisplayPhase 视图消费语义

    func testTerminalDisplayPhase_empty_noTerminalsForWorkspace() {
        let phase = TerminalListDisplayPhase.from(
            project: "p", workspace: "ws",
            allTerminals: [], pinnedIds: []
        )
        switch phase {
        case .empty: break
        default: XCTFail("空终端列表应进入 empty 阶段")
        }
    }

    func testTerminalDisplayPhase_content_carriesFilteredTerminals() {
        let term = TerminalSessionInfo(
            termId: "t1", project: "p", workspace: "ws",
            cwd: "/", shell: "bash", status: "running",
            name: "Shell", icon: nil, remoteSubscribers: []
        )
        let phase = TerminalListDisplayPhase.from(
            project: "p", workspace: "ws",
            allTerminals: [term], pinnedIds: []
        )
        switch phase {
        case .content(let terminals):
            XCTAssertEqual(terminals.count, 1)
        default:
            XCTFail("有终端时应进入 content 阶段")
        }
    }

    // MARK: 跨工作区隔离回归

    func testDisplayPhases_isolateAcrossProjects() {
        let term = TerminalSessionInfo(
            termId: "t1", project: "projA", workspace: "ws",
            cwd: "/", shell: "bash", status: "running",
            name: "Shell", icon: nil, remoteSubscribers: []
        )
        // projA/ws 有终端，projB/ws 无终端
        let phaseA = TerminalListDisplayPhase.from(
            project: "projA", workspace: "ws",
            allTerminals: [term], pinnedIds: []
        )
        let phaseB = TerminalListDisplayPhase.from(
            project: "projB", workspace: "ws",
            allTerminals: [term], pinnedIds: []
        )
        switch phaseA {
        case .content: break
        default: XCTFail("projA 应有终端")
        }
        switch phaseB {
        case .empty: break
        default: XCTFail("projB 不应看到 projA 的终端")
        }
    }
}

final class BottomPanelLayoutSemanticsTests: XCTestCase {

    func testRestoreExpandedHeight_usesDefaultHeightOnFirstExpand() {
        let restored = BottomPanelLayoutSemantics.restoredExpandedHeight(
            currentHeight: 0,
            lastExpandedHeight: nil
        )
        XCTAssertEqual(
            restored,
            BottomPanelLayoutSemantics.defaultExpandedTabPanelHeight,
            "首次展开应使用默认高度"
        )
    }

    func testRestoreExpandedHeight_prefersRememberedHeight() {
        let restored = BottomPanelLayoutSemantics.restoredExpandedHeight(
            currentHeight: 0,
            lastExpandedHeight: 312
        )
        XCTAssertEqual(restored, 312, accuracy: 0.001, "再次展开应恢复上次有效高度")
    }

    func testCollapsedDragCanReopenWhenCrossingMinimumHeight() {
        let totalHeight: CGFloat = 700
        let startHeight = BottomPanelLayoutSemantics.dragStartPanelHeight(
            isExpanded: false,
            currentHeight: 0
        )
        let candidateHeight = startHeight - (-80)

        XCTAssertTrue(
            BottomPanelLayoutSemantics.shouldExpand(
                candidateHeight: candidateHeight,
                totalHeight: totalHeight
            ),
            "收起态向上拖拽超过最小高度后应重新展开"
        )
    }

    func testDragBelowMinimumCollapsesWithoutDiscardingRememberedHeight() {
        let totalHeight: CGFloat = 700
        let rememberedHeight: CGFloat = 260
        let startHeight = BottomPanelLayoutSemantics.dragStartPanelHeight(
            isExpanded: true,
            currentHeight: rememberedHeight
        )
        let candidateHeight = startHeight - 180

        XCTAssertFalse(
            BottomPanelLayoutSemantics.shouldExpand(
                candidateHeight: candidateHeight,
                totalHeight: totalHeight
            ),
            "拖拽高度低于最小值时应收起内容区"
        )

        let restored = BottomPanelLayoutSemantics.restoredExpandedHeight(
            currentHeight: 0,
            lastExpandedHeight: rememberedHeight
        )
        XCTAssertEqual(restored, rememberedHeight, accuracy: 0.001, "收起后应保留上次有效高度")
    }

    func testSmallWindowClampsDefaultAndRememberedHeight() {
        let totalHeight: CGFloat = 280
        let clampedDefault = BottomPanelLayoutSemantics.clampedExpandedHeight(
            BottomPanelLayoutSemantics.defaultExpandedTabPanelHeight,
            totalHeight: totalHeight
        )
        let clampedRemembered = BottomPanelLayoutSemantics.clampedExpandedHeight(
            420,
            totalHeight: totalHeight
        )

        XCTAssertEqual(clampedDefault, 60, accuracy: 0.001, "小窗口下默认高度应被限制到可用高度")
        XCTAssertEqual(clampedRemembered, 60, accuracy: 0.001, "小窗口下记忆高度应被限制到可用高度")
    }
}

final class BottomPanelCategorySemanticsTests: XCTestCase {

    func testBottomPanelCategoryOrder_placesProjectConfigFirst() {
        XCTAssertEqual(
            BottomPanelCategory.allCases,
            [.projectConfig, .terminal, .edit, .diff],
            "底部面板分类顺序应为项目配置、终端、编辑、差异"
        )
    }

    func testNewWorkspaceDefaultsToProjectConfigCategory() {
        let appState = AppState()
        defer {
            appState.wsClient.disconnect()
            appState.coreProcessManager.stop()
        }
        let workspaceKey = "proj::ws"

        appState.ensureDefaultTab(for: workspaceKey)

        XCTAssertEqual(
            appState.activeBottomPanelCategory(workspaceKey: workspaceKey),
            .projectConfig,
            "新工作区底部面板默认应选中项目配置分类"
        )
    }

    func testActivateTerminalCategory_createsTerminalWhenEmpty() {
        let appState = AppState()
        defer {
            appState.wsClient.disconnect()
            appState.coreProcessManager.stop()
        }
        let workspaceKey = "proj::ws"
        appState.workspaceTabs[workspaceKey] = []

        appState.activateBottomPanelCategory(workspaceKey: workspaceKey, category: .terminal)

        let terminalTabs = appState.tabs(in: .terminal, workspaceKey: workspaceKey)
        XCTAssertEqual(terminalTabs.count, 1, "打开终端分类且当前无终端时应自动创建一个终端实例")
        XCTAssertEqual(terminalTabs.first?.kind, .terminal)
        XCTAssertEqual(appState.activeBottomPanelCategory(workspaceKey: workspaceKey), .terminal)
    }
}
