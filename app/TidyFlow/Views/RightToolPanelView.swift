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
                .matchedGeometryEffect(id: effectiveSelection, in: capsuleNamespace, isSource: false)
        )
        .background(
            Capsule()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
        )
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
                NoWorkspaceSelectedView()
            }
        }
    }
}

/// 未选择工作空间提示
struct NoWorkspaceSelectedView: View {
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
            // 工具栏
            HStack {
                Text(workspaceKey)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                Button(action: {
                    appState.fetchFileList(workspaceKey: workspaceKey, path: ".")
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("刷新文件列表")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            // 文件列表
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FileListContent(workspaceKey: workspaceKey, path: ".", depth: 0)
                        .environmentObject(appState)
                }
                .padding(.vertical, 4)
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

/// 单个文件/目录行
struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let workspaceKey: String
    let item: FileEntry
    let depth: Int
    
    @State private var isHovering: Bool = false
    
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 当前行
            HStack(spacing: 4) {
                // 展开/折叠指示器（仅目录）
                if item.isDir {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                } else {
                    Spacer()
                        .frame(width: 12)
                }
                
                // 图标
                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundColor(iconColor)
                    .frame(width: 16)
                
                // 文件名
                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(depth * 16 + 8))
            .padding(.trailing, 8)
            .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .onTapGesture {
                handleTap()
            }
            
            // 子目录内容（展开时）
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
            // 文件：打开编辑器
            appState.addEditorTab(workspaceKey: workspaceKey, path: item.path)
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
