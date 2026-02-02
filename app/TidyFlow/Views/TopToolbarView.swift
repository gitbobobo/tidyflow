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

struct ConnectionStatusView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            Circle()
                .fill(appState.connectionState == .connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            Text(appState.connectionState == .connected ? "Connected" : "Disconnected")
                .font(.caption)

            Button(action: {
                appState.restartCore()
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Restart Core (Cmd+R)")
        }
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

// MARK: - 外部编辑器枚举
enum ExternalEditor: String, CaseIterable {
    case vscode = "VSCode"
    case cursor = "Cursor"

    /// 应用程序的 bundle identifier
    var bundleId: String {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        }
    }

    /// 命令行工具名称
    var cliCommand: String {
        switch self {
        case .vscode: return "code"
        case .cursor: return "cursor"
        }
    }

    /// 工程内嵌的官方图标名称（Assets.xcassets）
    var assetName: String {
        switch self {
        case .vscode: return "vscode-icon"
        case .cursor: return "cursor-icon"
        }
    }

    /// SF Symbol 备用图标（Asset 不可用时使用）
    var fallbackIconName: String {
        switch self {
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        }
    }

    /// 检查应用是否已安装
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }
}

/// 在外部编辑器中打开工作空间按钮
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
                    openInEditor(editor)
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
                .help("在外部编辑器中打开")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8)
        .disabled(appState.selectedWorkspacePath == nil)
        .alert("打开编辑器失败", isPresented: $showingAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    /// 在指定编辑器中打开当前工作空间
    private func openInEditor(_ editor: ExternalEditor) {
        guard let path = appState.selectedWorkspacePath else {
            alertMessage = "未选择工作空间"
            showingAlert = true
            return
        }

        guard editor.isInstalled else {
            alertMessage = "\(editor.rawValue) 未安装"
            showingAlert = true
            return
        }

        // 使用 open 命令打开编辑器
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-b", editor.bundleId, path]

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                alertMessage = "无法启动 \(editor.rawValue)"
                showingAlert = true
            }
        } catch {
            alertMessage = "启动失败: \(error.localizedDescription)"
            showingAlert = true
        }
    }
}

// MARK: - Deprecated: ProjectPickerView (removed in UX-1)
// Workspace selection now happens in the sidebar via ProjectsSidebarView
