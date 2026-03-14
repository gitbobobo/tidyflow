import SwiftUI
import Shimmer
import TidyFlowShared

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
            let tools: [RightTool] = [.explorer, .search, .git, .todos, .evolution]
            let segmentW = max(0, geo.size.width) / CGFloat(tools.count)
            let fullH = max(24, geo.size.height - 4)

            HStack(spacing: 0) {
                ForEach(tools, id: \.self) { tool in
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
        case .todos: return "checklist"
        case .sessions: return "bubble.left.and.bubble.right"
        case .evolution: return "brain.head.profile"
        }
    }

    private func accessibilityLabel(for tool: RightTool) -> String {
        switch tool {
        case .explorer: return "rightPanel.files".localized
        case .search: return "rightPanel.search".localized
        case .git: return "Git"
        case .todos: return "rightPanel.todos".localized
        case .sessions: return "rightPanel.sessions".localized
        case .evolution: return "evolution.page.title".localized
        }
    }
}

// MARK: - Inspector Content View（符合苹果 HIG 规范）

/// 右侧检查器内容视图
/// 使用 .inspector() API 时作为内容显示
struct InspectorContentView: View {
    @EnvironmentObject var appState: AppState

    private var activeRightToolSelection: Binding<RightTool?> {
        Binding(
            get: { appState.activeRightTool },
            set: { appState.activeRightTool = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // 工具选择器：Xcode 风格胶囊、仅图标（自定义 CapsuleSegmentedControl）
            CapsuleSegmentedControl(selection: activeRightToolSelection)
                .padding(.horizontal, 12)

            // 内容区域
            Group {
                switch appState.activeRightTool {
                case .explorer:
                    ExplorerView()
                        .environmentObject(appState)
                case .search:
                    GlobalSearchPanelView()
                        .environmentObject(appState)
                case .git:
                    NativeGitPanelView()
                        .environmentObject(appState)
                case .todos:
                    TodoInspectorView(appState: appState)
                case .sessions:
                    // 会话列表已移至聊天界面左侧侧边栏，右侧面板不再显示
                    EmptyView()
                case .evolution:
                    EvolutionPipelineView(appState: appState)
                case .none:
                    NoToolSelectedView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

struct TreeRowActivityIndicator: Identifiable {
    let id: String
    let iconName: String
}

private struct TreeRowActivityIndicatorsView: View {
    let indicators: [TreeRowActivityIndicator]

    var body: some View {
        ZStack {
            indicatorIcons(foregroundStyle: .secondary)
            indicatorIcons(foregroundStyle: Color.white.opacity(0.95))
                .shimmering(
                    active: !indicators.isEmpty,
                    animation: .linear(duration: 1.8).repeatForever(autoreverses: false),
                    gradient: Gradient(colors: [
                        .clear,
                        .white,
                        .clear
                    ]),
                    bandSize: 0.45,
                    mode: .mask
                )
        }
    }

    private func indicatorIcons(foregroundStyle: Color) -> some View {
        HStack(spacing: 4) {
            ForEach(indicators) { indicator in
                CommandIconView(iconName: indicator.iconName, size: 11)
                    .foregroundStyle(foregroundStyle)
                    .frame(width: 12, height: 12)
            }
        }
    }
}

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
    /// 尾部活动图标（如聊天流式/进化循环/后台任务）
    var activityIndicators: [TreeRowActivityIndicator] = []
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
            if !activityIndicators.isEmpty {
                TreeRowActivityIndicatorsView(indicators: activityIndicators)
            }
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
        activityIndicators: [TreeRowActivityIndicator] = [],
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
        self.activityIndicators = activityIndicators
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
        activityIndicators: [TreeRowActivityIndicator] = [],
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
        self.activityIndicators = activityIndicators
        self.titleColor = titleColor
        self.trailingTextColor = trailingTextColor
        self.isLoading = isLoading
        self.customIconView = customIconView
        self.onTap = onTap
    }
}

// MARK: - 待办面板

struct TodoInspectorView: View {
    let appState: AppState
    @State private var draftTitle: String = ""
    @State private var draftNote: String = ""
    @State private var editingItem: WorkspaceTodoRowProjection?
    @State private var projectionStore = WorkspaceTodoProjectionStore()

    private var projection: WorkspaceTodoProjection {
        projectionStore.projection
    }

    var body: some View {
        Group {
            if let workspaceKey = projection.workspaceKey {
                VStack(spacing: 0) {
                    PanelHeaderView(title: "rightPanel.todos".localized)
                    composer(workspaceKey: workspaceKey)
                    Divider()
                    todoList(workspaceKey: workspaceKey)
                }
                .sheet(item: $editingItem) { item in
                    TodoEditSheet(item: item) { title, note in
                        _ = appState.updateWorkspaceTodo(
                            workspaceKey: workspaceKey,
                            todoID: item.id,
                            title: title,
                            note: note
                        )
                    }
                }
            } else {
                RightPanelNoWorkspaceView()
            }
        }
        .task(id: projection.workspaceKey ?? "no-workspace") {
            projectionStore.bind(appState: appState)
        }
    }

    @ViewBuilder
    private func composer(workspaceKey: String) -> some View {
        VStack(spacing: 8) {
            TextField("todo.input.title".localized, text: $draftTitle)
                .textFieldStyle(.roundedBorder)
            TextField("todo.input.note".localized, text: $draftNote)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("todo.add".localized) {
                    let created = appState.addWorkspaceTodo(
                        workspaceKey: workspaceKey,
                        title: draftTitle,
                        note: draftNote,
                        status: .pending
                    )
                    guard created != nil else { return }
                    draftTitle = ""
                    draftNote = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func todoList(workspaceKey: String) -> some View {
        if projection.totalCount == 0 {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "checklist")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("todo.empty".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(projection.sections) { section in
                    todoSection(workspaceKey: workspaceKey, section: section)
                }
            }
            .listStyle(.inset)
#if os(iOS)
            // iOS 侧始终处于编辑态，支持直接拖拽排序
            .environment(\.editMode, .constant(.active))
#endif
        }
    }

    @ViewBuilder
    private func todoSection(
        workspaceKey: String,
        section: WorkspaceTodoSectionProjection
    ) -> some View {
        Section(section.title) {
            ForEach(section.items) { item in
                TodoRowView(
                    item: item,
                    onEdit: { editingItem = item },
                    onDelete: {
                        _ = appState.deleteWorkspaceTodo(workspaceKey: workspaceKey, todoID: item.id)
                    },
                    onChangeStatus: { next in
                        _ = appState.setWorkspaceTodoStatus(
                            workspaceKey: workspaceKey,
                            todoID: item.id,
                            status: next
                        )
                    }
                )
            }
            .onMove { from, to in
                appState.moveWorkspaceTodos(
                    workspaceKey: workspaceKey,
                    status: section.status,
                    fromOffsets: from,
                    toOffset: to
                )
            }
        }
    }
}

private struct TodoRowView: View {
    let item: WorkspaceTodoRowProjection
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onChangeStatus: (WorkspaceTodoStatus) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let note = item.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Menu(item.status.localizedTitle) {
                ForEach(WorkspaceTodoStatus.allCases, id: \.rawValue) { status in
                    Button(status.localizedTitle) {
                        onChangeStatus(status)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("todo.edit".localized)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("todo.delete".localized)
        }
        .padding(.vertical, 2)
    }
}

private struct TodoEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: WorkspaceTodoRowProjection
    let onSave: (String, String?) -> Void

    @State private var title: String
    @State private var note: String

    init(item: WorkspaceTodoRowProjection, onSave: @escaping (String, String?) -> Void) {
        self.item = item
        self.onSave = onSave
        _title = State(initialValue: item.title)
        _note = State(initialValue: item.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("todo.edit".localized)
                .font(.headline)
            TextField("todo.input.title".localized, text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("todo.input.note".localized, text: $note)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("common.cancel".localized) {
                    dismiss()
                }
                Button("common.confirm".localized) {
                    onSave(title, note)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
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

// MARK: - 全局搜索面板

struct GlobalSearchPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""
    @State private var caseSensitive: Bool = false

    private var searchState: GlobalSearchState {
        appState.currentSearchState
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            resultContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 搜索输入栏

    private var searchBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("rightPanel.search.placeholder".localized, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit {
                        appState.performGlobalSearch(query: searchText, caseSensitive: caseSensitive)
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        appState.performGlobalSearch(query: "")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)

            HStack {
                Toggle(isOn: $caseSensitive) {
                    Text("Aa")
                        .font(.system(size: 11, weight: caseSensitive ? .bold : .regular, design: .monospaced))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("rightPanel.search.caseSensitive".localized)

                Spacer()

                if searchState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if searchState.hasResults {
                    Text("\(searchState.totalMatches) \("rightPanel.search.matches".localized)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if searchState.truncated {
                        Text("rightPanel.search.truncated".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - 结果区域

    @ViewBuilder
    private var resultContent: some View {
        if let error = searchState.error {
            statusView(icon: "exclamationmark.triangle", iconColor: .orange, message: error)
        } else if searchState.isLoading && !searchState.hasResults {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("rightPanel.search.searching".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchState.hasResults {
            resultList
        } else if !searchState.query.isEmpty {
            statusView(icon: "magnifyingglass", iconColor: .secondary.opacity(0.6), message: "rightPanel.search.noResults".localized)
        } else {
            statusView(icon: "magnifyingglass", iconColor: .secondary.opacity(0.4), message: "rightPanel.search.prompt".localized)
        }
    }

    private func statusView(icon: String, iconColor: Color, message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(iconColor)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(searchState.sections) { section in
                    SearchSectionView(section: section) { match in
                        appState.openSearchResult(match)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 搜索结果分组视图

private struct SearchSectionView: View {
    let section: GlobalSearchSection
    let onSelect: (GlobalSearchMatch) -> Void
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 文件头
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(section.fileName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if !section.directoryPath.isEmpty {
                        Text(section.directoryPath)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(section.matchCount)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            // 匹配列表
            if isExpanded {
                ForEach(section.matches) { match in
                    SearchMatchRowView(match: match)
                        .onTapGesture { onSelect(match) }
                }
            }
        }
    }
}

// MARK: - 搜索匹配行视图

private struct SearchMatchRowView: View {
    let match: GlobalSearchMatch

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(match.line)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 28, alignment: .trailing)

            highlightedPreview
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(Color.clear)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var highlightedPreview: some View {
        let segments = GlobalSearchPreviewFormatter.highlightedSegments(
            preview: match.preview,
            matchRanges: match.matchRanges
        )
        return segments.reduce(Text("")) { result, segment in
            if segment.isHighlighted {
                return result + Text(segment.text)
                    .foregroundColor(.accentColor)
                    .bold()
            } else {
                return result + Text(segment.text)
                    .foregroundColor(.primary)
            }
        }
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
