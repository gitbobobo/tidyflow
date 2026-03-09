import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文件浏览器视图

struct ExplorerView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            if let workspace = appState.selectedWorkspaceIdentity {
                // 工作空间已选择，显示文件树
                FileTreeView(workspace: workspace)
                    .environmentObject(appState)
            } else {
                // 未选择工作空间
                RightPanelNoWorkspaceView()
            }
        }
    }
}

/// 右侧面板 - 未选择工作空间提示
struct RightPanelNoWorkspaceView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.6))
            Text("rightPanel.noWorkspace".localized)
                .font(.headline)
                .foregroundColor(.secondary)
            Text("rightPanel.noWorkspace.hint".localized)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 文件树视图
struct FileTreeView: View {
    @EnvironmentObject var appState: AppState
    let workspace: WorkspaceIdentity

    // 新建文件状态
    @State private var showNewFileDialog = false
    @State private var newFileName = ""

    var body: some View {
        VStack(spacing: 0) {
            // 与源代码管理一致的面板标题
            PanelHeaderView(
                title: "rightPanel.explorer".localized,
                onRefresh: { appState.refreshFileList() },
                isRefreshDisabled: false
            )

            // 文件列表
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FileListContent(workspace: workspace, path: ".", depth: 0)
                        .environmentObject(appState)
                }
                .padding(4)
                // 撑满空白区域以响应右键
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            }
            .contextMenu {
                // 新建文件（根目录）
                Button {
                    newFileName = ""
                    showNewFileDialog = true
                } label: {
                    Label("rightPanel.newFile".localized, systemImage: "doc.badge.plus")
                }

                Divider()

                // 粘贴到根目录
                if appState.clipboardHasFiles {
                    Button {
                        appState.pasteFiles(workspaceKey: workspace.workspaceName, destDir: ".")
                    } label: {
                        Label("common.paste".localized, systemImage: "doc.on.clipboard")
                    }

                    Divider()
                }

                // 复制工作空间根目录绝对路径
                Button {
                    if let workspacePath = appState.selectedWorkspacePath {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(workspacePath, forType: .string)
                        appState.clipboardHasFiles = false
                    }
                } label: {
                    Label("rightPanel.copyPath".localized, systemImage: "link")
                }

                // 复制相对路径（根目录为 "."）
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(".", forType: .string)
                    appState.clipboardHasFiles = false
                } label: {
                    Label("rightPanel.copyRelativePath".localized, systemImage: "arrow.turn.down.right")
                }
            }
            .sheet(isPresented: $showNewFileDialog) {
                NewFileDialogView(
                    fileName: $newFileName,
                    onConfirm: {
                        if !newFileName.isEmpty {
                            appState.createNewFile(
                                workspaceKey: workspace.workspaceName,
                                parentDir: ".",
                                fileName: newFileName
                            )
                        }
                        showNewFileDialog = false
                    },
                    onCancel: {
                        showNewFileDialog = false
                    }
                )
            }
            // v1.25: 根目录放置目标（拖拽到空白区域移动到根目录）
            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                for provider in providers {
                    if provider.canLoadObject(ofClass: NSString.self) {
                        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
                            guard let draggedPath = reading as? String else { return }
                            // 不能拖到当前所在目录（已在根目录则无意义）
                            let parentDir = (draggedPath as NSString).deletingLastPathComponent
                            guard !parentDir.isEmpty && parentDir != "." else { return }
                            DispatchQueue.main.async {
                                appState.moveFile(
                                    workspaceKey: workspace.workspaceName,
                                    oldPath: draggedPath,
                                    newDir: "."
                                )
                            }
                        }
                    }
                }
                return true
            }
        }
        .onAppear {
            // 首次加载时请求根目录文件列表
            if appState.getFileListCache(
                project: workspace.projectName,
                workspaceKey: workspace.workspaceName,
                path: "."
            ) == nil {
                appState.fetchFileList(
                    project: workspace.projectName,
                    workspaceKey: workspace.workspaceName,
                    path: "."
                )
            }
            // 检查剪贴板状态以驱动粘贴菜单
            appState.checkClipboardForFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 应用获得焦点时刷新剪贴板状态（支持从 Finder 复制后粘贴）
            appState.checkClipboardForFiles()
        }
    }
}

/// 文件列表内容（递归）
/// 通过 `fileCache`（独立 ObservableObject）驱动，避免文件列表变化触发全局视图刷新。
struct FileListContent: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var fileCache: FileCacheState
    let workspace: WorkspaceIdentity
    let path: String
    let depth: Int

    private var cache: FileListCache? {
        fileCache.fileListCache[workspace.fileCacheKey(path: path)]
    }

    var body: some View {
        if let cache = cache {
            if let error = cache.error, cache.items.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .padding(.leading, CGFloat(depth * 16 + 8))
            } else {
                ForEach(cache.items) { item in
                    FileRowView(
                        workspace: workspace,
                        item: item,
                        depth: depth
                    )
                    .environmentObject(appState)
                }
            }
        } else {
            EmptyView()
        }
    }
}

/// 单个文件/目录行（使用共用 TreeRowView）
struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var fileCache: FileCacheState
    @EnvironmentObject var gitCache: GitCacheState
    let workspace: WorkspaceIdentity
    let item: FileEntry
    let depth: Int

    // v1.23: 右键菜单状态
    @State private var showRenameDialog = false
    @State private var showDeleteConfirm = false
    @State private var newName = ""
    // 新建文件状态
    @State private var showNewFileDialog = false
    @State private var newFileName = ""
    // v1.25: 拖拽放置目标高亮
    @State private var isDropTarget = false

    private var expandStateKey: String {
        workspace.fileCacheKey(path: item.path)
    }

    private var isExpanded: Bool {
        fileCache.directoryExpandState[expandStateKey] ?? false
    }

    /// 当前文件是否为资源管理器中应高亮的"当前打开文件"（与活动编辑器标签一致）
    private var isSelected: Bool {
        !item.isDir
            && appState.currentGlobalWorkspaceKey == workspace.globalKey
            && appState.activeEditorPath == item.path
    }

    /// 通过共享语义解析器推导条目展示语义，消除本地重复图标/颜色规则
    private var presentation: ExplorerItemPresentation {
        let gitIndex = gitCache.getGitStatusIndex(workspaceKey: workspace.workspaceName)
        return ExplorerSemanticResolver.resolve(
            entry: item,
            gitIndex: gitIndex,
            isExpanded: isExpanded,
            isSelected: isSelected
        )
    }

    /// 特殊文件的自定义图标视图（CLAUDE.md / AGENTS.md），仅在 presentation.hasSpecialIcon 时渲染
    @ViewBuilder
    private var specialFileIcon: some View {
        if item.name == "CLAUDE.md" {
            Image("claude-icon")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else if item.name == "AGENTS.md" {
            Image("agents-icon")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            EmptyView()
        }
    }

    var body: some View {
        let p = presentation
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if p.hasSpecialIcon {
                    TreeRowView(
                        isExpandable: item.isDir,
                        isExpanded: isExpanded,
                        iconName: p.iconName,
                        iconColor: p.iconColor,
                        title: item.name,
                        depth: depth,
                        isSelected: p.isSelected,
                        selectedBackgroundColor: Color.accentColor.opacity(0.35),
                        trailingText: p.gitStatus,
                        trailingIcon: p.trailingIcon,
                        titleColor: p.titleColor,
                        trailingTextColor: p.gitStatusColor,
                        customIconView: specialFileIcon,
                        onTap: { handleTap() }
                    )
                } else {
                    TreeRowView(
                        isExpandable: item.isDir,
                        isExpanded: isExpanded,
                        iconName: p.iconName,
                        iconColor: p.iconColor,
                        title: item.name,
                        depth: depth,
                        isSelected: p.isSelected,
                        selectedBackgroundColor: Color.accentColor.opacity(0.35),
                        trailingText: p.gitStatus,
                        trailingIcon: p.trailingIcon,
                        titleColor: p.titleColor,
                        trailingTextColor: p.gitStatusColor,
                        onTap: { handleTap() }
                    )
                }
            }
            .contextMenu {
                // 新建文件
                Button {
                    newFileName = ""
                    showNewFileDialog = true
                } label: {
                    Label("rightPanel.newFile".localized, systemImage: "doc.badge.plus")
                }

                Divider()

                Button {
                    appState.copyFileToClipboard(
                        workspaceKey: workspace.workspaceName,
                        path: item.path,
                        isDir: item.isDir,
                        name: item.name
                    )
                } label: {
                    Label("common.copy".localized, systemImage: "doc.on.doc")
                }

                // 粘贴选项：目录粘贴到自身，文件粘贴到其父目录
                if appState.clipboardHasFiles {
                    Button {
                        let destDir = item.isDir ? item.path : (item.path as NSString).deletingLastPathComponent
                        let dest = destDir.isEmpty ? "." : destDir
                        appState.pasteFiles(workspaceKey: workspace.workspaceName, destDir: dest)
                    } label: {
                        Label("common.paste".localized, systemImage: "doc.on.clipboard")
                    }
                }

                Divider()

                Button {
                    if let workspacePath = appState.selectedWorkspacePath {
                        let absolutePath = (workspacePath as NSString).appendingPathComponent(item.path)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(absolutePath, forType: .string)
                        appState.clipboardHasFiles = false
                    }
                } label: {
                    Label("rightPanel.copyPath".localized, systemImage: "link")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                    appState.clipboardHasFiles = false
                } label: {
                    Label("rightPanel.copyRelativePath".localized, systemImage: "arrow.turn.down.right")
                }

                Divider()

                Button {
                    newName = item.name
                    showRenameDialog = true
                } label: {
                    Label("common.rename".localized, systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("common.delete".localized, systemImage: "trash")
                }
            }

            if item.isDir && isExpanded {
                FileListContent(
                    workspace: workspace,
                    path: item.path,
                    depth: depth + 1
                )
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showRenameDialog) {
            RenameDialogView(
                originalName: item.name,
                newName: $newName,
                isDir: item.isDir,
                onConfirm: {
                    if !newName.isEmpty && newName != item.name {
                        appState.renameFile(
                            workspaceKey: workspace.workspaceName,
                            path: item.path,
                            newName: newName
                        )
                    }
                    showRenameDialog = false
                },
                onCancel: {
                    showRenameDialog = false
                }
            )
        }
        .sheet(isPresented: $showNewFileDialog) {
            NewFileDialogView(
                fileName: $newFileName,
                onConfirm: {
                    if !newFileName.isEmpty {
                        let parentDir = item.isDir ? item.path : (item.path as NSString).deletingLastPathComponent
                        let dir = parentDir.isEmpty ? "." : parentDir
                        appState.createNewFile(
                            workspaceKey: workspace.workspaceName,
                            parentDir: dir,
                            fileName: newFileName
                        )
                    }
                    showNewFileDialog = false
                },
                onCancel: {
                    showNewFileDialog = false
                }
            )
        }
        .alert("rightPanel.confirmDelete".localized, isPresented: $showDeleteConfirm) {
            Button("common.cancel".localized, role: .cancel) { }
            Button("common.delete".localized, role: .destructive) {
                appState.deleteFile(workspaceKey: workspace.workspaceName, path: item.path)
            }
        } message: {
            Text(String(format: "rightPanel.confirmDelete.message".localized, item.name))
        }
        // v1.25: 拖拽源
        .onDrag {
            NSItemProvider(object: item.path as NSString)
        }
        // v1.25: 放置目标（仅目录）
        .if(item.isDir) { view in
            view.onDrop(of: [UTType.plainText], isTargeted: $isDropTarget) { providers in
                handleDrop(providers: providers)
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isDropTarget ? Color.accentColor.opacity(0.2) : Color.clear)
            )
        }
    }

    /// 不支持在编辑器中打开的文件扩展名（二进制文件）
    private static let unsupportedExtensions: Set<String> = [
        // 图片
        "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "bmp", "tiff", "tif",
        // 音频
        "mp3", "wav", "m4a", "aac", "flac", "ogg", "wma",
        // 视频
        "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm",
        // 压缩包
        "zip", "tar", "gz", "rar", "7z", "bz2", "xz", "dmg", "iso",
        // 文档/二进制
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        // 字体
        "ttf", "otf", "woff", "woff2",
        // 编译产物
        "o", "a", "dylib", "so", "dll", "exe", "class", "jar",
        // 其他二进制
        "sqlite", "db", "DS_Store",
    ]

    private func handleTap() {
        if item.isDir {
            // 目录：切换展开状态
            appState.toggleDirectoryExpanded(
                project: workspace.projectName,
                workspaceKey: workspace.workspaceName,
                path: item.path
            )
        } else {
            // 不支持的文件类型不打开 tab
            let ext = (item.name as NSString).pathExtension.lowercased()
            guard !Self.unsupportedExtensions.contains(ext) else { return }
            // 文件：打开编辑器（使用资源树所属工作区的全局键）
            appState.addEditorTab(workspaceKey: workspace.globalKey, path: item.path)
        }
    }

    /// v1.25: 处理拖拽放置
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard item.isDir else { return false }
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
                    guard let draggedPath = reading as? String else { return }
                    // 不能拖到自身
                    guard draggedPath != item.path else { return }
                    // 不能拖到自身的子目录
                    guard !item.path.hasPrefix(draggedPath + "/") else { return }
                    // 不能拖到当前所在目录（无意义移动）
                    let parentDir = (draggedPath as NSString).deletingLastPathComponent
                    let targetDir = item.path
                    guard parentDir != targetDir else { return }
                    DispatchQueue.main.async {
                        appState.moveFile(
                            workspaceKey: workspace.workspaceName,
                            oldPath: draggedPath,
                            newDir: item.path
                        )
                    }
                }
            }
        }
        return true
    }

}
