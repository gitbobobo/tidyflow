import SwiftUI
import TidyFlowShared

/// iOS 工作区 Diff Inspector。
/// 路由入口：MobileRoute.workspaceDiff(project:workspace:path:mode)
/// 所有入口必须显式携带 project/workspace/path/mode，禁止依赖当前全局工作区隐式推导。
struct WorkspaceDiffView: View {
    @EnvironmentObject var appState: MobileAppState

    let project: String
    let workspace: String
    let path: String
    let initialMode: String

    /// "working" 或 "staged"
    @State private var currentMode: String

    init(project: String, workspace: String, path: String, initialMode: String) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.initialMode = initialMode
        self._currentMode = State(initialValue: initialMode == "staged" ? "staged" : "working")
    }

    private var descriptor: DiffDescriptor {
        DiffDescriptor(project: project, workspace: workspace, path: path, mode: currentMode)
    }

    private var cache: DiffCache? {
        appState.gitDiffCache(for: descriptor)
    }

    var body: some View {
        Group {
            if let cache {
                diffBody(cache: cache)
            } else {
                loadingView
            }
        }
        .navigationTitle(URL(string: path)?.lastPathComponent ?? path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.requestGitDiff(descriptor: descriptor, force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            modeToggle
        }
        .onAppear {
            appState.requestGitDiff(descriptor: descriptor)
        }
        .onChange(of: currentMode) { _, _ in
            appState.requestGitDiff(descriptor: descriptor)
        }
        .refreshable {
            appState.requestGitDiff(descriptor: descriptor, force: true)
        }
    }

    // MARK: - 模式切换栏

    private var modeToggle: some View {
        Picker("Diff 模式", selection: $currentMode) {
            Text("工作区").tag("working")
            Text("暂存区").tag("staged")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Diff 主体

    @ViewBuilder
    private func diffBody(cache: DiffCache) -> some View {
        if cache.isLoading {
            loadingView
        } else if let error = cache.error {
            errorView(message: error)
        } else if cache.isBinary {
            binaryView
        } else if cache.parsedLines.isEmpty {
            emptyView
        } else {
            VStack(spacing: 0) {
                if cache.truncated {
                    truncatedBanner
                }
                diffLinesView(lines: cache.parsedLines)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("加载 Diff…")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.red)
            Text("加载失败")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var binaryView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.binary")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("二进制文件")
                .font(.headline)
            Text("此文件为二进制格式，无法预览 Diff。")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(currentMode == "staged" ? "暂存区无变更" : "工作区无变更")
                .font(.headline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var truncatedBanner: some View {
        HStack {
            Image(systemName: "info.circle")
                .foregroundColor(.orange)
            Text("Diff 内容已截断（文件过大）")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func diffLinesView(lines: [DiffLine]) -> some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(lines) { line in
                    DiffLineRow(line: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 只读 Diff 行（iOS WorkspaceDiffView 专用）

/// iOS 端内联 Diff 行视图，使用 TidyFlowShared 的 DiffLine 模型。
/// macOS 共享版本见 GitDiffLineView.swift 中的 DiffLineRowView。
private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 8) {
            Text(line.oldLineNumber.map { String($0) } ?? "")
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 11, design: .monospaced))
            Text(line.newLineNumber.map { String($0) } ?? "")
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 11, design: .monospaced))
            Text(linePrefix)
                .foregroundColor(prefixColor)
                .font(.system(size: 11, design: .monospaced))
            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(lineBackground)
    }

    private var linePrefix: String {
        switch line.kind {
        case .add: return "+"
        case .del: return "-"
        case .context: return " "
        case .hunk: return "@@"
        case .header: return " "
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .add: return .green
        case .del: return .red
        case .hunk: return .blue
        default: return .secondary
        }
    }

    private var lineBackground: Color {
        switch line.kind {
        case .add: return Color.green.opacity(0.10)
        case .del: return Color.red.opacity(0.10)
        case .hunk: return Color.blue.opacity(0.08)
        default: return Color.clear
        }
    }
}
