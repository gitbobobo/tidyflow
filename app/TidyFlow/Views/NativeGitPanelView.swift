import SwiftUI

/// Native Git Status Panel for Phase C3-1 + C3-2a + C3-2b
/// Displays git status list with filtering, stage/unstage/discard, and opens diff tabs on click
struct NativeGitPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var filterText: String = ""
    @State private var showFilter: Bool = false
    @State private var showDiscardAllConfirm: Bool = false

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
        }
        .onChange(of: appState.selectedWorkspaceKey) { _ in
            loadStatusIfNeeded()
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
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var currentCache: GitStatusCache? {
        guard let ws = appState.selectedWorkspaceKey else { return nil }
        return appState.getGitStatusCache(workspaceKey: ws)
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
