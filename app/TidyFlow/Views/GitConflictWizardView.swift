import SwiftUI
import TidyFlowShared

#if os(macOS)
// MARK: - macOS Git 冲突向导视图

/// macOS Git 冲突向导
/// 在冲突状态下替换普通 Git 面板，提供冲突文件导航、内容对比与解决操作。
/// 严格消费 GitCacheState.conflictWizardCache，不在视图层重复推导业务规则。
struct GitConflictWizardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var gitCache: GitCacheState

    let project: String
    let workspace: String
    /// "workspace" 或 "integration"
    let context: String

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader
            Divider()
            if wizard.conflictFileCount == 0 {
                allResolvedPlaceholder
            } else {
                HSplitView {
                    fileListPanel
                        .frame(minWidth: 160, maxWidth: 240)
                    detailPanel
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            wizardFooter
        }
    }

    // MARK: - 子视图

    private var wizardHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 12, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: refreshWizard) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("git.conflict.refresh".localized)
            .disabled(wizard.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.07))
    }

    private var fileListPanel: some View {
        VStack(spacing: 0) {
            Text("git.conflict.files".localized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(conflictFiles, id: \.path) { file in
                        ConflictFileRow(
                            file: file,
                            isSelected: wizard.selectedFilePath == file.path
                        )
                        .onTapGesture { selectFile(file) }
                    }
                }
            }
        }
    }

    private var detailPanel: some View {
        VStack(spacing: 0) {
            if let detail = wizard.currentDetail {
                ConflictDetailView(
                    detail: detail,
                    filePath: wizard.selectedFilePath ?? "",
                    onAcceptOurs: { acceptOurs() },
                    onAcceptTheirs: { acceptTheirs() },
                    onAcceptBoth: { acceptBoth() },
                    onMarkResolved: { markResolved() },
                    onOpenEditor: { openInEditor() }
                )
            } else if wizard.isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Text("git.conflict.loading".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else if wizard.selectedFilePath != nil {
                VStack {
                    Spacer()
                    Image(systemName: "doc.badge.ellipsis")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("git.conflict.loadDetail".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                    Button("git.conflict.loadDetailAction".localized) {
                        loadCurrentFileDetail()
                    }
                    .font(.system(size: 11))
                    .padding(.top, 4)
                    Spacer()
                }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "arrow.left")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                    Text("git.conflict.selectFile".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wizardFooter: some View {
        HStack(spacing: 10) {
            Text(footerStepText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: abortOperation) {
                Text("git.conflict.abort".localized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help(abortHelpText)

            Button(action: continueOperation) {
                HStack(spacing: 4) {
                    if isContinueInFlight {
                        ProgressView().scaleEffect(0.55).frame(width: 12, height: 12)
                    }
                    Text("git.conflict.continue".localized)
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(canContinue ? Color.accentColor : Color.gray.opacity(0.3))
            .foregroundColor(canContinue ? .white : .secondary)
            .cornerRadius(4)
            .disabled(!canContinue || isContinueInFlight)
            .help(continueHelpText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var allResolvedPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundColor(.green)
            Text("git.conflict.allResolved".localized)
                .font(.system(size: 13, weight: .medium))
            Text("git.conflict.allResolvedHint".localized)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: - 计算属性

    private var wizard: ConflictWizardCache {
        gitCache.getConflictWizardCache(project: project, workspace: workspace, context: context)
    }

    private var conflictFiles: [ConflictFileEntry] {
        wizard.snapshot?.files ?? []
    }

    private var resolvedCount: Int {
        conflictFiles.filter { $0.staged }.count
    }

    private var totalCount: Int { conflictFiles.count }

    private var headerTitle: String {
        context == "integration"
            ? "git.conflict.headerIntegration".localized
            : "git.conflict.header".localized
    }

    private var headerSubtitle: String {
        String(format: "git.conflict.progress".localized, resolvedCount, totalCount)
    }

    private var footerStepText: String {
        if totalCount == 0 { return "git.conflict.allResolved".localized }
        let remaining = totalCount - resolvedCount
        return String(format: "git.conflict.remaining".localized, remaining)
    }

    private var canContinue: Bool {
        wizard.snapshot?.allResolved == true || resolvedCount == totalCount
    }

    private var isContinueInFlight: Bool {
        if context == "integration" {
            return gitCache.mergeInFlight[project] == true ||
                   gitCache.rebaseOntoDefaultInFlight[project] == true
        }
        let key = gitCache.workspaceCacheKey(workspace: workspace, project: project)
        return gitCache.rebaseInFlight[key] == true
    }

    private var abortHelpText: String { "git.conflict.abortHelp".localized }
    private var continueHelpText: String {
        canContinue
            ? "git.conflict.continueHelp".localized
            : "git.conflict.continueBlockedHelp".localized
    }

    // MARK: - 操作

    private func selectFile(_ file: ConflictFileEntry) {
        gitCache.fetchConflictDetail(
            project: project,
            workspace: workspace,
            path: file.path,
            context: context
        )
    }

    private func loadCurrentFileDetail() {
        guard let path = wizard.selectedFilePath else { return }
        gitCache.fetchConflictDetail(project: project, workspace: workspace, path: path, context: context)
    }

    private func acceptOurs() {
        guard let path = wizard.selectedFilePath else { return }
        gitCache.conflictAcceptOurs(project: project, workspace: workspace, path: path, context: context)
    }

    private func acceptTheirs() {
        guard let path = wizard.selectedFilePath else { return }
        gitCache.conflictAcceptTheirs(project: project, workspace: workspace, path: path, context: context)
    }

    private func acceptBoth() {
        guard let path = wizard.selectedFilePath else { return }
        gitCache.conflictAcceptBoth(project: project, workspace: workspace, path: path, context: context)
    }

    private func markResolved() {
        guard let path = wizard.selectedFilePath else { return }
        gitCache.conflictMarkResolved(project: project, workspace: workspace, path: path, context: context)
    }

    private func openInEditor() {
        guard let path = wizard.selectedFilePath else { return }
        appState.openEditorDocument(project: project, workspace: workspace, path: path, force: true)
    }

    private func refreshWizard() {
        if context == "integration" {
            gitCache.fetchGitIntegrationStatus(workspaceKey: workspace)
        } else {
            gitCache.fetchGitStatus(workspaceKey: workspace)
        }
    }

    private func continueOperation() {
        if context == "integration" {
            let integrationState = gitCache.getGitIntegrationStatusCache(workspaceKey: workspace)?.state ?? .idle
            if integrationState == .rebaseConflict {
                gitCache.gitRebaseOntoDefaultContinue(workspaceKey: workspace)
            } else {
                gitCache.gitMergeContinue(workspaceKey: workspace)
            }
        } else {
            let opState = gitCache.getGitOpStatusCache(workspaceKey: workspace)?.state ?? .normal
            if opState == .merging {
                gitCache.gitMergeContinue(workspaceKey: workspace)
            } else {
                gitCache.gitRebaseContinue(workspaceKey: workspace)
            }
        }
    }

    private func abortOperation() {
        if context == "integration" {
            let integrationState = gitCache.getGitIntegrationStatusCache(workspaceKey: workspace)?.state ?? .idle
            if integrationState == .rebaseConflict {
                gitCache.gitRebaseOntoDefaultAbort(workspaceKey: workspace)
            } else {
                gitCache.gitMergeAbort(workspaceKey: workspace)
            }
        } else {
            let opState = gitCache.getGitOpStatusCache(workspaceKey: workspace)?.state ?? .normal
            if opState == .merging {
                gitCache.gitMergeAbort(workspaceKey: workspace)
            } else {
                gitCache.gitRebaseAbort(workspaceKey: workspace)
            }
        }
    }
}

// MARK: - 冲突文件行

private struct ConflictFileRow: View {
    let file: ConflictFileEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.staged ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundColor(file.staged ? .green : .orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !fileDir.isEmpty {
                    Text(fileDir)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            Text(conflictTypeBadge)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
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

// MARK: - 冲突详情视图（四路内容对比）

private struct ConflictDetailView: View {
    let detail: GitConflictDetailResultCache
    let filePath: String
    let onAcceptOurs: () -> Void
    let onAcceptTheirs: () -> Void
    let onAcceptBoth: () -> Void
    let onMarkResolved: () -> Void
    let onOpenEditor: () -> Void

    @State private var selectedTab: ConflictViewTab = .current

    enum ConflictViewTab: String, CaseIterable {
        case current = "current"
        case ours = "ours"
        case theirs = "theirs"
        case base = "base"

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
            // 操作栏
            HStack(spacing: 6) {
                Text(fileName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if detail.conflictMarkersCount > 0 {
                    Text("(\(detail.conflictMarkersCount) conflicts)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                Spacer()
                // 动作按钮组
                actionButton(
                    label: "git.conflict.acceptOurs".localized,
                    icon: "arrow.left.circle",
                    color: .blue,
                    action: onAcceptOurs
                )
                actionButton(
                    label: "git.conflict.acceptTheirs".localized,
                    icon: "arrow.right.circle",
                    color: .purple,
                    action: onAcceptTheirs
                )
                actionButton(
                    label: "git.conflict.acceptBoth".localized,
                    icon: "arrow.left.arrow.right.circle",
                    color: .teal,
                    action: onAcceptBoth
                )
                Divider().frame(height: 16)
                actionButton(
                    label: "git.conflict.markResolved".localized,
                    icon: "checkmark.circle",
                    color: .green,
                    action: onMarkResolved
                )
                actionButton(
                    label: "git.conflict.openEditor".localized,
                    icon: "pencil",
                    color: .secondary,
                    action: onOpenEditor
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.04))
            Divider()
            // 选项卡
            HStack(spacing: 0) {
                ForEach(ConflictViewTab.allCases, id: \.rawValue) { tab in
                    tabButton(tab)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            Divider()
            // 内容区
            contentArea
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        ScrollView([.horizontal, .vertical]) {
            if detail.isBinary {
                Text("git.conflict.binaryFile".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let content = contentForTab(selectedTab)
                Text(content ?? "git.conflict.noContent".localized)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func contentForTab(_ tab: ConflictViewTab) -> String? {
        switch tab {
        case .current: return detail.currentContent.isEmpty ? nil : detail.currentContent
        case .ours: return detail.oursContent
        case .theirs: return detail.theirsContent
        case .base: return detail.baseContent
        }
    }

    private func tabButton(_ tab: ConflictViewTab) -> some View {
        Button(action: { selectedTab = tab }) {
            Text(tab.label)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func actionButton(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(color)
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var fileName: String { URL(fileURLWithPath: filePath).lastPathComponent }
}

#endif // os(macOS)
