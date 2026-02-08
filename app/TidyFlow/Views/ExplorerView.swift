import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文件浏览器视图

struct ExplorerView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            if let workspaceKey = appState.selectedWorkspaceKey {
                // 工作空间已选择，显示文件树
                FileTreeView(workspaceKey: workspaceKey)
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
    let workspaceKey: String

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
                    FileListContent(workspaceKey: workspaceKey, path: ".", depth: 0)
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
                        appState.pasteFiles(workspaceKey: workspaceKey, destDir: ".")
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
                            appState.createNewFile(workspaceKey: workspaceKey, parentDir: ".", fileName: newFileName)
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
                                    workspaceKey: workspaceKey,
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
            if appState.getFileListCache(workspaceKey: workspaceKey, path: ".") == nil {
                appState.fetchFileList(workspaceKey: workspaceKey, path: ".")
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
struct FileListContent: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var fileCache: FileCacheState
    let workspaceKey: String
    let path: String
    let depth: Int

    private var cacheKey: String {
        "\(workspaceKey):\(path)"
    }

    private var cache: FileListCache? {
        // 直接从 fileCache 读取，确保文件缓存变化时触发重绘
        appState.getFileListCache(workspaceKey: workspaceKey, path: path)
    }
    
    var body: some View {
        if let cache = cache {
            if let error = cache.error, cache.items.isEmpty {
                // 错误状态
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
                // 显示文件列表
                ForEach(cache.items) { item in
                    FileRowView(
                        workspaceKey: workspaceKey,
                        item: item,
                        depth: depth
                    )
                    .environmentObject(appState)
                }
            }
        } else {
            // 未加载
            EmptyView()
        }
    }
}

/// 单个文件/目录行（使用共用 TreeRowView）
struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    @EnvironmentObject var fileCache: FileCacheState
    let workspaceKey: String
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

    private var isExpanded: Bool {
        appState.isDirectoryExpanded(workspaceKey: workspaceKey, path: item.path)
    }

    private var iconName: String {
        if item.isDir {
            return isExpanded ? "folder.fill" : "folder"
        } else {
            return fileIconName(for: item.name)
        }
    }

    /// 特殊文件的自定义图标视图（CLAUDE.md / AGENTS.md）
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

    /// 是否为需要自定义图标的特殊文件
    private var hasSpecialIcon: Bool {
        guard !item.isDir else { return false }
        return item.name == "CLAUDE.md" || item.name == "AGENTS.md"
    }

    /// 获取当前项的 Git 状态
    private var gitStatus: String? {
        let index = gitCache.getGitStatusIndex(workspaceKey: workspaceKey)
        return index.getStatus(path: item.path, isDir: item.isDir)
    }

    /// 根据 Git 状态返回颜色
    private var gitStatusColor: Color? {
        GitStatusIndex.colorForStatus(gitStatus)
    }

    private var iconColor: Color {
        // 被忽略的文件显示为灰色
        if item.isIgnored {
            return Color.gray.opacity(0.5)
        }
        // 如果有 Git 状态颜色，使用它；否则使用默认颜色
        if let statusColor = gitStatusColor {
            return statusColor
        }
        if item.isDir {
            return .accentColor
        } else {
            return .secondary
        }
    }

    /// 标题颜色：被忽略时灰色，有 Git 状态时使用状态颜色
    private var titleColor: Color? {
        if item.isIgnored {
            return Color.gray.opacity(0.5)
        }
        return gitStatusColor
    }

    /// 当前文件是否为资源管理器中应高亮的"当前打开文件"（与活动编辑器标签一致）
    private var isSelected: Bool {
        !item.isDir
            && appState.selectedWorkspaceKey == workspaceKey
            && appState.activeEditorPath == item.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if hasSpecialIcon {
                    TreeRowView(
                        isExpandable: item.isDir,
                        isExpanded: isExpanded,
                        iconName: iconName,
                        iconColor: iconColor,
                        title: item.name,
                        depth: depth,
                        isSelected: isSelected,
                        selectedBackgroundColor: Color.accentColor.opacity(0.35),
                        trailingText: gitStatus,
                        trailingIcon: item.isSymlink ? "arrow.uturn.backward" : nil,
                        titleColor: titleColor,
                        trailingTextColor: gitStatusColor,
                        customIconView: specialFileIcon,
                        onTap: { handleTap() }
                    )
                } else {
                    TreeRowView(
                        isExpandable: item.isDir,
                        isExpanded: isExpanded,
                        iconName: iconName,
                        iconColor: iconColor,
                        title: item.name,
                        depth: depth,
                        isSelected: isSelected,
                        selectedBackgroundColor: Color.accentColor.opacity(0.35),
                        trailingText: gitStatus,
                        trailingIcon: item.isSymlink ? "arrow.uturn.backward" : nil,
                        titleColor: titleColor,
                        trailingTextColor: gitStatusColor,
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
                        workspaceKey: workspaceKey,
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
                        appState.pasteFiles(workspaceKey: workspaceKey, destDir: dest)
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
                    workspaceKey: workspaceKey,
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
                        appState.renameFile(workspaceKey: workspaceKey, path: item.path, newName: newName)
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
                        appState.createNewFile(workspaceKey: workspaceKey, parentDir: dir, fileName: newFileName)
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
                appState.deleteFile(workspaceKey: workspaceKey, path: item.path)
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
            appState.toggleDirectoryExpanded(workspaceKey: workspaceKey, path: item.path)
        } else {
            // 不支持的文件类型不打开 tab
            let ext = (item.name as NSString).pathExtension.lowercased()
            guard !Self.unsupportedExtensions.contains(ext) else { return }
            // 文件：打开编辑器（使用全局工作空间键）
            if let globalKey = appState.currentGlobalWorkspaceKey {
                appState.addEditorTab(workspaceKey: globalKey, path: item.path)
            }
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
                            workspaceKey: workspaceKey,
                            oldPath: draggedPath,
                            newDir: item.path
                        )
                    }
                }
            }
        }
        return true
    }

    /// 根据文件扩展名返回图标名称
    private func fileIconName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":
            return "swift"
        case "rs":
            return "gear"
        case "js", "ts", "jsx", "tsx":
            return "j.square"
        case "json", "json5":
            return "curlybraces"
        case "md", "markdown":
            return "doc.richtext"
        case "html", "htm":
            return "globe"
        case "css", "scss", "sass":
            return "paintbrush"
        case "py":
            return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh":
            return "terminal"
        case "yml", "yaml", "toml":
            return "doc.badge.gearshape"
        case "erl", "ets":
            return "antenna.radiowaves.left.and.right"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo"
        case "mp3", "wav", "m4a":
            return "music.note"
        case "mp4", "mov", "avi":
            return "video"
        case "zip", "tar", "gz", "rar":
            return "archivebox"
        case "pdf":
            return "doc.fill"
        case "txt":
            return "doc.text"
        case "lock":
            return "lock"
        default:
            return "doc"
        }
    }
}
