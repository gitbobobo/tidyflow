import SwiftUI

/// Native Git Status Panel for Phase C3-1 + C3-2a + C3-2b + C3-3a + C3-4a
/// Displays git status list with filtering, stage/unstage/discard, branch switching, commit, and opens diff tabs on click
struct NativeGitPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var filterText: String = ""
    @State private var showFilter: Bool = false
    @State private var showDiscardAllConfirm: Bool = false
    @State private var showBranchPicker: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Toast notification
            if let toast = appState.gitOpToast {
                GitOpToast(message: toast, isError: appState.gitOpToastIsError)
            }

            // Toolbar
            GitPanelToolbar(
                filterText: $filterText,
                showFilter: $showFilter,
                showDiscardAllConfirm: $showDiscardAllConfirm,
                showBranchPicker: $showBranchPicker,
                onRefresh: { refreshStatus() }
            )
            .environmentObject(appState)

            Divider()

            // Content
            GitPanelContent(filterText: filterText)
                .environmentObject(appState)
        }
        .onAppear {
            loadStatusIfNeeded()
            loadBranchesIfNeeded()
        }
        .onChange(of: appState.selectedWorkspaceKey) { _ in
            loadStatusIfNeeded()
            loadBranchesIfNeeded()
        }
        .alert("Discard All Changes?", isPresented: $showDiscardAllConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Discard", role: .destructive) {
                discardAll()
            }
        } message: {
            Text("This will discard all local changes in tracked files. This cannot be undone.")
        }
    }

    private func loadStatusIfNeeded() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        if appState.shouldFetchGitStatus(workspaceKey: ws) {
            appState.fetchGitStatus(workspaceKey: ws)
        }
    }

    private func loadBranchesIfNeeded() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        if appState.getGitBranchCache(workspaceKey: ws) == nil {
            appState.fetchGitBranches(workspaceKey: ws)
        }
    }

    private func refreshStatus() {
        appState.refreshGitStatus()
    }

    private func discardAll() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitDiscard(workspaceKey: ws, path: nil, scope: "all")
    }
}

// MARK: - Toast Notification

struct GitOpToast: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? .red : .green)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .shadow(radius: 2)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Toolbar

struct GitPanelToolbar: View {
    @EnvironmentObject var appState: AppState
    @Binding var filterText: String
    @Binding var showFilter: Bool
    @Binding var showDiscardAllConfirm: Bool
    @Binding var showBranchPicker: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Main toolbar row
            HStack(spacing: 8) {
                Text("Git")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                // Filter toggle/input
                if showFilter {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))

                        TextField("Filter...", text: $filterText)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 12))
                            .frame(width: 100)

                        Button(action: {
                            filterText = ""
                            showFilter = false
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                } else {
                    Button(action: { showFilter = true }) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Filter files")
                }

                // Refresh button
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Refresh git status")
                .disabled(currentCache?.isLoading == true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Branch selector row (only show if git repo)
            if isGitRepo {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Button(action: { showBranchPicker = true }) {
                        HStack(spacing: 4) {
                            Text(currentBranch)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            if isBranchSwitching {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isBranchSwitching)
                    .popover(isPresented: $showBranchPicker, arrowEdge: .bottom) {
                        BranchPickerView(isPresented: $showBranchPicker)
                            .environmentObject(appState)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            // Stage All / Unstage All buttons (only show if git repo with changes)
            if isGitRepoWithChanges {
                HStack(spacing: 8) {
                    Button(action: stageAll) {
                        HStack(spacing: 4) {
                            if isStageAllInFlight {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 11))
                            }
                            Text("Stage All")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isStageAllInFlight || !hasUnstagedChanges)
                    .help("Stage all changes")

                    Button(action: unstageAll) {
                        HStack(spacing: 4) {
                            if isUnstageAllInFlight {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 11))
                            }
                            Text("Unstage All")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isUnstageAllInFlight)
                    .help("Unstage all changes")

                    // Discard All button (red, destructive)
                    Button(action: { showDiscardAllConfirm = true }) {
                        HStack(spacing: 4) {
                            if isDiscardAllInFlight {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                            }
                            Text("Discard All")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isDiscardAllInFlight || !hasTrackedChanges)
                    .help("Discard all tracked changes (cannot be undone)")

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            // Commit section (only show if git repo)
            if isGitRepo {
                GitCommitSection()
                    .environmentObject(appState)
            }

            // Workspace Actions section (only show if git repo) - UX-3a
            if isGitRepo {
                GitWorkspaceActionsSection()
                    .environmentObject(appState)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var currentCache: GitStatusCache? {
        guard let ws = appState.selectedWorkspaceKey else { return nil }
        return appState.getGitStatusCache(workspaceKey: ws)
    }

    private var currentBranchCache: GitBranchCache? {
        guard let ws = appState.selectedWorkspaceKey else { return nil }
        return appState.getGitBranchCache(workspaceKey: ws)
    }

    private var isGitRepo: Bool {
        guard let cache = currentCache else { return false }
        return cache.isGitRepo
    }

    private var currentBranch: String {
        currentBranchCache?.current ?? "..."
    }

    private var isBranchSwitching: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isBranchSwitchInFlight(workspaceKey: ws)
    }

    private var isGitRepoWithChanges: Bool {
        guard let cache = currentCache else { return false }
        return cache.isGitRepo && !cache.items.isEmpty
    }

    private var hasUnstagedChanges: Bool {
        guard let cache = currentCache else { return false }
        // Check if there are any untracked or modified files
        return cache.items.contains { $0.status == "??" || $0.status == "M" || $0.status == "A" || $0.status == "D" }
    }

    private var isStageAllInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isGitOpInFlight(workspaceKey: ws, path: nil, op: "stage")
    }

    private var isUnstageAllInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isGitOpInFlight(workspaceKey: ws, path: nil, op: "unstage")
    }

    private var isDiscardAllInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isGitOpInFlight(workspaceKey: ws, path: nil, op: "discard")
    }

    private var hasTrackedChanges: Bool {
        guard let cache = currentCache else { return false }
        // Check if there are any tracked modified files (not untracked)
        return cache.items.contains { $0.status != "??" }
    }

    private func stageAll() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitStage(workspaceKey: ws, path: nil, scope: "all")
    }

    private func unstageAll() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitUnstage(workspaceKey: ws, path: nil, scope: "all")
    }
}

// MARK: - Content

struct GitPanelContent: View {
    @EnvironmentObject var appState: AppState
    let filterText: String

    var body: some View {
        Group {
            if appState.connectionState == .disconnected {
                EmptyStateView(
                    icon: "wifi.slash",
                    title: "Disconnected",
                    subtitle: "Connect to Core to view git status"
                )
            } else if let ws = appState.selectedWorkspaceKey,
                      let cache = appState.getGitStatusCache(workspaceKey: ws) {
                if cache.isLoading && cache.items.isEmpty {
                    LoadingView()
                } else if !cache.isGitRepo {
                    EmptyStateView(
                        icon: "folder.badge.questionmark",
                        title: "Not a Git Repository",
                        subtitle: "This workspace is not initialized as a git repository"
                    )
                } else if let error = cache.error {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Error",
                        subtitle: error
                    )
                } else if filteredItems(cache.items).isEmpty {
                    if filterText.isEmpty {
                        EmptyStateView(
                            icon: "checkmark.circle",
                            title: "No Changes",
                            subtitle: "Working tree is clean"
                        )
                    } else {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "No Matches",
                            subtitle: "No files match '\(filterText)'"
                        )
                    }
                } else {
                    GitStatusList(
                        items: filteredItems(cache.items),
                        isLoading: cache.isLoading,
                        updatedAt: cache.updatedAt
                    )
                    .environmentObject(appState)
                }
            } else {
                LoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func filteredItems(_ items: [GitStatusItem]) -> [GitStatusItem] {
        guard !filterText.isEmpty else { return items }
        let lowercased = filterText.lowercased()
        return items.filter { $0.path.lowercased().contains(lowercased) }
    }
}

// MARK: - Status List

struct GitStatusList: View {
    @EnvironmentObject var appState: AppState
    let items: [GitStatusItem]
    let isLoading: Bool
    let updatedAt: Date

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        GitStatusRow(item: item)
                            .environmentObject(appState)
                    }
                }
            }

            // Footer with update time
            HStack {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                    Text("Updating...")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Text("Updated \(timeAgo(updatedAt))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(items.count) file\(items.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "just now"
        } else if seconds < 3600 {
            let minutes = seconds / 60
            return "\(minutes)m ago"
        } else {
            let hours = seconds / 3600
            return "\(hours)h ago"
        }
    }
}

// MARK: - Status Row

struct GitStatusRow: View {
    @EnvironmentObject var appState: AppState
    let item: GitStatusItem
    @State private var isHovered: Bool = false
    @State private var showDiscardConfirm: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Main clickable area (opens diff)
            Button(action: { openDiffTab() }) {
                HStack(spacing: 8) {
                    // Status badge
                    Text(item.status)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(statusColor)
                        .frame(width: 24, alignment: .center)

                    // File path
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if let dir = directoryPath, !dir.isEmpty {
                            Text(dir)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        // Show rename info if available
                        if let renameFrom = item.renameFrom {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8))
                                Text(renameFrom)
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        }
                    }

                    Spacer()
                }
            }
            .buttonStyle(PlainButtonStyle())

            // Action buttons (visible on hover or when in-flight)
            if isHovered || isStageInFlight || isDiscardInFlight {
                // Stage button
                Button(action: stageFile) {
                    if isStageInFlight {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.green)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isStageInFlight)
                .help("Stage this file")

                // Discard button (only for tracked files or untracked)
                Button(action: { showDiscardConfirm = true }) {
                    if isDiscardInFlight {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: isUntracked ? "trash" : "arrow.uturn.backward")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isDiscardInFlight || isStaged)
                .help(discardButtonHelp)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.3) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(item.statusDescription)
        .alert(discardAlertTitle, isPresented: $showDiscardConfirm) {
            Button("Cancel", role: .cancel) { }
            Button(isUntracked ? "Delete" : "Discard", role: .destructive) {
                discardFile()
            }
        } message: {
            Text(discardAlertMessage)
        }
    }

    private var fileName: String {
        item.path.split(separator: "/").last.map(String.init) ?? item.path
    }

    private var directoryPath: String? {
        let components = item.path.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    private var statusColor: Color {
        switch item.status {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        case "??": return .gray
        case "R": return .blue
        case "C": return .cyan
        case "U": return .purple
        default: return .secondary
        }
    }

    private var isStageInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isGitOpInFlight(workspaceKey: ws, path: item.path, op: "stage")
    }

    private var isDiscardInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isGitOpInFlight(workspaceKey: ws, path: item.path, op: "discard")
    }

    private var isUntracked: Bool {
        item.status == "??"
    }

    private var isStaged: Bool {
        // Files that are only staged (no working tree changes) - discard not applicable
        // This is a simplified check; in practice, we'd need the full XY status
        item.status == "A" && item.staged == true
    }

    private var discardButtonHelp: String {
        if isStaged {
            return "Cannot discard staged-only changes (use Unstage first)"
        } else if isUntracked {
            return "Delete this untracked file (cannot be undone)"
        } else {
            return "Discard changes in this file (cannot be undone)"
        }
    }

    private var discardAlertTitle: String {
        isUntracked ? "Delete File?" : "Discard Changes?"
    }

    private var discardAlertMessage: String {
        if isUntracked {
            return "This will permanently delete '\(fileName)'. This cannot be undone."
        } else {
            return "This will discard all local changes in '\(fileName)'. This cannot be undone."
        }
    }

    private func openDiffTab() {
        guard let ws = appState.selectedWorkspaceKey else { return }

        // For deleted files, still open diff tab (diff view handles deleted state)
        appState.addDiffTab(workspaceKey: ws, path: item.path, mode: .working)
    }

    private func stageFile() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitStage(workspaceKey: ws, path: item.path, scope: "file")
    }

    private func discardFile() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitDiscard(workspaceKey: ws, path: item.path, scope: "file")
    }
}

// MARK: - Empty State View

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Loading View

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Loading...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Commit Section (Phase C3-4a)

struct GitCommitSection: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Divider()

            // Commit message input
            HStack(spacing: 8) {
                TextField("Commit message", text: commitMessageBinding)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(4)
                    .focused($isMessageFocused)
                    .onSubmit {
                        if canCommit {
                            performCommit()
                        }
                    }
                    .disabled(isCommitInFlight)

                // Commit button
                Button(action: performCommit) {
                    HStack(spacing: 4) {
                        if isCommitInFlight {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                        }
                        Text("Commit")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(canCommit ? Color.accentColor : Color.gray.opacity(0.3))
                    .foregroundColor(canCommit ? .white : .secondary)
                    .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canCommit || isCommitInFlight)
                .help(commitButtonHelp)
            }
            .padding(.horizontal, 12)

            // Status hint
            if !hasStagedChanges {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text("No staged changes")
                        .font(.system(size: 10))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            } else if stagedCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text("\(stagedCount) file\(stagedCount == 1 ? "" : "s") staged")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private var commitMessageBinding: Binding<String> {
        Binding(
            get: {
                guard let ws = appState.selectedWorkspaceKey else { return "" }
                return appState.commitMessage[ws] ?? ""
            },
            set: { newValue in
                guard let ws = appState.selectedWorkspaceKey else { return }
                appState.commitMessage[ws] = newValue
            }
        )
    }

    private var currentMessage: String {
        guard let ws = appState.selectedWorkspaceKey else { return "" }
        return appState.commitMessage[ws] ?? ""
    }

    private var hasStagedChanges: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.hasStagedChanges(workspaceKey: ws)
    }

    private var stagedCount: Int {
        guard let ws = appState.selectedWorkspaceKey else { return 0 }
        return appState.stagedCount(workspaceKey: ws)
    }

    private var isCommitInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isCommitInFlight(workspaceKey: ws)
    }

    private var canCommit: Bool {
        let trimmedMessage = currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasStagedChanges && !trimmedMessage.isEmpty && !isCommitInFlight
    }

    private var commitButtonHelp: String {
        if !hasStagedChanges {
            return "Stage changes before committing"
        } else if currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a commit message"
        } else if isCommitInFlight {
            return "Committing..."
        } else {
            return "Commit staged changes"
        }
    }

    private func performCommit() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitCommit(workspaceKey: ws, message: currentMessage)
    }
}

// MARK: - Workspace Actions Section (UX-3a + UX-3b)

struct GitWorkspaceActionsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            Divider()

            // Rebase status indicator (UX-3a)
            if let opStatus = currentOpStatus {
                if opStatus.state != .normal {
                    HStack(spacing: 6) {
                        Image(systemName: opStatus.state == .rebasing ? "arrow.triangle.2.circlepath" : "arrow.triangle.merge")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Text(opStatus.state.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                        if !opStatus.conflicts.isEmpty {
                            Text("(\(opStatus.conflicts.count) conflicts)")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                }
            }

            // Integration merge status indicator (UX-3b)
            if let integrationStatus = currentIntegrationStatus {
                if integrationStatus.state != .idle {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 11))
                            .foregroundColor(.purple)
                        Text("Merging to Default")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.purple)
                        if !integrationStatus.conflicts.isEmpty {
                            Text("(\(integrationStatus.conflicts.count) conflicts)")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.1))
                }
            }

            // UX-6: Branch divergence indicator (behind)
            if let integrationStatus = currentIntegrationStatus,
               let behindBy = integrationStatus.branchBehindBy,
               behindBy > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Text("Branch is \(behindBy) commit\(behindBy == 1 ? "" : "s") behind \(integrationStatus.comparedBranch ?? "default")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                        Spacer()
                    }

                    // CTA buttons
                    HStack(spacing: 8) {
                        Button(action: performRebaseOntoDefault) {
                            Text("Rebase onto Default")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRebaseOntoDefaultInFlight || isMergeInFlight)

                        Button(action: performMergeToDefault) {
                            Text("Merge Default into Branch")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRebaseOntoDefaultInFlight || isMergeInFlight)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }

            // UX-6: Branch divergence indicator (ahead)
            if let integrationStatus = currentIntegrationStatus,
               let aheadBy = integrationStatus.branchAheadBy,
               aheadBy > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Text("Branch is \(aheadBy) commit\(aheadBy == 1 ? "" : "s") ahead of \(integrationStatus.comparedBranch ?? "default")")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.05))
            }

            // Conflict files list (if any - rebase)
            if let conflicts = currentOpStatus?.conflicts, !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rebase Conflicts:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    ForEach(conflicts, id: \.self) { path in
                        Button(action: { openConflictFile(path) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                                Text(path.split(separator: "/").last.map(String.init) ?? path)
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Conflict files list (if any - merge)
            if let conflicts = currentIntegrationStatus?.conflicts, !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Merge Conflicts:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    ForEach(conflicts, id: \.self) { path in
                        Button(action: { openConflictFile(path) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                                Text(path.split(separator: "/").last.map(String.init) ?? path)
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Action buttons
            HStack(spacing: 8) {
                // Fetch button
                Button(action: performFetch) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11))
                        Text("Fetch")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15))
                    .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isRebaseInFlight || isMergeInFlight)
                .help("Fetch from remote")

                // UX-6: Check Up To Date button
                Button(action: performCheckUpToDate) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                        Text("Check")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.teal.opacity(0.15))
                    .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isRebaseInFlight || isMergeInFlight)
                .help("Check if branch is up to date with default")

                // Rebase button (only show if not in rebase or merge)
                if !isInRebase && !isInMerge {
                    Button(action: performRebase) {
                        HStack(spacing: 4) {
                            if isRebaseInFlight {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11))
                            }
                            Text("Rebase")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isRebaseInFlight || isMergeInFlight)
                    .help("Rebase onto default branch (main)")
                }

                // Merge to Default button (UX-3b) - only show if not in rebase or merge
                if !isInRebase && !isInMerge {
                    Button(action: performMergeToDefault) {
                        HStack(spacing: 4) {
                            if isMergeInFlight {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.system(size: 11))
                            }
                            Text("Merge to Default")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isRebaseInFlight || isMergeInFlight)
                    .help("Merge workspace branch into default branch (main)")
                }

                Spacer()
            }
            .padding(.horizontal, 12)

            // Continue/Abort buttons for rebase (only show if in rebase)
            if isInRebase {
                HStack(spacing: 8) {
                    Button(action: performContinue) {
                        HStack(spacing: 4) {
                            if isRebaseInFlight {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                            }
                            Text("Continue")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isRebaseInFlight)
                    .help("Continue rebase after resolving conflicts")

                    Button(action: performAbort) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11))
                            Text("Abort")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isRebaseInFlight)
                    .help("Abort rebase and return to original state")

                    Button(action: runAIResolve) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text("AI Resolve")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.cyan.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Open terminal with opencode to resolve conflicts")

                    Spacer()
                }
                .padding(.horizontal, 12)
            }

            // Continue/Abort buttons for merge (UX-3b) - only show if in merge
            if isInMerge {
                HStack(spacing: 8) {
                    Button(action: performMergeContinue) {
                        HStack(spacing: 4) {
                            if isMergeInFlight {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                            }
                            Text("Continue Merge")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isMergeInFlight)
                    .help("Continue merge after resolving conflicts")

                    Button(action: performMergeAbort) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11))
                            Text("Abort Merge")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isMergeInFlight)
                    .help("Abort merge and return to original state")

                    Button(action: runAIResolve) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text("AI Resolve")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.cyan.opacity(0.15))
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Open terminal with opencode to resolve conflicts")

                    Spacer()
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            loadOpStatusIfNeeded()
            loadIntegrationStatusIfNeeded()
        }
        .onChange(of: appState.selectedWorkspaceKey) { _ in
            loadOpStatusIfNeeded()
            loadIntegrationStatusIfNeeded()
        }
    }

    private var currentOpStatus: GitOpStatusCache? {
        guard let ws = appState.selectedWorkspaceKey else { return nil }
        return appState.getGitOpStatusCache(workspaceKey: ws)
    }

    private var currentIntegrationStatus: GitIntegrationStatusCache? {
        guard let ws = appState.selectedWorkspaceKey else { return nil }
        return appState.getGitIntegrationStatusCache(workspaceKey: ws)
    }

    private var isInRebase: Bool {
        currentOpStatus?.state == .rebasing
    }

    private var isInMerge: Bool {
        currentIntegrationStatus?.state == .merging
    }

    private var isRebaseInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isRebaseInFlight(workspaceKey: ws)
    }

    private var isMergeInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isMergeInFlight(workspaceKey: ws)
    }

    // UX-6: Check if rebase onto default is in-flight
    private var isRebaseOntoDefaultInFlight: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.isRebaseOntoDefaultInFlight(workspaceKey: ws)
    }

    private func loadOpStatusIfNeeded() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.fetchGitOpStatus(workspaceKey: ws)
    }

    private func loadIntegrationStatusIfNeeded() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.fetchGitIntegrationStatus(workspaceKey: ws)
    }

    private func performFetch() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitFetch(workspaceKey: ws)
    }

    // UX-6: Check if branch is up to date with default
    private func performCheckUpToDate() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitCheckBranchUpToDate(workspaceKey: ws)
    }

    private func performRebase() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        // Default to rebasing onto "main" - could be made configurable
        appState.gitRebase(workspaceKey: ws, ontoBranch: "origin/main")
    }

    private func performContinue() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitRebaseContinue(workspaceKey: ws)
    }

    private func performAbort() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitRebaseAbort(workspaceKey: ws)
    }

    private func performMergeToDefault() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitMergeToDefault(workspaceKey: ws)
    }

    // UX-6: Perform rebase onto default (via integration worktree)
    private func performRebaseOntoDefault() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitRebaseOntoDefault(workspaceKey: ws)
    }

    private func performMergeContinue() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitMergeContinue(workspaceKey: ws)
    }

    private func performMergeAbort() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        appState.gitMergeAbort(workspaceKey: ws)
    }

    private func openConflictFile(_ path: String) {
        guard let ws = appState.selectedWorkspaceKey else { return }
        // Open the file in editor
        appState.addEditorTab(workspaceKey: ws, path: path)
    }

    private func runAIResolve() {
        // Spawn a terminal tab with opencode
        // This will be handled by the terminal system
        guard let ws = appState.selectedWorkspaceKey else { return }

        // Create a new terminal tab for this workspace and run opencode
        // The terminal will be created in the workspace's cwd
        appState.spawnTerminalWithCommand(workspaceKey: ws, command: "opencode")
    }
}

// MARK: - Preview

#if DEBUG
struct NativeGitPanelView_Previews: PreviewProvider {
    static var previews: some View {
        NativeGitPanelView()
            .environmentObject(AppState())
            .frame(width: 280, height: 400)
    }
}
#endif
