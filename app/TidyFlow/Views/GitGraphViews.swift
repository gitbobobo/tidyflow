import SwiftUI
import AppKit

// MARK: - 图形/历史区域（均分区域，内部可滚动）

struct GitGraphSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 小标题（始终显示）
            SectionHeader(
                title: "git.graph".localized,
                isExpanded: $isExpanded
            ) {
                EmptyView()
            }

            // 展开时显示提交历史列表（可滚动）
            if isExpanded {
                ScrollView {
                    VStack(spacing: 0) {
                        if let ws = appState.selectedWorkspaceKey {
                            if let cache = gitCache.getGitLogCache(workspaceKey: ws) {
                                if cache.isLoading && cache.entries.isEmpty {
                                    LoadingRow()
                                } else if cache.entries.isEmpty {
                                    EmptyRow(text: "git.noCommitHistory".localized)
                                } else {
                                    ForEach(cache.entries) { entry in
                                        GitLogRow(entry: entry)
                                            .environmentObject(appState)
                                    }
                                }
                            } else {
                                LoadingRow()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 提交历史行（支持折叠展开）

struct GitLogRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    let entry: GitLogEntry
    @State private var isHovered: Bool = false
    @State private var isExpanded: Bool = false
    @State private var showDetailWorkItem: DispatchWorkItem?
    @State private var isShowingFloatingPanel: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主行：默认只显示一行内容
            GeometryReader { geometry in
                HStack(spacing: 6) {
                    // 展开/折叠指示器
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                    
                    // 提交图标
                    Circle()
                        .fill(isHead ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    
                    // 提交消息（列表只显示一行）
                    Text(entry.message)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // 相对时间
                    Text(entry.relativeDate)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                    // 展开时加载文件列表
                    if isExpanded, let ws = appState.selectedWorkspaceKey {
                        gitCache.fetchGitShow(workspaceKey: ws, sha: entry.sha)
                    }
                }
                .onHover { hovering in
                    isHovered = hovering
                    handleHover(hovering: hovering, geometry: geometry)
                }
            }
            .frame(height: 26) // 固定行高，避免 GeometryReader 高度为 0
            
            // 展开后显示文件列表
            if isExpanded {
                CommitFilesView(sha: entry.sha)
                    .environmentObject(appState)
            }
        }
    }
    
    private func handleHover(hovering: Bool, geometry: GeometryProxy) {
        showDetailWorkItem?.cancel()
        showDetailWorkItem = nil
        
        if hovering {
            // 获取行的全局坐标 frame
            let globalFrame = geometry.frame(in: .global)
            
            let showPanel = {
                // 获取当前窗口
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
                
                // SwiftUI global 坐标系：原点在窗口内容区域左上角，Y 向下增长
                // NSWindow 坐标系：原点在窗口内容区域左下角，Y 向上增长
                // 需要将 SwiftUI Y 坐标转换为 NSWindow Y 坐标
                let contentHeight = window.contentView?.bounds.height ?? window.frame.height
                let windowPoint = NSPoint(
                    x: globalFrame.minX,
                    y: contentHeight - globalFrame.midY
                )
                
                CommitDetailPanelManager.shared.show(entry: self.entry, windowPoint: windowPoint, in: window)
                self.isShowingFloatingPanel = true
            }
            
            // 如果面板已经显示，直接切换内容，无需等待
            if CommitDetailPanelManager.shared.isVisible {
                showPanel()
            } else {
                // 面板未显示，等待 2 秒后弹出
                let work = DispatchWorkItem {
                    showPanel()
                }
                showDetailWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
            }
        } else {
            if isShowingFloatingPanel {
                // 请求隐藏，会有延迟给用户时间移入面板
                CommitDetailPanelManager.shared.requestHide(entryId: entry.id)
                isShowingFloatingPanel = false
            }
        }
    }

    private var isHead: Bool {
        entry.refs.contains { $0.contains("HEAD") }
    }
}

// MARK: - 提交文件列表视图

struct CommitFilesView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState
    let sha: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let ws = appState.selectedWorkspaceKey,
               let cache = gitCache.getGitShowCache(workspaceKey: ws, sha: sha) {
                if cache.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.6)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if let result = cache.result {
                    if result.files.isEmpty {
                        Text("git.noFileChanges".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(result.files) { file in
                            CommitFileRow(file: file)
                        }
                    }
                } else if let error = cache.error {
                    Text(String(format: "git.loadFailed".localized, error))
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 4)
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.6)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }
}

// MARK: - 提交文件行

struct CommitFileRow: View {
    let file: GitShowFileEntry
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // 缩进 + 状态标识
            Text(file.status)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(statusColor)
                .frame(width: 14, alignment: .center)
            
            // 文件图标
            Image(systemName: fileIcon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            
            // 文件名
            Text(fileName)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(1)
            
            // 目录路径
            if let dir = directoryPath {
                Text(dir)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 3)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var fileName: String {
        file.path.split(separator: "/").last.map(String.init) ?? file.path
    }

    private var directoryPath: String? {
        let components = file.path.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    private var fileIcon: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "rs": return "gear"
        case "js", "ts", "jsx", "tsx": return "j.square"
        case "json": return "curlybraces"
        case "md": return "doc.richtext"
        case "toml", "yaml", "yml": return "doc.text"
        default: return "doc"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        case "R": return .blue
        case "C": return .purple
        default: return .secondary
        }
    }
}

// MARK: - 辅助视图

struct LoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.7)
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

struct EmptyRow: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}
