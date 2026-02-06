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
            return "Starting on port \(port) (attempt \(attempt)/\(AppConfig.maxPortRetries))"
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
        appState.connectionState == .connected ? .green : .red
    }

    private var helpText: String {
        appState.connectionState == .connected ? "connection.connected".localized : "connection.disconnected".localized
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

    /// 连接状态颜色
    private var statusColor: Color {
        appState.connectionState == .connected ? .green : .red
    }

    /// 当前分支名称
    private var currentBranch: String? {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getGitBranchCache(workspaceKey: ws),
              !cache.current.isEmpty else {
            return nil
        }
        return cache.current
    }

    var body: some View {
        if appState.selectedWorkspaceKey != nil {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .help(appState.connectionState == .connected ? "connection.connected".localized : "connection.disconnected".localized)

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
            .padding(.horizontal, 8)
        }
    }
}

/// 应用标题视图（未选择工作空间时显示）
struct AppTitleView: View {
    var body: some View {
        HStack(spacing: 6) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            Text("TidyFlow")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
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
            toolbarButtonIcon
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
