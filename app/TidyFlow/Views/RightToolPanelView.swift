import SwiftUI

// 已拆分：
// - ExplorerView.swift       文件浏览器（ExplorerView, FileTreeView, FileListContent, FileRowView）
// - FileDialogViews.swift    对话框（NewFileDialogView, RenameDialogView）+ View 条件修饰符

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
        case .explorer: return "rightPanel.files".localized
        case .search: return "rightPanel.search".localized
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
                .help("common.refresh".localized)
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
    /// 尾部图标（如符号链接指示）
    var trailingIcon: String? = nil
    /// 标题文字颜色；nil 表示使用默认 .primary
    var titleColor: Color? = nil
    /// 尾部文字颜色；nil 表示使用默认 .secondary
    var trailingTextColor: Color? = nil
    /// 是否显示加载中指示器（如后台任务活跃时）
    var isLoading: Bool = false
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
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if let icon = trailingIcon {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
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
        if isSelected { return selectedBackgroundColor ?? Color.accentColor.opacity(0.8) }
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
        trailingIcon: String? = nil,
        titleColor: Color? = nil,
        trailingTextColor: Color? = nil,
        isLoading: Bool = false,
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
        self.trailingIcon = trailingIcon
        self.titleColor = titleColor
        self.trailingTextColor = trailingTextColor
        self.isLoading = isLoading
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
        trailingIcon: String? = nil,
        titleColor: Color? = nil,
        trailingTextColor: Color? = nil,
        isLoading: Bool = false,
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
        self.trailingIcon = trailingIcon
        self.titleColor = titleColor
        self.trailingTextColor = trailingTextColor
        self.isLoading = isLoading
        self.customIconView = customIconView
        self.onTap = onTap
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
            Text("rightPanel.explorerPlaceholder".localized)
                .font(.headline)
                .foregroundColor(.secondary)
            Text("rightPanel.comingSoon".localized)
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
            Text("rightPanel.globalSearch".localized)
                .font(.headline)
                .foregroundColor(.secondary)
            Text("rightPanel.comingSoon".localized)
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
            Text("rightPanel.noTool".localized)
                .font(.headline)
                .foregroundColor(.secondary)
            Text("rightPanel.noTool.hint".localized)
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
