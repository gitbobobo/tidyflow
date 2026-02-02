import SwiftUI

// MARK: - Inspector Content View（符合苹果 HIG 规范）

/// 右侧检查器内容视图
/// 使用 .inspector() API 时作为内容显示
struct InspectorContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 工具选择器（使用 Picker 符合 HIG 规范）
            Picker("工具", selection: $appState.activeRightTool) {
                Label("文件", systemImage: "folder")
                    .tag(RightTool?.some(.explorer))
                Label("搜索", systemImage: "magnifyingglass")
                    .tag(RightTool?.some(.search))
                Label("Git", systemImage: "arrow.triangle.branch")
                    .tag(RightTool?.some(.git))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // 内容区域
            Group {
                switch appState.activeRightTool {
                case .explorer:
                    ExplorerPlaceholderView()
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
        // Inspector 自动使用 grouped 样式背景
        .background(Color(NSColor.windowBackgroundColor))
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
