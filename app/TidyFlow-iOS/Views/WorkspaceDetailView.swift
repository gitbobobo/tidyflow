import SwiftUI
import UIKit

/// 工作空间详情页：终端、后台任务、代码变更汇总与工具栏操作。
struct WorkspaceDetailView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    private var terminals: [TerminalSessionInfo] {
        appState.terminalsForWorkspace(project: project, workspace: workspace)
    }

    private var runningTasks: [MobileWorkspaceTask] {
        appState.runningTasksForWorkspace(project: project, workspace: workspace)
    }

    private var allTasks: [MobileWorkspaceTask] {
        appState.tasksForWorkspace(project: project, workspace: workspace)
    }

    private var completedTaskCount: Int {
        allTasks.filter { !$0.status.isActive }.count
    }

    private var pendingTodoCount: Int {
        appState.pendingTodoCountForWorkspace(project: project, workspace: workspace)
    }

    /// 使用共享语义快照，消除与 MobileWorkspaceGitSummary 的重复状态
    private var gitSnapshot: GitPanelSemanticSnapshot {
        appState.gitDetailStateForWorkspace(project: project, workspace: workspace).semanticSnapshot
    }

    private var projectCommands: [ProjectCommand] {
        appState.projectCommands(for: project)
    }

    var body: some View {
        List {
            Section("代码变更") {
                NavigationLink(value: MobileRoute.workspaceGit(project: project, workspace: workspace)) {
                    HStack(spacing: 16) {
                        Label("+\(gitSnapshot.totalAdditions)", systemImage: "plus")
                            .foregroundColor(.green)
                        Label("-\(gitSnapshot.totalDeletions)", systemImage: "minus")
                            .foregroundColor(.red)
                        Spacer()
                        if let branch = gitSnapshot.defaultBranch, !branch.isEmpty {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.headline)
                    .padding(.vertical, 4)
                }
            }

            Section("资源管理器") {
                NavigationLink(value: MobileRoute.workspaceExplorer(project: project, workspace: workspace)) {
                    Label("浏览项目文件", systemImage: "folder")
                }
                Text("iOS 暂不支持外部改动冲突的重载/覆盖/比较三路处理，请在 macOS 端完成。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section("活跃终端") {
                if terminals.isEmpty {
                    Text("暂无活跃终端")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(terminals.enumerated()), id: \.element.termId) { index, term in
                        NavigationLink(value: MobileRoute.terminalAttach(
                            project: project,
                            workspace: workspace,
                            termId: term.termId
                        )) {
                            HStack(spacing: 10) {
                                let presentation = appState.terminalPresentation(for: term.termId)
                                MobileCommandIconView(
                                    iconName: presentation?.icon ?? "terminal",
                                    size: 18
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(presentation?.name ?? "终端 \(index + 1)")
                                        .font(.body)
                                    Text(String(term.termId.prefix(8)))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if presentation?.isPinned == true {
                                    Image(systemName: "pin.fill")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .contextMenu {
                            Button(appState.isTerminalPinned(termId: term.termId) ? "取消固定" : "固定") {
                                appState.toggleTerminalPinned(termId: term.termId)
                            }
                            Divider()
                            Button("关闭其他") {
                                appState.closeOtherTerminals(project: project, workspace: workspace, keepTermId: term.termId)
                            }
                            let hasRight = index < terminals.count - 1
                            Button("关闭右侧") {
                                appState.closeTerminalsToRight(project: project, workspace: workspace, termId: term.termId)
                            }
                            .disabled(!hasRight)
                            Divider()
                            Button(role: .destructive) {
                                appState.closeTerminal(termId: term.termId)
                            } label: {
                                Label("终止", systemImage: "xmark.circle")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.closeTerminal(termId: term.termId)
                            } label: {
                                Label("终止", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }

            Section("后台任务") {
                if runningTasks.isEmpty {
                    Text("当前无进行中的后台任务")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(runningTasks) { task in
                        HStack(spacing: 10) {
                            MobileCommandIconView(iconName: task.icon, size: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                Text(task.message)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if appState.canCancelTask(task) {
                                Button {
                                    appState.cancelTask(task)
                                } label: {
                                    Image(systemName: "stop.circle")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            ProgressView()
                                .scaleEffect(0.9)
                        }
                        .padding(.vertical, 2)
                    }
                }

                NavigationLink(value: MobileRoute.workspaceTasks(project: project, workspace: workspace)) {
                    HStack {
                        Text("查看全部任务")
                        Spacer()
                        if completedTaskCount > 0 {
                            Text("\(completedTaskCount)")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.secondary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Section("待办事项") {
                NavigationLink(value: MobileRoute.workspaceTodos(project: project, workspace: workspace)) {
                    HStack {
                        Text("查看待办")
                        Spacer()
                        if pendingTodoCount > 0 {
                            Text("\(pendingTodoCount)")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .navigationTitle(workspace)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                evidenceButton
                evolutionButton
                aiChatButton
                moreActionsMenu
            }
        }
        .refreshable {
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
        .onAppear {
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
    }

    private var evidenceButton: some View {
        Button {
            appState.navigationPath.append(MobileRoute.evidence(project: project, workspace: workspace))
        } label: {
            Image(systemName: "photo.stack")
        }
    }

    private var evolutionButton: some View {
        Button {
            appState.navigationPath.append(MobileRoute.evolution(project: project, workspace: workspace))
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
    }

    private var aiChatButton: some View {
        Button {
            appState.navigationPath.append(MobileRoute.aiChat(project: project, workspace: workspace))
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
        }
    }

    private var moreActionsMenu: some View {
        Menu {
            Menu("新建终端") {
                Button {
                    appState.navigationPath.append(MobileRoute.terminal(project: project, workspace: workspace))
                } label: {
                    Label("新建终端", systemImage: "terminal")
                }

                if !appState.customCommands.isEmpty {
                    Divider()
                    ForEach(appState.customCommands) { cmd in
                        Button {
                            appState.navigationPath.append(MobileRoute.terminal(
                                project: project,
                                workspace: workspace,
                                command: cmd.command,
                                commandIcon: cmd.icon,
                                commandName: cmd.name
                            ))
                        } label: {
                            Label {
                                Text(cmd.name)
                            } icon: {
                                MobileCommandIconView(iconName: cmd.icon, size: 14)
                            }
                        }
                    }
                }
            }

            Button {
                appState.navigationPath.append(MobileRoute.workspaceExplorer(project: project, workspace: workspace))
            } label: {
                Label("资源管理器", systemImage: "folder")
            }

            Button {
                appState.runAICommit(project: project, workspace: workspace)
            } label: {
                Label("一键提交", systemImage: "sparkles")
            }

            Button {
                appState.runAIMerge(project: project, workspace: workspace)
            } label: {
                Label("智能合并", systemImage: "cpu")
            }

            Menu("执行") {
                if projectCommands.isEmpty {
                    Text("当前项目未配置命令")
                } else {
                    ForEach(projectCommands) { command in
                        Button {
                            appState.runProjectCommand(project: project, workspace: workspace, command: command)
                        } label: {
                            Label {
                                Text(command.name)
                            } icon: {
                                MobileCommandIconView(iconName: command.icon, size: 14)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

/// iOS 资源管理器（轻交互）：目录浏览 + 新建/重命名/删除 + 文本预览
struct WorkspaceExplorerView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    private var rootCache: FileListCache? {
        appState.explorerListCache(project: project, workspace: workspace, path: ".")
    }

    var body: some View {
        List {
            if let cache = rootCache {
                if cache.isLoading && cache.items.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("加载中...")
                            .foregroundColor(.secondary)
                    }
                } else if let error = cache.error, cache.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .foregroundColor(.secondary)
                        Button("重试") {
                            appState.fetchExplorerFileList(project: project, workspace: workspace, path: ".")
                        }
                    }
                } else if cache.items.isEmpty {
                    ContentUnavailableView("当前目录为空", systemImage: "folder")
                } else {
                    ForEach(cache.items) { item in
                        ExplorerFileRowView(
                            project: project,
                            workspace: workspace,
                            item: item,
                            depth: 0
                        )
                        .environmentObject(appState)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("加载中...")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("资源管理器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.refreshExplorer(project: project, workspace: workspace)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $appState.explorerPreviewPresented) {
            ExplorerFilePreviewSheet()
                .environmentObject(appState)
        }
        .onAppear {
            appState.prepareExplorer(project: project, workspace: workspace)
        }
    }
}

private struct ExplorerFileRowView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String
    let item: FileEntry
    let depth: Int

    @State private var showRenameDialog = false
    @State private var showDeleteConfirm = false
    @State private var showNewFileDialog = false
    @State private var newName = ""
    @State private var newFileName = ""

    private var isExpanded: Bool {
        appState.isExplorerDirectoryExpanded(project: project, workspace: workspace, path: item.path)
    }

    private var childrenCache: FileListCache? {
        appState.explorerListCache(project: project, workspace: workspace, path: item.path)
    }

    private var indent: CGFloat {
        CGFloat(depth) * 14
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if item.isDir {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }

                Image(systemName: item.isDir ? (isExpanded ? "folder.fill" : "folder") : "doc.text")
                    .foregroundColor(item.isDir ? .accentColor : .secondary)
                Text(item.name)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.leading, indent)
            .padding(.vertical, 6)
            .onTapGesture {
                if item.isDir {
                    appState.toggleExplorerDirectory(project: project, workspace: workspace, path: item.path)
                } else {
                    appState.readFileForPreview(project: project, workspace: workspace, path: item.path)
                }
            }
            .contextMenu {
                if item.isDir {
                    Button {
                        newFileName = ""
                        showNewFileDialog = true
                    } label: {
                        Label("新建文件", systemImage: "doc.badge.plus")
                    }
                }

                Button {
                    newName = item.name
                    showRenameDialog = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .sheet(isPresented: $showNewFileDialog) {
                NewFileDialogView(
                    fileName: $newFileName,
                    onConfirm: {
                        let parentDir = item.path
                        appState.createExplorerFile(
                            project: project,
                            workspace: workspace,
                            parentDir: parentDir,
                            fileName: newFileName
                        )
                        showNewFileDialog = false
                    },
                    onCancel: {
                        showNewFileDialog = false
                    }
                )
            }
            .sheet(isPresented: $showRenameDialog) {
                RenameDialogView(
                    originalName: item.name,
                    newName: $newName,
                    isDir: item.isDir,
                    onConfirm: {
                        appState.renameExplorerFile(
                            project: project,
                            workspace: workspace,
                            path: item.path,
                            newName: newName
                        )
                        showRenameDialog = false
                    },
                    onCancel: {
                        showRenameDialog = false
                    }
                )
            }
            .confirmationDialog(
                "确认删除 \(item.name)？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    appState.deleteExplorerFile(project: project, workspace: workspace, path: item.path)
                }
                Button("取消", role: .cancel) {}
            }

            if item.isDir && isExpanded {
                if let childrenCache {
                    if childrenCache.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.85)
                            Text("加载中...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, indent + 26)
                        .padding(.vertical, 4)
                    } else if let error = childrenCache.error, childrenCache.items.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, indent + 26)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(childrenCache.items) { child in
                            ExplorerFileRowView(
                                project: project,
                                workspace: workspace,
                                item: child,
                                depth: depth + 1
                            )
                            .environmentObject(appState)
                        }
                    }
                }
            }
        }
    }
}

private struct ExplorerFilePreviewSheet: View {
    @EnvironmentObject var appState: MobileAppState

    var body: some View {
        NavigationStack {
            Group {
                if appState.explorerPreviewLoading {
                    ProgressView("正在读取文件...")
                } else if let error = appState.explorerPreviewError {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(error)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    ScrollView {
                        Text(appState.explorerPreviewContent)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .navigationTitle(appState.explorerPreviewPath ?? "文件预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        appState.explorerPreviewPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - Evidence Tab Types (iOS)
// MobileEvidenceTabType 已统一为 EvidenceTabType（定义于 TabContentHostView.swift），两端共享语义。

struct MobileEvidenceView: View {
    @EnvironmentObject var appState: MobileAppState

    let project: String
    let workspace: String

    @State private var selectedTab: EvidenceTabType = .screenshot
    @State private var selectedScreenshotID: String?
    @State private var selectedLogID: String?
    @State private var itemLoading: Bool = false
    @State private var itemPaging: Bool = false
    @State private var itemError: String?
    @State private var itemTextChunks: [String] = []
    @State private var itemTextNextOffset: UInt64 = 0
    @State private var itemTextHasMore: Bool = false
    @State private var itemImage: UIImage?
    @State private var itemByteCount: Int = 0
    @State private var headerHint: String?
    @State private var showingDetailSheet: Bool = false
    @State private var screenshotThumbnails: [String: UIImage] = [:]
    @State private var screenshotThumbnailLoadingIDs: Set<String> = []
    @State private var screenshotThumbnailLoadFailedIDs: Set<String> = []
    @State private var screenshotThumbnailPendingIDs: [String] = []
    @State private var screenshotThumbnailActiveID: String?
    @State private var screenshotThumbnailRequestSequence: UInt64 = 0

    private var snapshot: EvidenceSnapshotV2? {
        appState.evidenceSnapshot(project: project, workspace: workspace)
    }

    private var snapshotLoading: Bool {
        appState.isEvidenceLoading(project: project, workspace: workspace)
    }

    private var snapshotError: String? {
        appState.evidenceError(project: project, workspace: workspace)
    }
    
    /// 根据当前选中的标签页获取对应的证据条目
    private var currentTabItems: [EvidenceItemInfoV2] {
        guard let snapshot else { return [] }
        return selectedTab.filteredItems(from: snapshot)
    }
    
    /// 获取当前标签页下的设备类型列表（保持原有顺序）
    private var currentTabDeviceTypes: [String] {
        let deviceTypes = currentTabItems.map { $0.deviceType }
        var seen = Set<String>()
        var result: [String] = []
        for type in deviceTypes {
            if !seen.contains(type) {
                seen.insert(type)
                result.append(type)
            }
        }
        return result
    }
    
    /// 获取指定设备类型的条目
    private func items(for deviceType: String) -> [EvidenceItemInfoV2] {
        currentTabItems.filter { $0.deviceType == deviceType }
    }

    var body: some View {
        List {
            // 重建按钮
            Section {
                Button("重建全链路证据") {
                    rebuildEvidence()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appState.isConnected)
                if let headerHint, !headerHint.isEmpty {
                    Text(headerHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // 类型切换 Tab 栏（与 macOS TabContentHostView 按钮式 Tab 栏语义对齐）
            Section {
                HStack(spacing: 0) {
                    ForEach(EvidenceTabType.allCases) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTab = tab
                            }
                            clearPreview()
                            stopScreenshotThumbnailPrefetch()
                            processNextScreenshotThumbnailLoadIfNeeded()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: 12))
                                Text("\(tab.displayName)(\(snapshot.map { tab.itemCount(in: $0) } ?? 0))")
                                    .font(.system(size: 12))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selectedTab == tab
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                            .contentShape(Rectangle())
                            .animation(.easeInOut(duration: 0.2), value: selectedTab)
                        }
                        .buttonStyle(.plain)

                        if tab != EvidenceTabType.allCases.last {
                            Divider()
                                .frame(height: 20)
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
            }

            if snapshotLoading && snapshot == nil {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("读取证据中...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let snapshotError, snapshot == nil {
                Section {
                    Text(snapshotError)
                        .foregroundColor(.red)
                    Button("重试") {
                        refreshEvidence()
                    }
                }
            } else if currentTabItems.isEmpty {
                Section {
                    ContentUnavailableView(
                        selectedTab.emptyStateText,
                        systemImage: selectedTab.iconName
                    )
                }
            } else if snapshot != nil {
                // 按设备类型分组展示
                ForEach(currentTabDeviceTypes, id: \.self) { deviceType in
                    deviceSection(deviceType: deviceType, items: items(for: deviceType))
                }
            } else {
                Section {
                    Text("暂无证据数据")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("证据")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refreshEvidence()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showingDetailSheet) {
            detailSheet
        }
        .onAppear {
            refreshEvidence()
            syncSelectionIfNeeded()
        }
        .onReceive(appState.$evidenceSnapshotsByWorkspace) { _ in
            syncSelectionIfNeeded()
            pruneScreenshotThumbnailCache()
            processNextScreenshotThumbnailLoadIfNeeded()
        }
        .onChange(of: appState.isConnected) { _, connected in
            guard connected else { return }
            refreshEvidence()
        }
        .onChange(of: showingDetailSheet) { _, showing in
            if showing {
                stopScreenshotThumbnailPrefetch()
            } else {
                processNextScreenshotThumbnailLoadIfNeeded()
            }
        }
    }
    
    /// 设备分组 Section
    @ViewBuilder
    private func deviceSection(deviceType: String, items: [EvidenceItemInfoV2]) -> some View {
        if selectedTab == .screenshot {
            // 截图使用网格布局
            Section("\(deviceType) (\(items.count)张)") {
                screenshotGrid(items: items)
            }
        } else {
            // 日志使用列表布局
            Section(deviceType) {
                ForEach(items, id: \.itemID) { item in
                    logRow(item: item)
                }
            }
        }
    }

    private func screenshotGrid(items: [EvidenceItemInfoV2]) -> some View {
        return LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 12)
            ],
            spacing: 12
        ) {
            ForEach(items, id: \.itemID) { item in
                screenshotThumbnail(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
    
    /// 截图缩略图
    private func screenshotThumbnail(item: EvidenceItemInfoV2) -> some View {
        let thumbnailHeight: CGFloat = 64
        return Button {
            selectedScreenshotID = item.itemID
            showingDetailSheet = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    if let thumbnail = screenshotThumbnails[item.itemID] {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary.opacity(0.5))
                        if screenshotThumbnailLoadingIDs.contains(item.itemID) {
                            ProgressView()
                                .controlSize(.small)
                                .offset(y: 16)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: thumbnailHeight)
                .clipped()
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            selectedScreenshotID == item.itemID ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
                .clipShape(.rect(cornerRadius: 6))
                
                Text("#\(item.order)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            enqueueScreenshotThumbnailLoad(for: item)
        }
    }
    
    /// 日志列表行
    private func logRow(item: EvidenceItemInfoV2) -> some View {
        Button {
            selectedLogID = item.itemID
            showingDetailSheet = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("#\(item.order) \(item.title)")
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    if !item.description.isEmpty && item.description != item.title {
                        Text(item.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Text(item.path)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
                
                Spacer()
                
                if item.sizeBytes > 0 {
                    Text(formatByteCount(item.sizeBytes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedLogID == item.itemID ? Color.accentColor.opacity(0.12) : Color.clear
        )
    }
    
    /// 格式化字节数
    private func formatByteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    /// 当前选中的条目
    private var currentSelectedItem: EvidenceItemInfoV2? {
        let selectedID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        if let id = selectedID {
            return currentTabItems.first { $0.itemID == id }
        }
        return nil
    }
    
    /// 详情 Sheet
    private var detailSheet: some View {
        NavigationStack {
            Group {
                if let item = currentSelectedItem {
                    detailContent(for: item)
                } else {
                    ContentUnavailableView("无内容", systemImage: "doc")
                }
            }
            .navigationTitle(currentSelectedItem?.title ?? "详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        showingDetailSheet = false
                    }
                }
            }
        }
    }
    
    /// 详情内容
    @ViewBuilder
    private func detailContent(for item: EvidenceItemInfoV2) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 信息卡片
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.headline)
                    if !item.description.isEmpty {
                        Text(item.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text(item.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if item.sizeBytes > 0 {
                            Text(formatByteCount(item.sizeBytes))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
                
                // 内容区域
                if itemLoading {
                    ProgressView("加载内容中...")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let itemError {
                    ContentUnavailableView(
                        "加载失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(itemError)
                    )
                } else if let itemImage, selectedTab == .screenshot {
                    Image(uiImage: itemImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: 10))
                } else if !itemTextChunks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(itemTextChunks.indices, id: \.self) { idx in
                            Text(itemTextChunks[idx])
                                .font(.system(.footnote, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if itemPaging || itemTextHasMore {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(itemPaging ? "加载更多中..." : "滚动到底部继续加载")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                            .onAppear {
                                loadNextTextPageIfNeeded(for: item)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(10)
                } else {
                    ContentUnavailableView(
                        "无法预览",
                        systemImage: "doc",
                        description: Text("该文件格式暂不支持预览")
                    )
                }
            }
            .padding()
        }
        .onAppear {
            loadItemIfNeeded(item)
        }
        .onChange(of: item.itemID) { _, _ in
            loadItem(item)
        }
    }
    
    private func loadItemIfNeeded(_ item: EvidenceItemInfoV2) {
        let currentID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        if currentID != item.itemID {
            if selectedTab == .screenshot {
                selectedScreenshotID = item.itemID
            } else {
                selectedLogID = item.itemID
            }
            loadItem(item)
        } else if itemTextChunks.isEmpty && itemImage == nil && !itemLoading && itemError == nil {
            loadItem(item)
        }
    }

    private func syncSelectionIfNeeded() {
        guard let snapshot else { return }
        var shouldClearPreview = false
        if let screenshotID = selectedScreenshotID,
           !snapshot.items.contains(where: { $0.itemID == screenshotID }) {
            selectedScreenshotID = nil
            shouldClearPreview = shouldClearPreview || selectedTab == .screenshot
        }
        if let logID = selectedLogID,
           !snapshot.items.contains(where: { $0.itemID == logID }) {
            selectedLogID = nil
            shouldClearPreview = shouldClearPreview || selectedTab == .log
        }
        if shouldClearPreview {
            clearPreview()
        }
    }

    private func clearPreview() {
        itemLoading = false
        itemPaging = false
        itemError = nil
        itemTextChunks = []
        itemTextNextOffset = 0
        itemTextHasMore = false
        itemImage = nil
        itemByteCount = 0
    }

    private func stopScreenshotThumbnailPrefetch() {
        screenshotThumbnailPendingIDs.removeAll()
        screenshotThumbnailActiveID = nil
        screenshotThumbnailLoadingIDs.removeAll()
        screenshotThumbnailRequestSequence &+= 1
    }

    private func pruneScreenshotThumbnailCache() {
        guard let snapshot else {
            screenshotThumbnails.removeAll()
            screenshotThumbnailLoadFailedIDs.removeAll()
            stopScreenshotThumbnailPrefetch()
            return
        }
        let validIDs = Set(
            snapshot.items.compactMap { item -> String? in
                if item.evidenceType == "screenshot" || item.mimeType.hasPrefix("image/") {
                    return item.itemID
                }
                return nil
            }
        )
        screenshotThumbnails = screenshotThumbnails.filter { validIDs.contains($0.key) }
        screenshotThumbnailLoadFailedIDs = screenshotThumbnailLoadFailedIDs.intersection(validIDs)
        screenshotThumbnailPendingIDs.removeAll { !validIDs.contains($0) }
        if let activeID = screenshotThumbnailActiveID, !validIDs.contains(activeID) {
            screenshotThumbnailActiveID = nil
            screenshotThumbnailLoadingIDs.remove(activeID)
        }
    }

    private var canPrefetchScreenshotThumbnails: Bool {
        selectedTab == .screenshot && !showingDetailSheet
    }

    private func enqueueScreenshotThumbnailLoad(for item: EvidenceItemInfoV2) {
        guard canPrefetchScreenshotThumbnails else { return }
        guard screenshotThumbnails[item.itemID] == nil else { return }
        guard !screenshotThumbnailLoadingIDs.contains(item.itemID) else { return }
        guard !screenshotThumbnailLoadFailedIDs.contains(item.itemID) else { return }
        guard !screenshotThumbnailPendingIDs.contains(item.itemID) else { return }
        guard item.mimeType.hasPrefix("image/") || item.evidenceType == "screenshot" else { return }
        screenshotThumbnailPendingIDs.append(item.itemID)
        processNextScreenshotThumbnailLoadIfNeeded()
    }

    private func processNextScreenshotThumbnailLoadIfNeeded() {
        guard canPrefetchScreenshotThumbnails else { return }
        guard screenshotThumbnailActiveID == nil else { return }

        while !screenshotThumbnailPendingIDs.isEmpty {
            let itemID = screenshotThumbnailPendingIDs.removeFirst()
            guard screenshotThumbnails[itemID] == nil else { continue }
            guard !screenshotThumbnailLoadFailedIDs.contains(itemID) else { continue }
            guard let item = currentTabItems.first(where: { $0.itemID == itemID }) else { continue }
            guard item.mimeType.hasPrefix("image/") || item.evidenceType == "screenshot" else { continue }

            screenshotThumbnailActiveID = itemID
            screenshotThumbnailLoadingIDs.insert(itemID)
            screenshotThumbnailRequestSequence &+= 1
            let requestSequence = screenshotThumbnailRequestSequence

            appState.readEvidenceItem(project: project, workspace: workspace, itemID: itemID) { payload, _ in
                DispatchQueue.main.async {
                    finalizeScreenshotThumbnailRequest(
                        itemID: itemID,
                        requestSequence: requestSequence,
                        payload: payload
                    )
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                finalizeScreenshotThumbnailRequest(
                    itemID: itemID,
                    requestSequence: requestSequence,
                    payload: nil
                )
            }
            return
        }
    }

    private func finalizeScreenshotThumbnailRequest(
        itemID: String,
        requestSequence: UInt64,
        payload: (mimeType: String, content: [UInt8])?
    ) {
        guard screenshotThumbnailActiveID == itemID else { return }
        guard screenshotThumbnailRequestSequence == requestSequence else { return }

        screenshotThumbnailLoadingIDs.remove(itemID)
        screenshotThumbnailActiveID = nil

        if let payload, let thumbnail = UIImage(data: Data(payload.content)) {
            screenshotThumbnails[itemID] = thumbnail
        } else {
            screenshotThumbnailLoadFailedIDs.insert(itemID)
        }

        processNextScreenshotThumbnailLoadIfNeeded()
    }

    private func refreshEvidence() {
        appState.requestEvidenceSnapshot(project: project, workspace: workspace)
    }

    private func rebuildEvidence() {
        appState.requestEvidenceRebuildPrompt(project: project, workspace: workspace) { prompt, errorMessage in
            DispatchQueue.main.async {
                if let prompt {
                    UIPasteboard.general.string = prompt.prompt
                    appState.setAIChatOneShotHint(
                        project: prompt.project,
                        workspace: prompt.workspace,
                        message: "提示词已复制，请在聊天输入框粘贴后发送。"
                    )
                    headerHint = "已复制提示词，正在跳转聊天页..."
                    appState.navigationPath.append(MobileRoute.aiChat(project: project, workspace: workspace))
                } else {
                    let error = errorMessage ?? "未知错误"
                    headerHint = "生成失败：\(error)"
                }
            }
        }
    }

    private func loadItem(_ item: EvidenceItemInfoV2) {
        itemLoading = true
        itemPaging = false
        itemError = nil
        itemTextChunks = []
        itemTextNextOffset = 0
        itemTextHasMore = false
        itemImage = nil
        itemByteCount = 0

        if item.mimeType.hasPrefix("image/") || item.evidenceType == "screenshot" {
            appState.readEvidenceItem(project: project, workspace: workspace, itemID: item.itemID) { payload, errorMessage in
                DispatchQueue.main.async {
                    let currentID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
                    guard currentID == item.itemID else { return }
                    itemLoading = false
                    if let payload {
                        itemByteCount = payload.content.count
                        if let image = UIImage(data: Data(payload.content)) {
                            itemImage = image
                            return
                        }
                        itemError = "图片解码失败"
                    } else {
                        itemError = errorMessage ?? "未知错误"
                    }
                }
            }
            return
        }

        loadNextTextPage(for: item, reset: true)
    }

    private func loadNextTextPageIfNeeded(for item: EvidenceItemInfoV2) {
        let currentID = selectedTab == .screenshot ? selectedScreenshotID : selectedLogID
        guard currentID == item.itemID else { return }
        guard itemTextHasMore, !itemPaging, !itemLoading else { return }
        loadNextTextPage(for: item, reset: false)
    }

    private func loadNextTextPage(for item: EvidenceItemInfoV2, reset: Bool) {
        let offset: UInt64 = reset ? 0 : itemTextNextOffset
        if !reset, offset == 0 {
            return
        }
        itemPaging = true
        appState.readEvidenceItemPage(
            project: project,
            workspace: workspace,
            itemID: item.itemID,
            offset: offset,
            limit: 131_072
        ) { payload, errorMessage in
            DispatchQueue.main.async {
                let currentID = self.selectedTab == .screenshot ? self.selectedScreenshotID : self.selectedLogID
                guard currentID == item.itemID else { return }
                itemLoading = false
                itemPaging = false
                if let payload {
                    itemByteCount = Int(payload.totalSizeBytes)
                    let text = String(data: Data(payload.content), encoding: .utf8) ?? String(decoding: payload.content, as: UTF8.self)
                    if reset {
                        itemTextChunks = [text]
                    } else {
                        itemTextChunks.append(text)
                    }
                    itemTextNextOffset = payload.nextOffset
                    itemTextHasMore = !payload.eof
                    return
                }
                itemError = errorMessage ?? "未知错误"
            }
        }
    }
}

private struct EvolutionProfileDraft: Identifiable {
    let id: String
    let stage: String
    var aiTool: AIChatTool
    var mode: String
    var providerID: String
    var modelID: String
    var configOptions: [String: Any]
}

struct MobileEvolutionView: View {
    @EnvironmentObject var appState: MobileAppState

    let project: String
    let workspace: String

    @State private var loopRoundLimitText: String = "1"
    @State private var profiles: [EvolutionProfileDraft] = []
    @State private var isApplyingRemoteProfiles: Bool = false
    @State private var lastSyncedProfileSignature: String = ""
    @State private var pendingProfileSaveSignature: String?
    @State private var pendingProfileSaveDate: Date?
    @State private var hasPendingUserProfileEdit: Bool = false
    @State private var blockerDrafts: [String: EvolutionBlockerDraft] = [:]
    @State private var isPlanDocumentSheetPresented: Bool = false
    @State private var selectedPlanDocumentCycleID: String?
    @State private var selectedCycleDetail: MobileCycleDetailPayload?

    private struct EvolutionBlockerDraft {
        var selected: Bool
        var selectedOptionID: String
        var answerText: String
    }

    private var item: EvolutionWorkspaceItemV2? {
        appState.evolutionItem(project: project, workspace: workspace)
    }
    private var controlState: (
        canStart: Bool,
        canStop: Bool,
        canResume: Bool,
        isStartPending: Bool,
        isStopPending: Bool,
        isResumePending: Bool
    ) {
        appState.evolutionControlState(project: project, workspace: workspace)
    }
    private var primaryControlShowsStop: Bool {
        controlState.canStop || controlState.isStopPending
    }
    private var canTriggerPrimaryControlAction: Bool {
        controlState.canStart || controlState.canStop
    }
    private var primaryControlButtonTitle: String {
        primaryControlShowsStop
            ? "evolution.page.action.stop".localized
            : "evolution.page.action.startManual".localized
    }
    private var primaryControlButtonSymbol: String {
        if primaryControlShowsStop {
            return controlState.isStopPending ? "clock" : "stop.fill"
        }
        return controlState.isStartPending ? "clock" : "play.fill"
    }
    private var primaryControlButtonTint: Color {
        primaryControlShowsStop ? .red : .green
    }
    private let evolutionStageOrder: [String] = [
        "direction",
        "plan",
        "implement_general",
        "implement_visual",
        "implement_advanced",
        "verify",
        "judge",
        "auto_commit",
    ]

    var body: some View {
        List {
            Section("evolution.page.scheduler.section".localized) {
                LabeledContent("evolution.page.scheduler.activation".localized) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isSchedulerActive(appState.evolutionScheduler.activationState) ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(localizedSchedulerActivationDisplay(appState.evolutionScheduler.activationState))
                    }
                }
                LabeledContent("evolution.page.scheduler.maxParallel".localized) {
                    Text("\(appState.evolutionScheduler.maxParallelWorkspaces)")
                }
                LabeledContent("evolution.page.scheduler.runningQueued".localized) {
                    Text("\(appState.evolutionScheduler.runningCount) / \(appState.evolutionScheduler.queuedCount)")
                }
            }

            Section("evolution.page.workspace.section".localized) {
                LabeledContent("evolution.page.workspace.currentWorkspace".localized) {
                    Text("\(project)/\(workspace)")
                }
                if let item {
                    LabeledContent("evolution.page.workspace.status".localized) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(mobileWorkspaceStatusColor(item.status))
                                .frame(width: 8, height: 8)
                            Text(localizedWorkspaceStatusDisplay(item.status))
                        }
                    }
                    LabeledContent("evolution.page.workspace.currentStage".localized) {
                        Text(stageDisplayName(item.currentStage))
                    }
                    LabeledContent("evolution.page.workspace.loopRound".localized) {
                        Text("\(item.globalLoopRound)/\(max(1, item.loopRoundLimit))")
                    }
                    LabeledContent("循环标题") {
                        Text(mobileCycleDisplayTitle(item.title))
                    }
                    LabeledContent("evolution.page.workspace.verifyRound".localized) {
                        Text("\(item.verifyIteration)/\(item.verifyIterationLimit)")
                    }
                    LabeledContent("evolution.page.workspace.activeAgents".localized) {
                        Text(
                            item.activeAgents.isEmpty
                                ? "evolution.page.workspace.noActiveAgents".localized
                                : item.activeAgents.joined(separator: ", ")
                        )
                            .lineLimit(1)
                    }
                    // 终止原因
                    if let reason = trimmedNonEmptyText(item.terminalReasonCode) {
                        LabeledContent("evolution.page.pipeline.terminalReason".localized) {
                            Text(mobileLocalizedTerminalReason(reason))
                                .foregroundColor(.red)
                                .lineLimit(2)
                        }
                    }
                    if let terminalError = trimmedNonEmptyText(item.terminalErrorMessage) {
                        LabeledContent("evolution.page.pipeline.terminalError".localized) {
                            Text(terminalError)
                                .foregroundColor(.red)
                                .lineLimit(4)
                                .font(.caption)
                        }
                    }
                    // 限流错误信息
                    if let rateLimitMsg = trimmedNonEmptyText(item.rateLimitErrorMessage) {
                        LabeledContent("evolution.page.pipeline.rateLimitError".localized) {
                            Text(rateLimitMsg)
                                .foregroundColor(.orange)
                                .lineLimit(3)
                                .font(.caption)
                        }
                    }
                } else {
                    Text("evolution.page.workspace.notStarted".localized)
                        .foregroundColor(.secondary)
                }

                LabeledContent("evolution.page.workspace.loopRoundInput".localized) {
                    HStack(spacing: 6) {
                        TextField("evolution.page.workspace.loopRoundInput".localized, text: $loopRoundLimitText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                            .disabled(!controlState.canStart)
                        // WI-004：运行中支持 +1/-1 快捷调整循环轮次
                        if controlState.canStop {
                            HStack(spacing: 4) {
                                Button {
                                    let current = Int(loopRoundLimitText) ?? 1
                                    let newVal = max(1, current - 1)
                                    loopRoundLimitText = "\(newVal)"
                                    appState.adjustEvolutionLoopRound(project: project, workspace: workspace, loopRoundLimit: newVal)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .disabled((Int(loopRoundLimitText) ?? 1) <= 1)

                                Button {
                                    let current = Int(loopRoundLimitText) ?? 1
                                    let newVal = current + 1
                                    loopRoundLimitText = "\(newVal)"
                                    appState.adjustEvolutionLoopRound(project: project, workspace: workspace, loopRoundLimit: newVal)
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Text("evolution.page.workspace.verifyLoopFixed".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Button {
                        triggerPrimaryControlAction()
                    } label: {
                        Label(primaryControlButtonTitle, systemImage: primaryControlButtonSymbol)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(primaryControlButtonTint)
                    .disabled(!canTriggerPrimaryControlAction)
                    Button {
                        appState.resumeEvolution(project: project, workspace: workspace)
                    } label: {
                        if controlState.isResumePending {
                            Label("evolution.page.action.resume".localized, systemImage: "clock")
                        } else {
                            Label("evolution.page.action.resume".localized, systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!controlState.canResume)
                }

                Button {
                    if let item {
                        openPlanDocumentSheet(cycleID: item.cycleID)
                    }
                } label: {
                    Label("evolution.page.action.previewPlanDocument".localized, systemImage: "doc.text")
                }
                .disabled(item == nil)
            }

            Section("evolution.page.agentType.description.section".localized) {
                Text("evolution.page.agentType.description.text".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let blocking = activeBlockingRequest {
                Section("evolution.page.blocker.section".localized) {
                    Text("evolution.page.blocker.pendingHint".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "evolution.page.blocker.triggerOnly".localized, blocking.trigger))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(blocking.unresolvedItems, id: \.blockerID) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(item.title, isOn: bindingSelected(item.blockerID))
                            Text(item.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if !item.options.isEmpty {
                                Picker("evolution.page.blocker.option".localized, selection: bindingOption(item.blockerID)) {
                                    Text("evolution.page.blocker.choose".localized).tag("")
                                    ForEach(item.options, id: \.optionID) { option in
                                        Text(option.label).tag(option.optionID)
                                    }
                                }
                            }
                            if item.allowCustomInput || item.options.isEmpty {
                                TextField("evolution.page.blocker.answerInput".localized, text: bindingAnswer(item.blockerID))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button("evolution.page.blocker.submitSelected".localized) {
                        submitBlockers(blocking)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if profiles.isEmpty {
                Section("evolution.page.agentType.section".localized) {
                    Text("evolution.page.agentType.empty".localized)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach($profiles) { $profile in
                    let stage = profile.stage
                    let runtime = runtimeAgent(for: stage)
                    let statusText = runtime?.status ?? "not_started"
                    let aiToolBinding = Binding<AIChatTool>(
                        get: { profile.aiTool },
                        set: { newValue in
                            guard profile.aiTool != newValue else { return }
                            hasPendingUserProfileEdit = true
                            profile.aiTool = newValue
                            profile.configOptions = [:]
                            sanitizeProfileSelection(profileID: profile.id)
                            autoSaveProfilesIfNeeded()
                        }
                    )
                    Section(sectionTitle(for: profile, runtime: runtime)) {
                        if canOpenStageChat(stage: stage, status: statusText) {
                            LabeledContent("evolution.page.agent.status".localized) {
                                Button {
                                    guard let currentItem = item else { return }
                                    appState.openEvolutionStageChat(
                                        project: project,
                                        workspace: workspace,
                                        cycleId: currentItem.cycleID,
                                        stage: stage
                                    )
                                    appState.navigationPath.append(MobileRoute.aiChat(project: project, workspace: workspace))
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(localizedStageStatusDisplay(statusText))
                                            .foregroundColor(stageStatusColor(statusText))
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            LabeledContent("evolution.page.agent.status".localized) {
                                Text(localizedStageStatusDisplay(statusText))
                                    .foregroundColor(stageStatusColor(statusText))
                            }
                        }

                        LabeledContent("settings.evolution.aiTool".localized) {
                            Picker("", selection: aiToolBinding) {
                                ForEach(AIChatTool.allCases) { tool in
                                    Text(tool.displayName).tag(tool)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        LabeledContent("settings.evolution.mode".localized) {
                            Menu {
                                Button("settings.evolution.defaultMode".localized) {
                                    hasPendingUserProfileEdit = true
                                    profile.mode = ""
                                    autoSaveProfilesIfNeeded()
                                }
                                let options = modeOptions(for: profile.aiTool)
                                if options.isEmpty {
                                    Text("settings.evolution.noModes".localized)
                                } else {
                                    ForEach(options, id: \.self) { mode in
                                        Button(mode) {
                                            hasPendingUserProfileEdit = true
                                            profile.mode = mode
                                            applyAgentDefaultModelIfAvailable(
                                                profileID: profile.id,
                                                agentName: mode
                                            )
                                            autoSaveProfilesIfNeeded()
                                        }
                                    }
                                }
                            } label: {
                                Text(profile.mode.isEmpty ? "settings.evolution.defaultMode".localized : profile.mode)
                                    .foregroundColor(.secondary)
                            }
                        }

                        LabeledContent("settings.evolution.model".localized) {
                            Menu {
                                Button("settings.evolution.defaultModel".localized) {
                                    hasPendingUserProfileEdit = true
                                    profile.providerID = ""
                                    profile.modelID = ""
                                    autoSaveProfilesIfNeeded()
                                }
                                let providers = modelProviders(for: profile.aiTool)
                                if providers.isEmpty {
                                    Text("settings.evolution.noModels".localized)
                                } else if providers.count == 1 {
                                    if let onlyProvider = providers.first {
                                        ForEach(onlyProvider.models) { model in
                                            Button(model.name) {
                                                hasPendingUserProfileEdit = true
                                                profile.providerID = onlyProvider.id
                                                profile.modelID = model.id
                                                autoSaveProfilesIfNeeded()
                                            }
                                        }
                                    }
                                } else {
                                    ForEach(providers) { provider in
                                        Menu(provider.name) {
                                            ForEach(provider.models) { model in
                                                Button(model.name) {
                                                    hasPendingUserProfileEdit = true
                                                    profile.providerID = provider.id
                                                    profile.modelID = model.id
                                                    autoSaveProfilesIfNeeded()
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Text(selectedModelDisplayName(for: profile))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        LabeledContent("思考强度") {
                            Menu {
                                Button("默认") {
                                    hasPendingUserProfileEdit = true
                                    if let optionID = thoughtLevelOptionID(for: profile.aiTool) {
                                        profile.configOptions.removeValue(forKey: optionID)
                                    }
                                    autoSaveProfilesIfNeeded()
                                }
                                let options = thoughtLevelOptions(for: profile.aiTool)
                                if options.isEmpty {
                                    Text("未提供 thought_level 选项")
                                } else {
                                    ForEach(options, id: \.self) { option in
                                        Button(option) {
                                            hasPendingUserProfileEdit = true
                                            if let optionID = thoughtLevelOptionID(for: profile.aiTool) {
                                                profile.configOptions[optionID] = option
                                            }
                                            autoSaveProfilesIfNeeded()
                                        }
                                    }
                                }
                            } label: {
                                Text(selectedThoughtLevel(for: profile) ?? "默认")
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            let runtimeOnly = runtimeOnlyAgents()
            if !runtimeOnly.isEmpty {
                Section("evolution.page.agentList.section".localized) {
                    ForEach(Array(runtimeOnly.enumerated()), id: \.offset) { _, runtime in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(stageDisplayName(runtime.stage))
                                .font(.headline)
                            LabeledContent("evolution.page.agent.status".localized) {
                                Text(localizedStageStatusDisplay(runtime.status))
                                    .foregroundColor(stageStatusColor(runtime.status))
                            }
                            Text(String(format: "evolution.page.toolCallCount".localized, runtime.toolCallCount))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            // 历史循环
            mobileCycleHistorySection
        }
        .navigationTitle("evolution.page.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPlanDocumentSheetPresented) {
            mobilePlanDocumentSheet
        }
        .sheet(item: $selectedCycleDetail) { detail in
            mobileCycleDetailSheet(detail)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("common.refresh".localized) {
                    appState.refreshEvolution(project: project, workspace: workspace)
                    loadProfiles()
                }
            }
        }
        .onAppear {
            appState.openEvolution(project: project, workspace: workspace)
            loadProfiles()
            syncStartOptionsFromItem()
            appState.requestEvolutionCycleHistory(project: project, workspace: workspace)
        }
        .onReceive(appState.$evolutionStageProfilesByWorkspace) { _ in
            loadProfiles()
        }
        .onReceive(appState.$evolutionWorkspaceItems) { _ in
            syncStartOptionsFromItem()
        }
        .onReceive(appState.$evolutionBlockingRequired) { value in
            syncBlockingDrafts(value)
        }
        .onChange(of: appState.isConnected) { _, connected in
            guard connected else { return }
            appState.refreshEvolution(project: project, workspace: workspace)
            loadProfiles()
        }
    }

    private var mobilePlanDocumentSheet: some View {
        NavigationStack {
            Group {
                if appState.evolutionPlanDocumentLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("evolution.page.planDocument.loading".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = appState.evolutionPlanDocumentError {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content = appState.evolutionPlanDocumentContent {
                    ScrollView {
                        Text(LocalizedStringKey(content))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("evolution.page.planDocument.empty".localized)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("evolution.page.planDocument.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refreshSelectedPlanDocument()
                    } label: {
                        Label("evolution.page.planDocument.refresh".localized, systemImage: "arrow.clockwise")
                    }
                    .disabled(selectedPlanDocumentCycleID == nil && item == nil)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.close".localized) {
                        selectedPlanDocumentCycleID = nil
                        isPlanDocumentSheetPresented = false
                    }
                }
            }
        }
    }

    private func openPlanDocumentSheet(cycleID: String) {
        selectedPlanDocumentCycleID = cycleID
        appState.requestEvolutionPlanDocument(project: project, workspace: workspace, cycleID: cycleID)
        isPlanDocumentSheetPresented = true
    }

    private func refreshSelectedPlanDocument() {
        if let cycleID = selectedPlanDocumentCycleID {
            appState.requestEvolutionPlanDocument(project: project, workspace: workspace, cycleID: cycleID)
            return
        }
        if let item {
            appState.requestEvolutionPlanDocument(project: project, workspace: workspace, cycleID: item.cycleID)
        }
    }

    private func loadProfiles() {
        let values = appState.evolutionProfiles(project: project, workspace: workspace)
        let loadedProfiles = values.map { profile in
            EvolutionProfileDraft(
                id: profile.stage,
                stage: profile.stage,
                aiTool: profile.aiTool,
                mode: profile.mode ?? "",
                providerID: profile.model?.providerID ?? "",
                modelID: profile.model?.modelID ?? "",
                configOptions: profile.configOptions
            )
        }
        let incomingSignature = profileSignature(loadedProfiles)
        if shouldIgnoreIncomingProfiles(signature: incomingSignature) {
            return
        }

        isApplyingRemoteProfiles = true
        profiles = loadedProfiles
        lastSyncedProfileSignature = profileSignature(profiles)
        if pendingProfileSaveSignature == lastSyncedProfileSignature {
            pendingProfileSaveSignature = nil
            pendingProfileSaveDate = nil
        }
        hasPendingUserProfileEdit = false
        DispatchQueue.main.async {
            isApplyingRemoteProfiles = false
        }
    }

    private func modeOptions(for tool: AIChatTool) -> [String] {
        // 与 macOS 端保持一致：mode 选项来自 agent.name。
        var seen: Set<String> = []
        var values: [String] = []
        for agent in appState.evolutionAgents(project: project, workspace: workspace, aiTool: tool) {
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard seen.insert(name).inserted else { continue }
            values.append(name)
        }
        return values
    }

    private func runtimeAgent(for stage: String) -> EvolutionAgentInfoV2? {
        item?.agents.first { normalizedStageKey($0.stage) == normalizedStageKey(stage) }
    }

    private func stageStatusColor(_ status: String) -> Color {
        let normalized = normalizedStageStatus(status)
        switch normalized {
        case "running":
            return .orange
        case _ where isCompletedStatus(normalized):
            return .green
        default:
            return .secondary
        }
    }

    private func mobileWorkspaceStatusColor(_ status: String) -> Color {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "running", "进行中":
            return .orange
        case "idle", "空闲":
            return .green
        case "queued", "排队中":
            return .blue
        case "stopped", "已停止", "error", "failed":
            return .red
        case "interrupted":
            return .orange
        case "failed_exhausted", "failed_system":
            return .red
        case "completed", "done", "success":
            return .green
        default:
            return .secondary
        }
    }

    private func canOpenStageChat(stage: String, status: String) -> Bool {
        if normalizedStageKey(stage) == "auto_commit" {
            return false
        }
        let normalized = normalizedStageStatus(status)
        return normalized == "running" ||
            normalized == "completed" ||
            normalized == "done" ||
            normalized == "success" ||
            normalized == "succeeded" ||
            normalized == "已完成" ||
            normalized == "完成"
    }

    private func normalizedStageStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedStageKey(_ stage: String) -> String {
        let normalized = stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "implement" {
            return "implement_general"
        }
        return normalized
    }

    private func isCompletedStatus(_ status: String) -> Bool {
        status == "completed" ||
            status == "done" ||
            status == "success" ||
            status == "succeeded" ||
            status == "已完成" ||
            status == "完成"
    }

    private func isExecutionCompletedStatus(_ status: String) -> Bool {
        let normalized = normalizedStageStatus(status)
        if normalized.isEmpty {
            return false
        }
        if normalized == "running" ||
            normalized == "pending" ||
            normalized == "queued" ||
            normalized == "in_progress" ||
            normalized == "processing" {
            return false
        }
        return true
    }

    private func stageOrder(for stage: String) -> Int {
        let normalized = normalizedStageKey(stage)
        if let index = evolutionStageOrder.firstIndex(of: normalized) {
            return index
        }
        return evolutionStageOrder.count
    }

    private func runtimeOnlyAgents() -> [EvolutionAgentInfoV2] {
        guard let item else { return [] }
        let configuredStages = Set(profiles.map { normalizedStageKey($0.stage) })
        return item.agents
            .filter { !configuredStages.contains(normalizedStageKey($0.stage)) }
            .sorted { lhs, rhs in
                let leftOrder = stageOrder(for: lhs.stage)
                let rightOrder = stageOrder(for: rhs.stage)
                if leftOrder != rightOrder {
                    return leftOrder < rightOrder
                }
                return lhs.stage < rhs.stage
            }
    }

    private func sectionTitle(for profile: EvolutionProfileDraft, runtime: EvolutionAgentInfoV2?) -> String {
        let runtimeAgent = runtime?.agent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !runtimeAgent.isEmpty { return runtimeAgent }
        let configuredMode = profile.mode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredMode.isEmpty { return configuredMode }
        return stageDisplayName(profile.stage)
    }

    private func applyAgentDefaultModelIfAvailable(profileID: String, agentName: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var profile = profiles[index]
        let target = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        let agent = appState.evolutionAgents(project: project, workspace: workspace, aiTool: profile.aiTool)
            .first { info in
                info.name == target || info.name.caseInsensitiveCompare(target) == .orderedSame
            }
        guard let agent,
              let providerID = agent.defaultProviderID,
              let modelID = agent.defaultModelID,
              !providerID.isEmpty,
              !modelID.isEmpty else { return }

        profile.providerID = providerID
        profile.modelID = modelID
        profiles[index] = profile
    }

    private func modelProviders(for tool: AIChatTool) -> [AIProviderInfo] {
        appState.evolutionProviders(project: project, workspace: workspace, aiTool: tool)
            .filter { !$0.models.isEmpty }
    }

    private func selectedModelDisplayName(for profile: EvolutionProfileDraft) -> String {
        guard !profile.providerID.isEmpty, !profile.modelID.isEmpty else {
            return "settings.evolution.defaultModel".localized
        }
        for provider in modelProviders(for: profile.aiTool) {
            if provider.id == profile.providerID,
               let model = provider.models.first(where: { $0.id == profile.modelID }) {
                return model.name
            }
        }
        return profile.modelID
    }

    private func thoughtLevelOptionID(for tool: AIChatTool) -> String? {
        appState.thoughtLevelOptionID(for: tool)
    }

    private func thoughtLevelOptions(for tool: AIChatTool) -> [String] {
        appState.thoughtLevelOptions(for: tool)
    }

    private func selectedThoughtLevel(for profile: EvolutionProfileDraft) -> String? {
        guard let optionID = thoughtLevelOptionID(for: profile.aiTool) else { return nil }
        let raw = profile.configOptions[optionID]
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = raw as? NSNumber {
            let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func sanitizeProfileSelection(profileID: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var profile = profiles[index]

        if !profile.mode.isEmpty {
            let modes = modeOptions(for: profile.aiTool)
            if !modes.isEmpty, !modes.contains(profile.mode) {
                profile.mode = ""
            }
        }

        if !profile.providerID.isEmpty || !profile.modelID.isEmpty {
            let providers = modelProviders(for: profile.aiTool)
            let modelExists = providers.contains { provider in
                provider.id == profile.providerID &&
                    provider.models.contains(where: { $0.id == profile.modelID })
            }
            if !providers.isEmpty, !modelExists {
                profile.providerID = ""
                profile.modelID = ""
            }
        }

        profiles[index] = profile
    }

    private func buildStageProfilesForSubmit() -> [EvolutionStageProfileInfoV2] {
        profiles.map { profile in
            var mode: String?
            if !profile.mode.isEmpty {
                let modes = modeOptions(for: profile.aiTool)
                if modes.isEmpty || modes.contains(profile.mode) {
                    mode = profile.mode
                }
            }

            let model: EvolutionModelSelectionV2? = {
                guard !profile.providerID.isEmpty, !profile.modelID.isEmpty else { return nil }
                return EvolutionModelSelectionV2(providerID: profile.providerID, modelID: profile.modelID)
            }()

            let configOptions = profile.configOptions

            return EvolutionStageProfileInfoV2(
                stage: profile.stage,
                aiTool: profile.aiTool,
                mode: mode,
                model: model,
                configOptions: configOptions
            )
        }
    }

    private func saveProfiles() {
        let values = buildStageProfilesForSubmit()
        appState.updateEvolutionAgentProfile(project: project, workspace: workspace, profiles: values)
    }

    private func autoSaveProfilesIfNeeded() {
        guard !isApplyingRemoteProfiles else { return }
        guard hasPendingUserProfileEdit else { return }
        let signature = profileSignature(profiles)
        guard signature != lastSyncedProfileSignature else {
            hasPendingUserProfileEdit = false
            return
        }
        guard signature != pendingProfileSaveSignature else { return }
        pendingProfileSaveSignature = signature
        pendingProfileSaveDate = Date()
        hasPendingUserProfileEdit = false
        saveProfiles()
    }

    private func shouldIgnoreIncomingProfiles(signature: String) -> Bool {
        guard let pending = pendingProfileSaveSignature else { return false }
        guard pending != signature else { return false }

        let timeout: TimeInterval = 3
        if let date = pendingProfileSaveDate, Date().timeIntervalSince(date) < timeout {
            return true
        }

        pendingProfileSaveSignature = nil
        pendingProfileSaveDate = nil
        return false
    }

    private func profileSignature(_ values: [EvolutionProfileDraft]) -> String {
        values
            .sorted { $0.stage < $1.stage }
            .map {
                [
                    $0.stage,
                    $0.aiTool.rawValue,
                    $0.mode,
                    $0.providerID,
                    $0.modelID,
                    configOptionsSignature($0.configOptions)
                ].joined(separator: "::")
            }
            .joined(separator: "||")
    }

    private func configOptionsSignature(_ configOptions: [String: Any]) -> String {
        guard !configOptions.isEmpty else { return "" }
        guard JSONSerialization.isValidJSONObject(configOptions),
              let data = try? JSONSerialization.data(withJSONObject: configOptions, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(NSDictionary(dictionary: configOptions))"
        }
        return text
    }

    private func startEvolution() {
        let loopRoundLimit = max(1, Int(loopRoundLimitText) ?? 1)
        let values = buildStageProfilesForSubmit()
        appState.startEvolution(
            project: project,
            workspace: workspace,
            loopRoundLimit: loopRoundLimit,
            profiles: values
        )
    }

    private func triggerPrimaryControlAction() {
        if controlState.canStop {
            appState.stopEvolution(project: project, workspace: workspace)
            return
        }
        if controlState.canStart {
            startEvolution()
        }
    }

    private func syncStartOptionsFromItem() {
        guard let item else { return }
        loopRoundLimitText = "\(max(1, item.loopRoundLimit))"
    }

    private func trimmedNonEmptyText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func mobileCycleDisplayTitle(_ value: String?) -> String {
        trimmedNonEmptyText(value) ?? "Untitled"
    }

    private var activeBlockingRequest: EvolutionBlockingRequiredV2? {
        guard let blocking = appState.evolutionBlockingRequired else { return nil }
        guard blocking.project == project else { return nil }
        let lhs = normalizeWorkspace(blocking.workspace)
        let rhs = normalizeWorkspace(workspace)
        return lhs == rhs ? blocking : nil
    }

    private func syncBlockingDrafts(_ value: EvolutionBlockingRequiredV2?) {
        guard let value = activeBlockingRequest else { return }
        for item in value.unresolvedItems {
            if blockerDrafts[item.blockerID] != nil { continue }
            blockerDrafts[item.blockerID] = EvolutionBlockerDraft(
                selected: true,
                selectedOptionID: item.options.first?.optionID ?? "",
                answerText: ""
            )
        }
    }

    private func bindingSelected(_ blockerID: String) -> Binding<Bool> {
        Binding(
            get: { blockerDrafts[blockerID]?.selected ?? true },
            set: { value in
                var draft = blockerDrafts[blockerID] ?? EvolutionBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
                draft.selected = value
                blockerDrafts[blockerID] = draft
            }
        )
    }

    private func bindingOption(_ blockerID: String) -> Binding<String> {
        Binding(
            get: { blockerDrafts[blockerID]?.selectedOptionID ?? "" },
            set: { value in
                var draft = blockerDrafts[blockerID] ?? EvolutionBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
                draft.selectedOptionID = value
                blockerDrafts[blockerID] = draft
            }
        )
    }

    private func bindingAnswer(_ blockerID: String) -> Binding<String> {
        Binding(
            get: { blockerDrafts[blockerID]?.answerText ?? "" },
            set: { value in
                var draft = blockerDrafts[blockerID] ?? EvolutionBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
                draft.answerText = value
                blockerDrafts[blockerID] = draft
            }
        )
    }

    private func submitBlockers(_ blocking: EvolutionBlockingRequiredV2) {
        let resolutions = blocking.unresolvedItems.compactMap { item -> EvolutionBlockerResolutionInputV2? in
            let draft = blockerDrafts[item.blockerID] ?? EvolutionBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
            guard draft.selected else { return nil }
            let selectedOptionIDs = draft.selectedOptionID.isEmpty ? [] : [draft.selectedOptionID]
            let answer = draft.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
            return EvolutionBlockerResolutionInputV2(
                blockerID: item.blockerID,
                selectedOptionIDs: selectedOptionIDs,
                answerText: answer.isEmpty ? nil : answer
            )
        }
        appState.resolveEvolutionBlockers(
            project: blocking.project,
            workspace: blocking.workspace,
            resolutions: resolutions
        )
    }

    private func normalizeWorkspace(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    private func isSchedulerActive(_ status: String) -> Bool {
        let normalized = normalizedStageStatus(status)
        return normalized == "active" || normalized == "激活"
    }

    private func localizedSchedulerActivationDisplay(_ status: String) -> String {
        let normalized = normalizedStageStatus(status)
        switch normalized {
        case "active", "激活":
            return "evolution.status.active".localized
        default:
            return status
        }
    }

    private func localizedWorkspaceStatusDisplay(_ status: String) -> String {
        let normalized = normalizedStageStatus(status)
        switch normalized {
        case "running", "进行中":
            return "evolution.status.running".localized
        case "queued", "排队中":
            return "evolution.status.queued".localized
        case "idle", "空闲":
            return "evolution.status.idle".localized
        case "stopped", "已停止":
            return "evolution.status.stopped".localized
        case "error", "failed", "失败":
            return "evolution.status.failed".localized
        case "completed", "done", "success", "succeeded", "已完成", "完成":
            return "evolution.status.completed".localized
        case "interrupted":
            return "evolution.status.interrupted".localized
        case "failed_exhausted":
            return "evolution.status.failedExhausted".localized
        case "failed_system":
            return "evolution.status.failedSystem".localized
        default:
            return status
        }
    }

    private func localizedStageStatusDisplay(_ status: String) -> String {
        let normalized = normalizedStageStatus(status)
        switch normalized {
        case "running":
            return "evolution.status.running".localized
        case "completed", "done", "success", "succeeded", "已完成", "完成":
            return "evolution.status.completed".localized
        case "error", "failed", "失败":
            return "evolution.status.failed".localized
        case "queued":
            return "evolution.status.queued".localized
        case "idle":
            return "evolution.status.idle".localized
        case "stopped":
            return "evolution.status.stopped".localized
        case "not_started", "not started", "未启动", "未运行":
            return "evolution.status.notStarted".localized
        case "skipped", "skip", "已跳过":
            return "evolution.status.skipped".localized
        default:
            return status
        }
    }

    /// 将终止原因码转为本地化描述
    private func mobileLocalizedTerminalReason(_ code: String) -> String {
        let key = "evolution.terminalReason.\(code)"
        let localized = key.localized
        return localized == key ? code : localized
    }

    private func stageDisplayName(_ stage: String) -> String {
        let trimmed = stage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "evolution.stage.unnamed".localized }
        switch trimmed.lowercased() {
        case "direction":
            return "evolution.stage.direction".localized
        case "plan":
            return "evolution.stage.plan".localized
        case "implement_general":
            return "evolution.stage.implementGeneral".localized
        case "implement_visual":
            return "evolution.stage.implementVisual".localized
        case "implement_advanced":
            return "evolution.stage.implementAdvanced".localized
        case "implement":
            return "evolution.stage.implementGeneral".localized
        case "verify":
            return "evolution.stage.verify".localized
        case "judge":
            return "evolution.stage.judge".localized
        case "auto_commit":
            return "evolution.stage.autoCommit".localized
        default:
            return trimmed
        }
    }

    // MARK: - 历史循环紧凑条形

    private struct MobileCycleBarEntry: Identifiable {
        let id: String
        let stage: String
        let agent: String
        let aiTool: String
        let startedAt: String?
        let status: String
        let durationMs: UInt64?
    }

    private struct MobileCycleBarSegment: Identifiable {
        let entry: MobileCycleBarEntry
        let ratio: CGFloat
        var id: String { entry.id }
    }

    private struct MobileCycleDetailTimelineEntry: Identifiable {
        let id: String
        let stage: String
        let agent: String
        let aiTool: String
        let startedAt: String?
        let status: String
        let durationMs: UInt64?
    }

    private struct MobileCycleDetailPayload: Identifiable {
        let id: String
        let cycleID: String
        let title: String
        let round: Int
        let status: String
        let startTimeText: String
        let totalDurationText: String?
        let terminalReasonCode: String?
        let terminalErrorMessage: String?
        let timelineEntries: [MobileCycleDetailTimelineEntry]
    }

    private func mobileCycleBarEntries(_ cycle: EvolutionCycleHistoryItemV2) -> [MobileCycleBarEntry] {
        let executionEntries = cycle.executions
            .filter { isExecutionCompletedStatus($0.status) }
            .sorted { lhs, rhs in
                switch (lhs.startedAt.isEmpty, rhs.startedAt.isEmpty) {
                case (false, false):
                    if lhs.startedAt != rhs.startedAt {
                        return lhs.startedAt < rhs.startedAt
                    }
                case (false, true):
                    return true
                case (true, false):
                    return false
                case (true, true):
                    break
                }
                return lhs.sessionID < rhs.sessionID
            }
            .map { execution in
                MobileCycleBarEntry(
                    id: execution.sessionID + "|" + execution.startedAt,
                    stage: execution.stage,
                    agent: execution.agent,
                    aiTool: execution.aiTool,
                    startedAt: trimmedNonEmptyText(execution.startedAt),
                    status: execution.status,
                    durationMs: execution.durationMs
                )
            }
        if !executionEntries.isEmpty {
            return executionEntries
        }
        return cycle.stages.map { stage in
            MobileCycleBarEntry(
                id: "\(cycle.cycleID)_\(stage.stage)",
                stage: stage.stage,
                agent: stage.agent,
                aiTool: stage.aiTool,
                startedAt: nil,
                status: stage.status,
                durationMs: stage.durationMs
            )
        }
    }

    private func mobileStageColor(_ stage: String) -> Color {
        switch normalizedStageKey(stage) {
        case "direction": return .cyan
        case "plan": return .blue
        case "implement_general": return .orange
        case "implement_visual": return .pink
        case "implement_advanced": return .purple
        case "verify": return .green
        case "judge": return .yellow
        case "auto_commit": return .gray
        default: return .secondary
        }
    }

    @ViewBuilder
    private var mobileCycleHistorySection: some View {
        let key = appState.globalWorkspaceKey(project: project, workspace: appState.normalizeEvolutionWorkspaceName(workspace))
        if let cycles = appState.evolutionCycleHistories[key], !cycles.isEmpty {
            Section("evolution.page.pipeline.historyCycles".localized) {
                ForEach(cycles, id: \.cycleID) { cycle in
                    let entries = mobileCycleBarEntries(cycle)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mobileCycleDisplayTitle(cycle.title))
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Text(String(format: "evolution.page.pipeline.roundLabel".localized, cycle.globalLoopRound))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Label(mobileCycleTimeLabel(cycle.createdAt), systemImage: "clock")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                openPlanDocumentSheet(cycleID: cycle.cycleID)
                            } label: {
                                Image(systemName: "doc.text")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                        }

                        // 紧凑彩色条
                        mobileProportionalStageBar(entries: entries, height: 6)

                        // 终止原因
                        if let reason = trimmedNonEmptyText(cycle.terminalReasonCode) {
                            Text(mobileLocalizedTerminalReason(reason))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let terminalError = trimmedNonEmptyText(cycle.terminalErrorMessage) {
                            Text(terminalError)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedCycleDetail = mobileCycleDetailPayload(cycle)
                    }
                }
            }
        }
    }

    private func mobileCycleDetailPayload(_ cycle: EvolutionCycleHistoryItemV2) -> MobileCycleDetailPayload {
        let timelineEntries: [MobileCycleDetailTimelineEntry] = {
            let executionEntries = cycle.executions
                .sorted { lhs, rhs in
                    switch (lhs.startedAt.isEmpty, rhs.startedAt.isEmpty) {
                    case (false, false):
                        if lhs.startedAt != rhs.startedAt {
                            return lhs.startedAt < rhs.startedAt
                        }
                    case (false, true):
                        return true
                    case (true, false):
                        return false
                    case (true, true):
                        break
                    }
                    return lhs.sessionID < rhs.sessionID
                }
                .map { execution in
                    MobileCycleDetailTimelineEntry(
                        id: execution.sessionID + "|" + execution.startedAt,
                        stage: execution.stage,
                        agent: execution.agent,
                        aiTool: execution.aiTool,
                        startedAt: trimmedNonEmptyText(execution.startedAt),
                        status: execution.status,
                        durationMs: execution.durationMs
                    )
                }
            if !executionEntries.isEmpty {
                return executionEntries
            }
            return cycle.stages.enumerated().map { index, stage in
                MobileCycleDetailTimelineEntry(
                    id: "\(cycle.cycleID)_\(index)_\(stage.stage)",
                    stage: stage.stage,
                    agent: stage.agent,
                    aiTool: stage.aiTool,
                    startedAt: nil,
                    status: stage.status,
                    durationMs: stage.durationMs
                )
            }
        }()

        let totalDurationMs = timelineEntries.compactMap(\.durationMs).reduce(0, +)
        let startTimeText: String = {
            let earliest = timelineEntries
                .compactMap { mobileParseISODate($0.startedAt) }
                .min()
            if let earliest {
                return mobileCycleDateTimeLabel(earliest)
            }
            if let createdAt = mobileParseISODate(cycle.createdAt) {
                return mobileCycleDateTimeLabel(createdAt)
            }
            return cycle.createdAt
        }()

        return MobileCycleDetailPayload(
            id: cycle.cycleID,
            cycleID: cycle.cycleID,
            title: mobileCycleDisplayTitle(cycle.title),
            round: max(1, cycle.globalLoopRound),
            status: cycle.status,
            startTimeText: startTimeText,
            totalDurationText: totalDurationMs > 0 ? mobileStageDuration(TimeInterval(totalDurationMs) / 1000.0) : nil,
            terminalReasonCode: cycle.terminalReasonCode,
            terminalErrorMessage: cycle.terminalErrorMessage,
            timelineEntries: timelineEntries
        )
    }

    private func mobileCycleDetailSheet(_ detail: MobileCycleDetailPayload) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text(String(format: "evolution.page.pipeline.roundLabel".localized, detail.round))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        Text(detail.title)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        Text(localizedWorkspaceStatusDisplay(detail.status))
                            .font(.caption)
                            .foregroundColor(mobileWorkspaceStatusColor(detail.status))
                    }

                    HStack(spacing: 10) {
                        Label("\("evolution.page.pipeline.startTimeLabel".localized): \(detail.startTimeText)", systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let totalDurationText = detail.totalDurationText {
                            Label("\("evolution.page.pipeline.durationLabel".localized): \(totalDurationText)", systemImage: "timer")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let reason = trimmedNonEmptyText(detail.terminalReasonCode) {
                        Text(mobileLocalizedTerminalReason(reason))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let terminalError = trimmedNonEmptyText(detail.terminalErrorMessage) {
                        Text(terminalError)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(4)
                    }

                    Divider()

                    Text("evolution.page.pipeline.timelineTitle".localized)
                        .font(.headline)

                    if detail.timelineEntries.isEmpty {
                        Text("evolution.page.pipeline.noTimeline".localized)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(detail.timelineEntries) { entry in
                                mobileCycleDetailTimelineRow(entry)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(String(format: "evolution.page.pipeline.roundLabel".localized, detail.round))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.close".localized) {
                        selectedCycleDetail = nil
                    }
                }
            }
        }
    }

    private func mobileCycleDetailTimelineRow(_ entry: MobileCycleDetailTimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(mobileStageColor(entry.stage))
                    .frame(width: 8, height: 8)
                Text(stageDisplayName(entry.stage))
                    .font(.subheadline.weight(.semibold))
                if let agent = trimmedNonEmptyText(entry.agent) {
                    Text(agent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                Label("\("evolution.page.pipeline.startTimeLabel".localized): \(mobileTimelineStartTimeText(entry.startedAt))", systemImage: "clock")
                Label("\("evolution.page.pipeline.durationLabel".localized): \(mobileTimelineDurationText(entry))", systemImage: "timer")
                Label("\("evolution.page.pipeline.aiTool".localized): \(trimmedNonEmptyText(entry.aiTool) ?? "-")", systemImage: "sparkles")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(mobileStageColor(entry.stage).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(mobileStageColor(entry.stage).opacity(0.2), lineWidth: 1)
        )
    }

    private func mobileTimelineStartTimeText(_ startedAt: String?) -> String {
        guard let date = mobileParseISODate(startedAt) else { return "-" }
        return mobileCycleDateTimeLabel(date)
    }

    private func mobileTimelineDurationText(_ entry: MobileCycleDetailTimelineEntry) -> String {
        if let durationMs = entry.durationMs, durationMs > 0 {
            return mobileStageDuration(TimeInterval(durationMs) / 1000.0)
        }
        let normalized = normalizedStageStatus(entry.status)
        if normalized == "running" || normalized == "进行中",
           let startDate = mobileParseISODate(entry.startedAt) {
            return mobileStageDuration(max(0, Date().timeIntervalSince(startDate)))
        }
        return "evolution.page.pipeline.durationUnknown".localized
    }

    private func mobileParseISODate(_ isoString: String?) -> Date? {
        guard let isoString = trimmedNonEmptyText(isoString) else { return nil }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        return isoFormatter.date(from: isoString) ?? fallbackFormatter.date(from: isoString)
    }

    private func mobileCycleDateTimeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func mobileCycleTimeLabel(_ isoString: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        guard let date = isoFormatter.date(from: isoString) ?? fallbackFormatter.date(from: isoString) else {
            return isoString
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func mobileStageDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else {
            let minutes = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(minutes)m\(String(format: "%02d", secs))s"
        }
    }

    private func mobileTooltipDuration(_ durationMs: UInt64?) -> String {
        guard let durationMs, durationMs > 0 else {
            return "evolution.page.pipeline.durationUnknown".localized
        }
        return mobileStageDuration(TimeInterval(durationMs) / 1000.0)
    }

    private func mobileProportionalStageBar(entries: [MobileCycleBarEntry], height: CGFloat) -> some View {
        let segments = mobileStageBarSegments(entries)
        let segmentSpacing: CGFloat = 2

        return GeometryReader { geo in
            let totalSpacing = segmentSpacing * CGFloat(max(segments.count - 1, 0))
            let drawableWidth = max(geo.size.width - totalSpacing, 0)
            HStack(spacing: segmentSpacing) {
                ForEach(segments) { segment in
                    let durationText = mobileTooltipDuration(segment.entry.durationMs)
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(mobileStageColor(segment.entry.stage))
                        .frame(width: max(0, drawableWidth * segment.ratio), height: height)
                        .overlay {
                            Color.clear
                                .contentShape(Rectangle())
                                .contextMenu {
                                    Text(stageDisplayName(segment.entry.stage))
                                    if !segment.entry.agent.isEmpty {
                                        Text("evolution.page.pipeline.agentLabel".localized + ": \(segment.entry.agent)")
                                    }
                                    if !segment.entry.aiTool.isEmpty {
                                        Text("AI: \(segment.entry.aiTool)")
                                    }
                                    Text("evolution.page.pipeline.durationLabel".localized + ": \(durationText)")
                                }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.3), value: mobileStageBarAnimationToken(segments))
        }
        .frame(height: height)
        .clipShape(Capsule())
    }

    private func mobileStageBarAnimationToken(_ segments: [MobileCycleBarSegment]) -> String {
        segments
            .map { segment in
                "\(segment.id)=\(String(format: "%.6f", Double(segment.ratio)))"
            }
            .joined(separator: "|")
    }

    private func mobileStageBarSegments(_ entries: [MobileCycleBarEntry]) -> [MobileCycleBarSegment] {
        guard !entries.isEmpty else { return [] }

        let rawDurations = entries.map { TimeInterval($0.durationMs ?? 0) / 1000.0 }
        let positiveDurations = rawDurations.filter { $0 > 0 }
        let weights: [TimeInterval]

        if !positiveDurations.isEmpty {
            let averagePositive = positiveDurations.reduce(0, +) / Double(positiveDurations.count)
            let fallbackWeight = max(averagePositive * 0.12, 0.3)
            weights = rawDurations.map { duration in
                duration > 0 ? duration : fallbackWeight
            }
        } else {
            weights = Array(repeating: 1, count: entries.count)
        }

        let totalWeight = max(weights.reduce(0, +), 0.0001)
        return zip(entries, weights).map { entry, weight in
            MobileCycleBarSegment(entry: entry, ratio: CGFloat(weight / totalWeight))
        }
    }
}
