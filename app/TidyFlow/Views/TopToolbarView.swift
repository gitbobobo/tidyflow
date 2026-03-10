import SwiftUI

/// Shows Core process status (Starting/Running/Restarting/Failed) with port info
struct CoreStatusView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var coreManager: CoreProcessManager

    init(coreManager: CoreProcessManager) {
        self.coreManager = coreManager
    }

    private var statusColor: Color {
        switch coreManager.status {
        case .stopped: return .gray
        case .starting: return .orange
        case .running: return .green
        case .restarting: return .yellow
        case .failed: return .red
        }
    }

    private var statusIcon: String {
        switch coreManager.status {
        case .stopped: return "stop.circle"
        case .starting: return "hourglass"
        case .running: return "checkmark.circle"
        case .restarting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var helpText: String {
        switch coreManager.status {
        case .running(let port, let pid):
            return "Core running on port \(port) (PID: \(pid))\nCmd+R to restart"
        case .starting(let attempt, let port):
            let portText = port.map(String.init) ?? "?"
            return "Starting on port \(portText) (attempt \(attempt)/\(AppConfig.maxPortRetries))"
        case .restarting(let attempt, let max, let lastError):
            var text = "Auto-restarting (attempt \(attempt)/\(max))"
            if let err = lastError {
                text += "\nLast error: \(err)"
            }
            return text
        case .failed(let msg):
            return "Failed: \(msg)\nCmd+R to retry\n\n\(CoreProcessManager.manualRunInstructions)"
        case .stopped:
            return "Core stopped\nCmd+R to start"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.caption)

            Text("Core: \(coreManager.status.displayText)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .help(helpText)
    }
}

/// 连接状态指示器（仅显示圆点）
struct ConnectionStatusView: View {
    @EnvironmentObject var appState: AppState

    private var statusColor: Color {
        appState.connectionPhase.isConnected ? .green : .red
    }

    private var helpText: String {
        appState.connectionPhase.isConnected ? "connection.connected".localized : "connection.disconnected".localized
    }

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .help(helpText)
    }
}

/// 显示当前项目名称和分支（格式：● project:branch）
struct ProjectBranchView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    @State private var showingIssuesPopover = false

    private var currentWorkspaceGlobalKey: String? {
        appState.currentGlobalWorkspaceKey
    }

    /// 当前工作空间诊断快照
    private var diagnosticsSnapshot: WorkspaceDiagnosticsSnapshot {
        appState.diagnosticsSnapshot(for: currentWorkspaceGlobalKey)
    }

    /// 顶部圆点颜色：诊断语义（Error/Warning/Info/None）
    private var diagnosticsColor: Color {
        return diagnosticsSnapshot.highestSeverity.dotColor
    }

    private var diagnosticsHelpText: String {
        let connectionText = appState.connectionPhase.isConnected
            ? "connection.connected".localized
            : "connection.disconnected".localized
        let base = String(
            format: "toolbar.diagnostics.help".localized,
            diagnosticsSnapshot.highestSeverity.localizedName,
            diagnosticsSnapshot.items.count,
            connectionText
        )
        if appState.connectionPhase.isConnected {
            return base
        }
        return "\(base)\n\("toolbar.diagnostics.disconnectedHint".localized)"
    }

    /// 当前分支名称（统一从共享语义快照读取，与 Git 状态数据源保持一致）
    private var currentBranch: String? {
        guard let ws = appState.selectedWorkspaceKey else { return nil }
        return gitCache.getGitSemanticSnapshot(workspaceKey: ws).currentBranch
    }

    var body: some View {
        if let globalKey = currentWorkspaceGlobalKey {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(diagnosticsColor)
                        .frame(width: 8, height: 8)
                    if !appState.connectionPhase.isConnected {
                        Circle()
                            .stroke(Color.red, lineWidth: 1)
                            .frame(width: 10, height: 10)
                    }
                }
                .help(diagnosticsHelpText)

                Button {
                    showingIssuesPopover.toggle()
                } label: {
                    HStack(spacing: 0) {
                        Text(appState.selectedProjectName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)

                        if let branch = currentBranch {
                            Text(":")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(branch)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("toolbar.diagnostics.openIssues".localized)
                .popover(isPresented: $showingIssuesPopover) {
                    WorkspaceIssuePopoverView(workspaceGlobalKey: globalKey) {
                        showingIssuesPopover = false
                    }
                    .environmentObject(appState)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 2)
        }
    }
}

// MARK: - 工作空间问题列表弹框

private struct WorkspaceIssuePopoverView: View {
    @EnvironmentObject var appState: AppState
    let workspaceGlobalKey: String
    let onSelectIssue: () -> Void

    private var snapshot: WorkspaceDiagnosticsSnapshot {
        appState.diagnosticsSnapshot(for: workspaceGlobalKey)
    }

    private var groupedPaths: [String] {
        let keys = Set(snapshot.items.map { $0.displayPath })
        return keys.sorted()
    }

    private var errorCount: Int {
        snapshot.items.filter { $0.severity == .error }.count
    }

    private var warningCount: Int {
        snapshot.items.filter { $0.severity == .warning }.count
    }

    private var infoCount: Int {
        snapshot.items.filter { $0.severity == .info }.count
    }

    private func issues(for path: String) -> [ProjectDiagnosticItem] {
        snapshot.items.filter { $0.displayPath == path }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("toolbar.diagnostics.issueListTitle".localized)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 8) {
                    statBadge(title: String(format: "toolbar.diagnostics.countErrors".localized, errorCount), color: .red)
                    statBadge(title: String(format: "toolbar.diagnostics.countWarnings".localized, warningCount), color: .orange)
                    statBadge(title: String(format: "toolbar.diagnostics.countInfo".localized, infoCount), color: .blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if snapshot.items.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 26))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("toolbar.diagnostics.noIssues".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groupedPaths, id: \.self) { path in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(path)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)

                                ForEach(issues(for: path)) { item in
                                    issueRow(item)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private func issueRow(_ item: ProjectDiagnosticItem) -> some View {
        let canJump = item.editorPath != nil
        Button {
            guard let editorPath = item.editorPath else { return }
            appState.addEditorTab(workspaceKey: workspaceGlobalKey, path: editorPath, line: item.line)
            onSelectIssue()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.severity.iconName)
                    .font(.system(size: 11))
                    .foregroundColor(item.severity.dotColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.summary)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)

                    Text(issueLocationText(item))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help(canJump ? "toolbar.diagnostics.jumpToIssue".localized : "toolbar.diagnostics.cannotJump".localized)
    }

    private func issueLocationText(_ item: ProjectDiagnosticItem) -> String {
        if let col = item.column {
            return "L\(item.line):\(col)"
        }
        return "L\(item.line)"
    }

    @ViewBuilder
    private func statBadge(title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

}

private extension DiagnosticSeverity {
    var dotColor: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        case .none: return .green
        }
    }

    var iconName: String {
        switch self {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .none: return "checkmark.circle.fill"
        }
    }

    var localizedName: String {
        switch self {
        case .error: return "toolbar.diagnostics.severity.error".localized
        case .warning: return "toolbar.diagnostics.severity.warning".localized
        case .info: return "toolbar.diagnostics.severity.info".localized
        case .none: return "toolbar.diagnostics.severity.none".localized
        }
    }
}

/// 应用标题视图（未选择工作空间时显示）
struct AppTitleView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.fill")
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(Color.accentColor)
            Text("TidyFlow")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
            Text("·")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary.opacity(0.6))
            Text("toolbar.slogan".localized)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
    }
}

/// UX-1: Add Project button for toolbar
struct AddProjectButtonView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button(action: {
            appState.addProjectSheetPresented = true
        }) {
            Image(systemName: "plus")
        }
        .help("Add Project")
    }
}

// MARK: - 固定尺寸的工具栏/菜单图标（macOS 会提取底层图片按 intrinsic size 显示，需在绘制时缩放到目标尺寸）
struct FixedSizeAssetImage: View {
    let name: String
    let targetSize: CGFloat

    var body: some View {
        let size = CGSize(width: targetSize, height: targetSize)
        let image = Image(name)
        return Image(size: size, label: Text(name)) { ctx in
            let resolved = ctx.resolve(image)
            let imageSize = resolved.size
            let maxDim = max(imageSize.width, imageSize.height, 1)
            let w = targetSize * imageSize.width / maxDim
            let h = targetSize * imageSize.height / maxDim
            let x = (targetSize - w) / 2
            let y = (targetSize - h) / 2
            ctx.draw(resolved, in: CGRect(x: x, y: y, width: w, height: h))
        }
    }
}

// MARK: - 在外部编辑器中打开工作空间按钮（ExternalEditor 定义在 Models.swift）
struct OpenInEditorButtonView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAlert = false
    @State private var alertMessage = ""

    /// 获取已安装的编辑器列表
    private var installedEditors: [ExternalEditor] {
        ExternalEditor.allCases.filter { $0.isInstalled }
    }

    /// 工具栏按钮图标尺寸（与其它工具栏图标一致）
    private let toolbarIconSize: CGFloat = 18

    /// 菜单项图标尺寸
    private let menuIconSize: CGFloat = 16

    /// 工具栏按钮图标：用固定尺寸绘制，使 macOS 工具栏按目标尺寸显示
    private var toolbarButtonIcon: some View {
        Group {
            if let first = installedEditors.first {
                FixedSizeAssetImage(name: first.assetName, targetSize: toolbarIconSize)
            } else {
                Image(systemName: "cursorarrow.and.square.on.square.dashed")
                    .font(.system(size: toolbarIconSize))
            }
        }
    }

    /// 菜单项图标：用固定尺寸绘制，使 macOS 菜单按目标尺寸显示
    private func editorMenuIcon(_ editor: ExternalEditor) -> some View {
        FixedSizeAssetImage(name: editor.assetName, targetSize: menuIconSize)
    }

    var body: some View {
        Menu {
            ForEach(ExternalEditor.allCases, id: \.self) { editor in
                Button(action: {
                    if let path = appState.selectedWorkspacePath, !appState.openPathInEditor(path, editor: editor) {
                        alertMessage = "toolbar.openFailed".localized
                        showingAlert = true
                    }
                }) {
                    Label {
                        Text(editor.rawValue)
                    } icon: {
                        editorMenuIcon(editor)
                    }
                }
                .disabled(!editor.isInstalled)
            }
        } label: {
            HStack(spacing: 4) {
                toolbarButtonIcon
                Text("toolbar.open".localized)
            }
            .help("toolbar.openInEditor".localized)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8)
        .disabled(appState.selectedWorkspacePath == nil)
        .alert("toolbar.openEditorFailed".localized, isPresented: $showingAlert) {
            Button("common.confirm".localized, role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
}

// MARK: - Deprecated: ProjectPickerView (removed in UX-1)
// Workspace selection now happens in the sidebar via ProjectsSidebarView
