import SwiftUI
import UniformTypeIdentifiers

// MARK: - Xcode 风格胶囊分段控件（仅图标）

/// 胶囊形分段控件，选中项带滑动高亮（参考 Xcode Inspector、matchedGeometryEffect 实现）
struct CapsuleSegmentedControl: View {
    @Binding var selection: RightTool?
    @Namespace private var capsuleNamespace

    private var effectiveSelection: RightTool {
        selection ?? .explorer
    }

    var body: some View {
        GeometryReader { geo in
            let segmentW = max(0, geo.size.width) / 3
            let fullH = max(24, geo.size.height - 4)

            HStack(spacing: 0) {
                ForEach([RightTool.explorer, .search, .git], id: \.self) { tool in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = tool
                        }
                    } label: {
                        Image(systemName: iconName(for: tool))
                            .font(.system(size: 14, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .accessibilityLabel(accessibilityLabel(for: tool))
                    .matchedGeometryEffect(id: tool, in: capsuleNamespace)
                }
            }
            .background(
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: segmentW, height: fullH)
                    .matchedGeometryEffect(id: effectiveSelection, in: capsuleNamespace, properties: .position, isSource: false)
            )
            .background(
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.6))
            )
        }
        .frame(height: 32)
    }

    private func iconName(for tool: RightTool) -> String {
        switch tool {
        case .explorer: return "folder"
        case .search: return "magnifyingglass"
        case .git: return "arrow.triangle.branch"
        }
    }

    private func accessibilityLabel(for tool: RightTool) -> String {
        switch tool {
        case .explorer: return "文件"
        case .search: return "搜索"
        case .git: return "Git"
        }
    }
}

// MARK: - Inspector Content View（符合苹果 HIG 规范）

/// 右侧检查器内容视图
/// 使用 .inspector() API 时作为内容显示
struct InspectorContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 工具选择器：Xcode 风格胶囊、仅图标（自定义 CapsuleSegmentedControl）
            CapsuleSegmentedControl(selection: $appState.activeRightTool)
                .padding(.horizontal, 12)

            // 内容区域
            Group {
                switch appState.activeRightTool {
                case .explorer:
                    ExplorerView()
                        .environmentObject(appState)
                case .search:
                    SearchPlaceholderView()
                case .git:
                    NativeGitPanelView()
                        .environmentObject(appState)
                case .none:
                    NoToolSelectedView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 旧版兼容（如果其他地方还在使用）

/// 保留旧名称以兼容可能的其他引用
struct RightToolPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        InspectorContentView()
            .environmentObject(appState)
    }
}

// MARK: - 面板标题（与源代码管理标题样式一致，可复用）

/// 通用面板标题栏：左侧标题、右侧刷新按钮
struct PanelHeaderView: View {
    let title: String
    var onRefresh: (() -> Void)?
    var isRefreshDisabled: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer()

            if let onRefresh = onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("刷新")
                .disabled(isRefreshDisabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 树行组件（资源管理器文件树与左侧项目树共用）

/// 可复用的树行：展开指示器 + 图标 + 标题，无数量/状态等尾部信息
/// - Parameter selectedBackgroundColor: 选中时的背景色；为 nil 时使用系统 accentColor（如左侧项目树）；可传入更淡的颜色用于资源管理器等
struct TreeRowView<CustomIcon: View>: View {
    var isExpandable: Bool
    var isExpanded: Bool
    var iconName: String
    var iconColor: Color
    var title: String
    var depth: Int = 0
    var isSelected: Bool = false
    /// 选中时的背景色；nil 表示使用 Color.accentColor
    var selectedBackgroundColor: Color? = nil
    /// 尾部标签文本（如快捷键提示 ⌘1）
    var trailingText: String? = nil
    /// 标题文字颜色；nil 表示使用默认 .primary
    var titleColor: Color? = nil
    /// 尾部文字颜色；nil 表示使用默认 .secondary
    var trailingTextColor: Color? = nil
    /// 自定义图标视图，如果提供则替代默认的 SF Symbol 图标
    var customIconView: CustomIcon?
    var onTap: () -> Void

    @State private var isHovering: Bool = false

    private var leadingPadding: CGFloat {
        CGFloat(depth * 16 + 8)
    }

    var body: some View {
        HStack(spacing: 4) {
            if isExpandable {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
            } else {
                Spacer()
                    .frame(width: 12)
            }
            if let custom = customIconView {
                custom
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundColor(iconColor)
                    .frame(width: 16)
            }
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(titleColor ?? .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let trailing = trailingText {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundColor(trailingTextColor ?? .secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, leadingPadding)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 5).fill(backgroundColor))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onTap)
    }

    private var backgroundColor: Color {
        if isSelected { return selectedBackgroundColor ?? Color.accentColor }
        if isHovering { return Color.primary.opacity(0.05) }
        return Color.clear
    }
}

// MARK: - TreeRowView 便捷初始化（无自定义图标）

extension TreeRowView where CustomIcon == EmptyView {
    init(
        isExpandable: Bool,
        isExpanded: Bool,
        iconName: String,
        iconColor: Color,
        title: String,
        depth: Int = 0,
        isSelected: Bool = false,
        selectedBackgroundColor: Color? = nil,
        trailingText: String? = nil,
        titleColor: Color? = nil,
        trailingTextColor: Color? = nil,
        onTap: @escaping () -> Void
    ) {
        self.isExpandable = isExpandable
        self.isExpanded = isExpanded
        self.iconName = iconName
        self.iconColor = iconColor
        self.title = title
        self.depth = depth
        self.isSelected = isSelected
        self.selectedBackgroundColor = selectedBackgroundColor
        self.trailingText = trailingText
        self.titleColor = titleColor
        self.trailingTextColor = trailingTextColor
        self.customIconView = nil
        self.onTap = onTap
    }
}

// MARK: - TreeRowView 初始化（带自定义图标）

extension TreeRowView {
    init(
        isExpandable: Bool,
        isExpanded: Bool,
        iconName: String,
        iconColor: Color,
        title: String,
        depth: Int = 0,
        isSelected: Bool = false,
        selectedBackgroundColor: Color? = nil,
        trailingText: String? = nil,
        titleColor: Color? = nil,
        trailingTextColor: Color? = nil,
        customIconView: CustomIcon,
        onTap: @escaping () -> Void
    ) {
        self.isExpandable = isExpandable
        self.isExpanded = isExpanded
        self.iconName = iconName
        self.iconColor = iconColor
        self.title = title
        self.depth = depth
        self.isSelected = isSelected
        self.selectedBackgroundColor = selectedBackgroundColor
        self.trailingText = trailingText
        self.titleColor = titleColor
        self.trailingTextColor = trailingTextColor
        self.customIconView = customIconView
        self.onTap = onTap
    }
}

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
            Text("未选择工作空间")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("请在左侧边栏选择一个项目和工作空间")
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

    var body: some View {
        VStack(spacing: 0) {
            // 与源代码管理一致的面板标题
            PanelHeaderView(
                title: "资源管理器",
                onRefresh: { appState.fetchFileList(workspaceKey: workspaceKey, path: ".") },
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
                // 粘贴到根目录
                if appState.clipboardHasFiles {
                    Button {
                        appState.pasteFiles(workspaceKey: workspaceKey, destDir: ".")
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
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
                    Label("复制路径", systemImage: "link")
                }

                // 复制相对路径（根目录为 "."）
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(".", forType: .string)
                    appState.clipboardHasFiles = false
                } label: {
                    Label("复制相对路径", systemImage: "arrow.turn.down.right")
                }
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
    let workspaceKey: String
    let path: String
    let depth: Int
    
    private var cacheKey: String {
        "\(workspaceKey):\(path)"
    }
    
    private var cache: FileListCache? {
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
    let workspaceKey: String
    let item: FileEntry
    let depth: Int

    // v1.23: 右键菜单状态
    @State private var showRenameDialog = false
    @State private var showDeleteConfirm = false
    @State private var newName = ""
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
        let index = appState.getGitStatusIndex(workspaceKey: workspaceKey)
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
                        titleColor: titleColor,
                        trailingTextColor: gitStatusColor,
                        onTap: { handleTap() }
                    )
                }
            }
            .contextMenu {
                Button {
                    appState.copyFileToClipboard(
                        workspaceKey: workspaceKey,
                        path: item.path,
                        isDir: item.isDir,
                        name: item.name
                    )
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }

                // 粘贴选项：目录粘贴到自身，文件粘贴到其父目录
                if appState.clipboardHasFiles {
                    Button {
                        let destDir = item.isDir ? item.path : (item.path as NSString).deletingLastPathComponent
                        let dest = destDir.isEmpty ? "." : destDir
                        appState.pasteFiles(workspaceKey: workspaceKey, destDir: dest)
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
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
                    Label("复制路径", systemImage: "link")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                    appState.clipboardHasFiles = false
                } label: {
                    Label("复制相对路径", systemImage: "arrow.turn.down.right")
                }

                Divider()

                Button {
                    newName = item.name
                    showRenameDialog = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除", systemImage: "trash")
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
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                appState.deleteFile(workspaceKey: workspaceKey, path: item.path)
            }
        } message: {
            Text("确定要将「\(item.name)」移到废纸篓吗？")
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

// MARK: - 占位视图（符合苹果 Inspector 设计风格）

struct ExplorerPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.6))
            Text("文件浏览器")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("即将推出")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SearchPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.6))
            Text("全局搜索")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("即将推出")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoToolSelectedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.dashed")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.6))
            Text("未选择工具")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("请从上方选择一个工具")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - v1.23: 重命名对话框

/// 重命名对话框视图
struct RenameDialogView: View {
    let originalName: String
    @Binding var newName: String
    let isDir: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    private var isValid: Bool {
        !newName.isEmpty && newName != originalName && !newName.contains("/") && !newName.contains("\\")
    }

    var body: some View {
        VStack(spacing: 16) {
            // 标题
            HStack {
                Image(systemName: isDir ? "folder" : "doc")
                    .foregroundColor(.accentColor)
                Text("重命名\(isDir ? "文件夹" : "文件")")
                    .font(.headline)
            }

            // 输入框
            TextField("新名称", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .onSubmit {
                    if isValid {
                        onConfirm()
                    }
                }

            // 按钮
            HStack(spacing: 12) {
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("确定") {
                    onConfirm()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            // 自动聚焦并选中文件名（不含扩展名）
            isTextFieldFocused = true
        }
    }
}

// MARK: - View 条件修饰符扩展

extension View {
    /// 条件应用修饰符
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - 预览

#Preview {
    InspectorContentView()
        .environmentObject(AppState())
        .frame(width: 300, height: 500)
}
