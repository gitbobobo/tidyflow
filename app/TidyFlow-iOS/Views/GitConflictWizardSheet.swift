import SwiftUI
import TidyFlowShared

#if os(iOS)

// MARK: - iOS Git 冲突向导 Sheet

/// iOS 冲突向导，以 sheet 呈现冲突文件导航、内容对比与解决操作。
/// 动作语义、可用条件、continue/abort 行为与 macOS GitConflictWizardView 保持一致。
/// 严格消费 MobileAppState.conflictWizardCache，不额外发明移动端专有冲突状态。
struct GitConflictWizardSheet: View {
    @EnvironmentObject var appState: MobileAppState
    @Environment(\.dismiss) private var dismiss

    let project: String
    let workspace: String
    /// "workspace" 或 "integration"
    let context: String

    var body: some View {
        NavigationStack {
            Group {
                if wizard.conflictFileCount == 0 {
                    allResolvedView
                } else {
                    conflictList
                }
            }
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    refreshButton
                }
            }
            .safeAreaInset(edge: .bottom) {
                footerActions
            }
        }
    }

    // MARK: - 子视图

    private var conflictList: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Section("git.conflict.files".localized) {
                ForEach(conflictFiles, id: \.path) { file in
                    NavigationLink(
                        destination: ConflictFileDetailView(
                            project: project,
                            workspace: workspace,
                            context: context,
                            file: file
                        )
                        .environmentObject(appState)
                    ) {
                        IOSConflictFileRow(file: file)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var allResolvedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("git.conflict.allResolved".localized)
                .font(.title3.bold())
            Text("git.conflict.allResolvedHint".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var footerActions: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                // Abort
                Button(role: .destructive, action: abortOperation) {
                    Label("git.conflict.abort".localized, systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                // Continue
                Button(action: continueOperation) {
                    HStack {
                        if isContinueInFlight {
                            ProgressView().scaleEffect(0.7)
                        }
                        Label("git.conflict.continue".localized, systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue || isContinueInFlight)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(uiColor: .systemBackground))
        }
    }

    private var refreshButton: some View {
        Button(action: refreshWizard) {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(wizard.isLoading)
    }

    // MARK: - 计算属性

    private var wizard: ConflictWizardCache {
        let key = context == "integration"
            ? "\(project):integration"
            : "\(project):\(workspace)"
        return appState.conflictWizardCache[key] ?? ConflictWizardCache.empty()
    }

    private var conflictFiles: [ConflictFileEntry] {
        wizard.snapshot?.files ?? []
    }

    private var resolvedCount: Int { conflictFiles.filter { $0.staged }.count }
    private var totalCount: Int { conflictFiles.count }

    private var headerTitle: String {
        context == "integration"
            ? "git.conflict.headerIntegration".localized
            : "git.conflict.header".localized
    }

    private var headerSubtitle: String {
        String(format: "git.conflict.progress".localized, resolvedCount, totalCount)
    }

    private var canContinue: Bool {
        wizard.snapshot?.allResolved == true || resolvedCount == totalCount
    }

    private var isContinueInFlight: Bool {
        if context == "integration" {
            return appState.conflictWizardCache["\(project):integration"]?.isLoading == true
        }
        return false
    }

    // MARK: - 操作

    private func refreshWizard() {
        appState.fetchGitDetailForWorkspace(project: project, workspace: workspace)
    }

    private func continueOperation() {
        if context == "integration" {
            // iOS 端 integration 冲突目前仅由 merge-to-default 触发
            appState.wsClient.requestGitMergeContinue(project: project)
        } else {
            appState.wsClient.requestGitRebaseContinue(project: project, workspace: workspace)
        }
        dismiss()
    }

    private func abortOperation() {
        if context == "integration" {
            appState.wsClient.requestGitMergeAbort(project: project)
        } else {
            appState.wsClient.requestGitRebaseAbort(project: project, workspace: workspace)
        }
        dismiss()
    }
}

// MARK: - iOS 冲突文件行

private struct IOSConflictFileRow: View {
    let file: ConflictFileEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.staged ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(file.staged ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.subheadline)
                if !fileDir.isEmpty {
                    Text(fileDir)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Text(conflictTypeBadge)
                .font(.caption2.bold())
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(4)
        }
        .padding(.vertical, 2)
    }

    private var fileName: String { URL(fileURLWithPath: file.path).lastPathComponent }
    private var fileDir: String {
        let dir = (file.path as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }
    private var conflictTypeBadge: String {
        switch file.conflictType {
        case "add_add": return "AA"
        case "delete_modify": return "DM"
        case "modify_delete": return "MD"
        default: return "UU"
        }
    }
}

// MARK: - iOS 冲突文件详情页（推入导航）

struct ConflictFileDetailView: View {
    @EnvironmentObject var appState: MobileAppState

    let project: String
    let workspace: String
    let context: String
    let file: ConflictFileEntry

    @State private var selectedTab: DetailTab = .current

    enum DetailTab: String, CaseIterable {
        case current, ours, theirs, base
        var label: String {
            switch self {
            case .current: return "git.conflict.tab.current".localized
            case .ours: return "git.conflict.tab.ours".localized
            case .theirs: return "git.conflict.tab.theirs".localized
            case .base: return "git.conflict.tab.base".localized
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 操作区
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    conflictActionButton(
                        label: "git.conflict.acceptOurs".localized,
                        icon: "arrow.left.circle.fill",
                        color: .blue,
                        action: acceptOurs
                    )
                    conflictActionButton(
                        label: "git.conflict.acceptTheirs".localized,
                        icon: "arrow.right.circle.fill",
                        color: .purple,
                        action: acceptTheirs
                    )
                    conflictActionButton(
                        label: "git.conflict.acceptBoth".localized,
                        icon: "arrow.left.arrow.right.circle.fill",
                        color: .teal,
                        action: acceptBoth
                    )
                    Divider().frame(height: 28)
                    conflictActionButton(
                        label: "git.conflict.markResolved".localized,
                        icon: "checkmark.circle.fill",
                        color: .green,
                        action: markResolved
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            Divider()
            // 选项卡
            Picker("", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.rawValue) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            // 内容区
            contentView
        }
        .navigationTitle(URL(fileURLWithPath: file.path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadDetail() }
    }

    @ViewBuilder
    private var contentView: some View {
        if let detail = currentDetail {
            if detail.isBinary {
                VStack {
                    Spacer()
                    Label("git.conflict.binaryFile".localized, systemImage: "doc.zipper")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    Text(contentForTab(selectedTab, detail: detail) ?? "git.conflict.noContent".localized)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if isLoading {
            VStack {
                Spacer()
                ProgressView()
                Text("git.conflict.loading".localized).font(.subheadline).foregroundColor(.secondary).padding(.top, 8)
                Spacer()
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "doc.badge.ellipsis")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("git.conflict.loadDetail".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button("git.conflict.loadDetailAction".localized) { loadDetail() }
                    .buttonStyle(.bordered)
                Spacer()
            }
        }
    }

    private var cacheKey: String {
        context == "integration" ? "\(project):integration" : "\(project):\(workspace)"
    }

    private var currentDetail: GitConflictDetailResultCache? {
        appState.conflictWizardCache[cacheKey]?.currentDetail
    }

    private var isLoading: Bool {
        appState.conflictWizardCache[cacheKey]?.isLoading == true
    }

    private func contentForTab(_ tab: DetailTab, detail: GitConflictDetailResultCache) -> String? {
        switch tab {
        case .current: return detail.currentContent.isEmpty ? nil : detail.currentContent
        case .ours: return detail.oursContent
        case .theirs: return detail.theirsContent
        case .base: return detail.baseContent
        }
    }

    private func loadDetail() {
        var wizard = appState.conflictWizardCache[cacheKey] ?? ConflictWizardCache.empty()
        wizard.isLoading = true
        wizard.selectedFilePath = file.path
        appState.conflictWizardCache[cacheKey] = wizard
        appState.wsClient.requestGitConflictDetail(
            project: project,
            workspace: workspace,
            path: file.path,
            context: context
        )
    }

    private func conflictActionButton(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .tint(color)
    }

    private func acceptOurs() {
        appState.wsClient.requestGitConflictAcceptOurs(project: project, workspace: workspace, path: file.path, context: context)
    }
    private func acceptTheirs() {
        appState.wsClient.requestGitConflictAcceptTheirs(project: project, workspace: workspace, path: file.path, context: context)
    }
    private func acceptBoth() {
        appState.wsClient.requestGitConflictAcceptBoth(project: project, workspace: workspace, path: file.path, context: context)
    }
    private func markResolved() {
        appState.wsClient.requestGitConflictMarkResolved(project: project, workspace: workspace, path: file.path, context: context)
    }
}

#endif // os(iOS)
