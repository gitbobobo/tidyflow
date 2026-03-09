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
            let tools: [RightTool] = [.explorer, .search, .git, .todos, .evidence, .evolution]
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
        case .evidence: return "photo.stack"
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
        case .evidence: return "rightPanel.evidence".localized
        case .evolution: return "evolution.page.title".localized
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
                case .todos:
                    TodoInspectorView()
                        .environmentObject(appState)
                case .sessions:
                    // 会话列表已移至聊天界面左侧侧边栏，右侧面板不再显示
                    EmptyView()
                case .evidence:
                    EvidenceTabView(appState: appState)
                case .evolution:
                    EvolutionPipelineView(appState: appState)
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

struct TreeRowActivityIndicator: Identifiable {
    let id: String
    let iconName: String
}

private struct TreeRowActivityPhaseKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    var treeRowActivityPhase: Double? {
        get { self[TreeRowActivityPhaseKey.self] }
        set { self[TreeRowActivityPhaseKey.self] = newValue }
    }
}

struct TreeRowActivityPhaseProvider<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
            let cycle = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.8) / 1.8
            content()
                .environment(\.treeRowActivityPhase, cycle)
        }
    }
}

private struct TreeRowActivityIndicatorsView: View {
    let indicators: [TreeRowActivityIndicator]
    @Environment(\.treeRowActivityPhase) private var sharedPhase

    var body: some View {
        indicatorIcons(maskStyle: false)
            .overlay {
                if let sharedPhase, !indicators.isEmpty {
                    GeometryReader { proxy in
                        let width = max(8, proxy.size.width * 0.45)
                        let offset = (sharedPhase * 1.6 - 0.3) * proxy.size.width
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.85),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: width, height: proxy.size.height * 1.6)
                        .rotationEffect(.degrees(16))
                        .offset(x: offset, y: -proxy.size.height * 0.3)
                    }
                    .mask(indicatorIcons(maskStyle: true))
                    .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func indicatorIcons(maskStyle: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(indicators) { indicator in
                CommandIconView(iconName: indicator.iconName, size: 11)
                    .foregroundColor(maskStyle ? .white : .secondary)
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
    @EnvironmentObject var appState: AppState
    @State private var draftTitle: String = ""
    @State private var draftNote: String = ""
    @State private var editingItem: WorkspaceTodoItem?

    private var workspaceKey: String? {
        appState.currentGlobalWorkspaceKey
    }

    private var pendingTodos: [WorkspaceTodoItem] {
        appState.workspaceTodos(for: workspaceKey).filter { $0.status == .pending }
    }

    private var inProgressTodos: [WorkspaceTodoItem] {
        appState.workspaceTodos(for: workspaceKey).filter { $0.status == .inProgress }
    }

    private var completedTodos: [WorkspaceTodoItem] {
        appState.workspaceTodos(for: workspaceKey).filter { $0.status == .completed }
    }

    var body: some View {
        Group {
            if let workspaceKey {
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
        let isEmpty = pendingTodos.isEmpty && inProgressTodos.isEmpty && completedTodos.isEmpty
        if isEmpty {
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
                todoSection(
                    title: "todo.section.pending".localized,
                    workspaceKey: workspaceKey,
                    status: .pending,
                    items: pendingTodos
                )
                todoSection(
                    title: "todo.section.inProgress".localized,
                    workspaceKey: workspaceKey,
                    status: .inProgress,
                    items: inProgressTodos
                )
                todoSection(
                    title: "todo.section.completed".localized,
                    workspaceKey: workspaceKey,
                    status: .completed,
                    items: completedTodos
                )
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
        title: String,
        workspaceKey: String,
        status: WorkspaceTodoStatus,
        items: [WorkspaceTodoItem]
    ) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
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
                        status: status,
                        fromOffsets: from,
                        toOffset: to
                    )
                }
            }
        }
    }
}

private struct TodoRowView: View {
    let item: WorkspaceTodoItem
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
    let item: WorkspaceTodoItem
    let onSave: (String, String?) -> Void

    @State private var title: String
    @State private var note: String

    init(item: WorkspaceTodoItem, onSave: @escaping (String, String?) -> Void) {
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
