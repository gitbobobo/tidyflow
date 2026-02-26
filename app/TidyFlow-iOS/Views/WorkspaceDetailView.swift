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

    private var gitSummary: MobileWorkspaceGitSummary {
        appState.gitSummaryForWorkspace(project: project, workspace: workspace)
    }

    private var projectCommands: [ProjectCommand] {
        appState.projectCommands(for: project)
    }

    var body: some View {
        List {
            Section("代码变更") {
                HStack(spacing: 16) {
                    Label("+\(gitSummary.additions)", systemImage: "plus")
                        .foregroundColor(.green)
                    Label("-\(gitSummary.deletions)", systemImage: "minus")
                        .foregroundColor(.red)
                }
                .font(.headline)
                .padding(.vertical, 4)
            }

            Section("资源管理器") {
                NavigationLink(value: MobileRoute.workspaceExplorer(project: project, workspace: workspace)) {
                    Label("浏览项目文件", systemImage: "folder")
                }
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
                            }
                            .padding(.vertical, 2)
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

struct MobileEvidenceView: View {
    @EnvironmentObject var appState: MobileAppState

    let project: String
    let workspace: String

    @State private var selectedItemID: String?
    @State private var itemLoading: Bool = false
    @State private var itemPaging: Bool = false
    @State private var itemError: String?
    @State private var itemTextChunks: [String] = []
    @State private var itemTextNextOffset: UInt64 = 0
    @State private var itemTextHasMore: Bool = false
    @State private var itemImage: UIImage?
    @State private var itemByteCount: Int = 0
    @State private var headerHint: String?

    private var snapshot: EvolutionEvidenceSnapshotV2? {
        appState.evidenceSnapshot(project: project, workspace: workspace)
    }

    private var snapshotLoading: Bool {
        appState.isEvidenceLoading(project: project, workspace: workspace)
    }

    private var snapshotError: String? {
        appState.evidenceError(project: project, workspace: workspace)
    }

    var body: some View {
        List {
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
            } else if let snapshot {
                Section("状态") {
                    LabeledContent("证据目录") {
                        Text(snapshot.evidenceRoot)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("索引文件") {
                        Text(snapshot.indexFile)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("索引状态") {
                        Text(snapshot.indexExists ? "存在" : "缺失")
                            .foregroundColor(snapshot.indexExists ? .green : .orange)
                    }
                    LabeledContent("子系统") {
                        Text(snapshot.detectedSubsystems.isEmpty ? "未识别" : snapshot.detectedSubsystems.map(\.id).joined(separator: ", "))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("平台") {
                        Text(snapshot.detectedPlatforms.isEmpty ? "未识别" : snapshot.detectedPlatforms.joined(separator: ", "))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if !snapshot.issues.isEmpty {
                    Section("告警") {
                        ForEach(snapshot.issues.indices, id: \.self) { idx in
                            let issue = snapshot.issues[idx]
                            Text("[\(issue.level)] \(issue.message)")
                                .font(.caption)
                                .foregroundColor(issue.level.lowercased() == "warning" ? .orange : .secondary)
                        }
                    }
                }

                ForEach(displayPlatforms(in: snapshot), id: \.self) { platform in
                    Section(platform.uppercased()) {
                        let rows = snapshot.items.filter { $0.platform == platform }
                        if rows.isEmpty {
                            Text("暂无条目")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(rows, id: \.itemID) { item in
                                Button {
                                    selectedItemID = item.itemID
                                    loadItem(item)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("#\(item.order) \(item.title)")
                                                .font(.body)
                                            Spacer()
                                            Image(systemName: item.exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                                .foregroundColor(item.exists ? .green : .orange)
                                        }
                                        Text(item.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(item.path)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(
                                    selectedItemID == item.itemID ? Color.accentColor.opacity(0.14) : Color.clear
                                )
                            }
                        }
                    }
                }

                Section("条目详情") {
                    detailView(snapshot: snapshot)
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
        .onAppear {
            refreshEvidence()
            syncSelectionIfNeeded()
        }
        .onReceive(appState.$evolutionEvidenceSnapshotsByWorkspace) { _ in
            syncSelectionIfNeeded()
        }
        .onChange(of: appState.isConnected) { _, connected in
            guard connected else { return }
            refreshEvidence()
        }
    }

    @ViewBuilder
    private func detailView(snapshot: EvolutionEvidenceSnapshotV2) -> some View {
        let selected = snapshot.items.first { $0.itemID == selectedItemID } ?? snapshot.items.first
        if let selected {
            VStack(alignment: .leading, spacing: 8) {
                Text(selected.title)
                    .font(.headline)
                Text(selected.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if itemLoading {
                    ProgressView("加载内容中...")
                        .padding(.vertical, 6)
                } else if let itemError {
                    Text(itemError)
                        .foregroundColor(.red)
                } else if let itemImage {
                    Image(uiImage: itemImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !itemTextChunks.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
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
                                    loadNextTextPageIfNeeded(for: selected)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 180)
                } else {
                    Text("无法预览该条目（\(itemByteCount) bytes）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onAppear {
                if selectedItemID != selected.itemID {
                    selectedItemID = selected.itemID
                    loadItem(selected)
                } else if itemTextChunks.isEmpty && itemImage == nil && itemError == nil && !itemLoading {
                    loadItem(selected)
                }
            }
        } else {
            Text("暂无条目")
                .foregroundColor(.secondary)
        }
    }

    private func displayPlatforms(in snapshot: EvolutionEvidenceSnapshotV2) -> [String] {
        var ordered: [String] = []
        for platform in snapshot.detectedPlatforms where !ordered.contains(platform) {
            ordered.append(platform)
        }
        for item in snapshot.items where !ordered.contains(item.platform) {
            ordered.append(item.platform)
        }
        return ordered
    }

    private func syncSelectionIfNeeded() {
        guard let snapshot else { return }
        if let selectedItemID,
           snapshot.items.contains(where: { $0.itemID == selectedItemID }) {
            return
        }
        selectedItemID = snapshot.items.first?.itemID
        clearPreview()
        if let first = snapshot.items.first {
            loadItem(first)
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

    private func refreshEvidence() {
        appState.requestEvolutionEvidenceSnapshot(project: project, workspace: workspace)
    }

    private func rebuildEvidence() {
        appState.requestEvolutionEvidenceRebuildPrompt(project: project, workspace: workspace) { prompt, errorMessage in
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

    private func loadItem(_ item: EvolutionEvidenceItemInfoV2) {
        itemLoading = true
        itemPaging = false
        itemError = nil
        itemTextChunks = []
        itemTextNextOffset = 0
        itemTextHasMore = false
        itemImage = nil
        itemByteCount = 0

        if item.mimeType.hasPrefix("image/") || item.evidenceType == "screenshot" {
            appState.readEvolutionEvidenceItem(project: project, workspace: workspace, itemID: item.itemID) { payload, errorMessage in
                DispatchQueue.main.async {
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

    private func loadNextTextPageIfNeeded(for item: EvolutionEvidenceItemInfoV2) {
        guard selectedItemID == item.itemID else { return }
        guard itemTextHasMore, !itemPaging, !itemLoading else { return }
        loadNextTextPage(for: item, reset: false)
    }

    private func loadNextTextPage(for item: EvolutionEvidenceItemInfoV2, reset: Bool) {
        let offset: UInt64 = reset ? 0 : itemTextNextOffset
        if !reset, offset == 0 {
            return
        }
        itemPaging = true
        appState.readEvolutionEvidenceItemPage(
            project: project,
            workspace: workspace,
            itemID: item.itemID,
            offset: offset,
            limit: 131_072
        ) { payload, errorMessage in
            DispatchQueue.main.async {
                itemLoading = false
                itemPaging = false
                guard selectedItemID == item.itemID else { return }
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

    private struct EvolutionBlockerDraft {
        var selected: Bool
        var selectedOptionID: String
        var answerText: String
    }

    private var item: EvolutionWorkspaceItemV2? {
        appState.evolutionItem(project: project, workspace: workspace)
    }

    var body: some View {
        List {
            Section("调度器状态") {
                LabeledContent("激活状态") {
                    Text(appState.evolutionScheduler.activationState)
                }
                LabeledContent("并发上限") {
                    Text("\(appState.evolutionScheduler.maxParallelWorkspaces)")
                }
                LabeledContent("运行中 / 排队") {
                    Text("\(appState.evolutionScheduler.runningCount) / \(appState.evolutionScheduler.queuedCount)")
                }
            }

            Section("工作空间控制") {
                LabeledContent("当前工作空间") {
                    Text("\(project)/\(workspace)")
                }
                if let item {
                    LabeledContent("状态") {
                        Text(item.status)
                    }
                    LabeledContent("当前阶段") {
                        Text(item.currentStage)
                    }
                    LabeledContent("轮次") {
                        Text("\(item.globalLoopRound)/\(max(1, item.loopRoundLimit))")
                    }
                    LabeledContent("校验轮次") {
                        Text("\(item.verifyIteration)/\(item.verifyIterationLimit)")
                    }
                    LabeledContent("活跃代理") {
                        Text(item.activeAgents.isEmpty ? "无" : item.activeAgents.joined(separator: ", "))
                            .lineLimit(1)
                    }
                } else {
                    Text("状态: 未启动")
                        .foregroundColor(.secondary)
                }

                LabeledContent("循环轮次") {
                    TextField("1", text: $loopRoundLimitText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }

                Text("验证循环固定 3 次")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ControlGroup {
                    Button("手动启动") {
                        startEvolution()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("停止") {
                        appState.stopEvolution(project: project, workspace: workspace)
                    }
                    Button("恢复") {
                        appState.resumeEvolution(project: project, workspace: workspace)
                    }
                }
                .buttonStyle(.bordered)
            }

            Section("代理类型说明") {
                Text("按代理类型配置 AI 工具 / 模式 / 模型；运行中或已完成的代理可进入聊天详情。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let blocking = activeBlockingRequest {
                Section("阻塞任务") {
                    Text("存在未完成阻塞项，需人工处理后才能继续循环")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("触发: \(blocking.trigger)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(blocking.unresolvedItems, id: \.blockerID) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(item.title, isOn: bindingSelected(item.blockerID))
                            Text(item.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if !item.options.isEmpty {
                                Picker("选项", selection: bindingOption(item.blockerID)) {
                                    Text("请选择").tag("")
                                    ForEach(item.options, id: \.optionID) { option in
                                        Text(option.label).tag(option.optionID)
                                    }
                                }
                            }
                            if item.allowCustomInput || item.options.isEmpty {
                                TextField("输入答案", text: bindingAnswer(item.blockerID))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button("提交已勾选项") {
                        submitBlockers(blocking)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if profiles.isEmpty {
                Section("代理类型") {
                    Text("暂无阶段配置")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach($profiles) { $profile in
                    let stage = profile.stage
                    let runtime = runtimeAgent(for: stage)
                    let statusText = runtime?.status ?? "未启动"
                    let aiToolBinding = Binding<AIChatTool>(
                        get: { profile.aiTool },
                        set: { newValue in
                            guard profile.aiTool != newValue else { return }
                            hasPendingUserProfileEdit = true
                            profile.aiTool = newValue
                            sanitizeProfileSelection(profileID: profile.id)
                            autoSaveProfilesIfNeeded()
                        }
                    )
                    Section(sectionTitle(for: profile, runtime: runtime)) {
                        if canOpenStageChat(statusText) {
                            LabeledContent("工作状态") {
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
                                        Text(statusText)
                                            .foregroundColor(stageStatusColor(statusText))
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            LabeledContent("工作状态") {
                                Text(statusText)
                                    .foregroundColor(stageStatusColor(statusText))
                            }
                        }

                        LabeledContent("AI 工具") {
                            Picker("", selection: aiToolBinding) {
                                ForEach(AIChatTool.allCases) { tool in
                                    Text(tool.displayName).tag(tool)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        LabeledContent("模式") {
                            Menu {
                                Button("默认模式") {
                                    hasPendingUserProfileEdit = true
                                    profile.mode = ""
                                    autoSaveProfilesIfNeeded()
                                }
                                let options = modeOptions(for: profile.aiTool)
                                if options.isEmpty {
                                    Text("暂无可用模式")
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
                                Text(profile.mode.isEmpty ? "默认模式" : profile.mode)
                                    .foregroundColor(.secondary)
                            }
                        }

                        LabeledContent("模型") {
                            Menu {
                                Button("默认模型") {
                                    hasPendingUserProfileEdit = true
                                    profile.providerID = ""
                                    profile.modelID = ""
                                    autoSaveProfilesIfNeeded()
                                }
                                let providers = modelProviders(for: profile.aiTool)
                                if providers.isEmpty {
                                    Text("暂无可用模型")
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
                    }
                }
            }
        }
        .navigationTitle("自主进化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") {
                    appState.refreshEvolution(project: project, workspace: workspace)
                    loadProfiles()
                }
            }
        }
        .onAppear {
            appState.openEvolution(project: project, workspace: workspace)
            loadProfiles()
            syncStartOptionsFromItem()
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

    private func loadProfiles() {
        let values = appState.evolutionProfiles(project: project, workspace: workspace)
        let loadedProfiles = values.map { profile in
            EvolutionProfileDraft(
                id: profile.stage,
                stage: profile.stage,
                aiTool: profile.aiTool,
                mode: profile.mode ?? "",
                providerID: profile.model?.providerID ?? "",
                modelID: profile.model?.modelID ?? ""
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
        item?.agents.first { $0.stage == stage }
    }

    private func stageStatusColor(_ status: String) -> Color {
        switch normalizedStageStatus(status) {
        case "running":
            return .orange
        case "completed":
            return .green
        default:
            return .secondary
        }
    }

    private func canOpenStageChat(_ status: String) -> Bool {
        let normalized = normalizedStageStatus(status)
        return normalized == "running" || normalized == "completed"
    }

    private func normalizedStageStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func sectionTitle(for profile: EvolutionProfileDraft, runtime: EvolutionAgentInfoV2?) -> String {
        let runtimeAgent = runtime?.agent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !runtimeAgent.isEmpty { return runtimeAgent }
        let configuredMode = profile.mode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredMode.isEmpty { return configuredMode }
        return profile.stage
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
            return "默认模型"
        }
        for provider in modelProviders(for: profile.aiTool) {
            if provider.id == profile.providerID,
               let model = provider.models.first(where: { $0.id == profile.modelID }) {
                return model.name
            }
        }
        return profile.modelID
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

            return EvolutionStageProfileInfoV2(
                stage: profile.stage,
                aiTool: profile.aiTool,
                mode: mode,
                model: model
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
                    $0.modelID
                ].joined(separator: "::")
            }
            .joined(separator: "||")
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

    private func syncStartOptionsFromItem() {
        guard let item else {
            loopRoundLimitText = "1"
            return
        }
        loopRoundLimitText = "\(max(1, item.loopRoundLimit))"
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
}
