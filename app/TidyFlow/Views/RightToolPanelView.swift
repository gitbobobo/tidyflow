import SwiftUI

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

/// 与源代码管理面板标题一致的通用标题栏：左侧标题、右侧刷新 + 三点菜单
struct PanelHeaderView<MenuContent: View>: View {
    let title: String
    var onRefresh: (() -> Void)?
    var isRefreshDisabled: Bool = false
    @ViewBuilder var menuContent: () -> MenuContent

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

            Menu {
                menuContent()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
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
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let trailing = trailingText {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
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
        self.customIconView = nil
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
            ) {
                Button("刷新") {
                    appState.fetchFileList(workspaceKey: workspaceKey, path: ".")
                }
            }
            
            // 文件列表
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FileListContent(workspaceKey: workspaceKey, path: ".", depth: 0)
                        .environmentObject(appState)
                }
                .padding(4)
            }
        }
        .onAppear {
            // 首次加载时请求根目录文件列表
            if appState.getFileListCache(workspaceKey: workspaceKey, path: ".") == nil {
                appState.fetchFileList(workspaceKey: workspaceKey, path: ".")
            }
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
            if cache.isLoading && cache.items.isEmpty {
                // 加载中
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.7)
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.leading, CGFloat(depth * 16 + 8))
            } else if let error = cache.error {
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

    private var iconColor: Color {
        if item.isDir {
            return .accentColor
        } else {
            return .secondary
        }
    }

    /// 当前文件是否为资源管理器中应高亮的“当前打开文件”（与活动编辑器标签一致）
    private var isSelected: Bool {
        !item.isDir
            && appState.selectedWorkspaceKey == workspaceKey
            && appState.activeEditorPath == item.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TreeRowView(
                isExpandable: item.isDir,
                isExpanded: isExpanded,
                iconName: iconName,
                iconColor: iconColor,
                title: item.name,
                depth: depth,
                isSelected: isSelected,
                selectedBackgroundColor: Color.accentColor.opacity(0.35),
                onTap: { handleTap() }
            )

            if item.isDir && isExpanded {
                FileListContent(
                    workspaceKey: workspaceKey,
                    path: item.path,
                    depth: depth + 1
                )
                .environmentObject(appState)
            }
        }
    }

    private func handleTap() {
        if item.isDir {
            // 目录：切换展开状态
            appState.toggleDirectoryExpanded(workspaceKey: workspaceKey, path: item.path)
        } else {
            // 文件：打开编辑器（使用全局工作空间键）
            if let globalKey = appState.currentGlobalWorkspaceKey {
                appState.addEditorTab(workspaceKey: globalKey, path: item.path)
            }
        }
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
        case "json":
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

// MARK: - 预览

#Preview {
    InspectorContentView()
        .environmentObject(AppState())
        .frame(width: 300, height: 500)
}
