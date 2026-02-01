import SwiftUI

/// Branch picker popover for Phase C3-3a/C3-3b
/// Displays list of local branches with search filter, switch, and create functionality
struct BranchPickerView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var searchText: String = ""
    @State private var showCreateForm: Bool = false
    @State private var newBranchName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))

                TextField("Search branches...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Branch list
            if let ws = appState.selectedWorkspaceKey,
               let cache = appState.getGitBranchCache(workspaceKey: ws) {
                if cache.isLoading && cache.branches.isEmpty {
                    LoadingStateView()
                } else if let error = cache.error {
                    ErrorStateView(message: error)
                } else if filteredBranches(cache.branches).isEmpty && !showCreateForm {
                    EmptySearchView(searchText: searchText)
                } else {
                    BranchListView(
                        branches: filteredBranches(cache.branches),
                        currentBranch: cache.current,
                        isLoading: cache.isLoading,
                        showCreateForm: $showCreateForm,
                        newBranchName: $newBranchName,
                        onSelect: { branch in
                            switchToBranch(branch)
                        },
                        onCreateBranch: {
                            createBranch()
                        }
                    )
                    .environmentObject(appState)
                }
            } else {
                LoadingStateView()
            }
        }
        .frame(width: 280, height: 320)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            loadBranchesIfNeeded()
        }
        .onChange(of: appState.branchCreateInFlight) { inFlight in
            // Close picker when create succeeds (inFlight becomes empty)
            if let ws = appState.selectedWorkspaceKey,
               inFlight[ws] == nil && showCreateForm && !newBranchName.isEmpty {
                // Check if the branch was actually created (exists in cache)
                if let cache = appState.getGitBranchCache(workspaceKey: ws),
                   cache.branches.contains(where: { $0.name == newBranchName.trimmingCharacters(in: .whitespaces) }) {
                    isPresented = false
                }
            }
        }
    }

    private func loadBranchesIfNeeded() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        if appState.getGitBranchCache(workspaceKey: ws) == nil {
            appState.fetchGitBranches(workspaceKey: ws)
        }
    }

    private func filteredBranches(_ branches: [GitBranchItem]) -> [GitBranchItem] {
        guard !searchText.isEmpty else { return branches }
        let lowercased = searchText.lowercased()
        return branches.filter { $0.name.lowercased().contains(lowercased) }
    }

    private func switchToBranch(_ branch: String) {
        guard let ws = appState.selectedWorkspaceKey else { return }
        guard let cache = appState.getGitBranchCache(workspaceKey: ws),
              branch != cache.current else {
            // Already on this branch
            isPresented = false
            return
        }
        appState.gitSwitchBranch(workspaceKey: ws, branch: branch)
        isPresented = false
    }

    private func createBranch() {
        guard let ws = appState.selectedWorkspaceKey else { return }
        let trimmed = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appState.gitCreateBranch(workspaceKey: ws, branch: trimmed)
    }
}

// MARK: - Branch Name Validation

/// Validates branch name according to git-check-ref-format rules
func validateBranchName(_ name: String) -> (valid: Bool, error: String?) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)

    if trimmed.isEmpty {
        return (false, "Branch name required")
    }
    if trimmed.hasPrefix("-") {
        return (false, "Cannot start with '-'")
    }
    if trimmed.hasSuffix(".") {
        return (false, "Cannot end with '.'")
    }
    if trimmed.contains("..") {
        return (false, "Cannot contain '..'")
    }
    if trimmed.contains(" ") {
        return (false, "Cannot contain spaces")
    }

    // Check for forbidden characters: ~ ^ : ? * [ \
    let forbidden = CharacterSet(charactersIn: "~^:?*[\\")
    if trimmed.unicodeScalars.contains(where: { forbidden.contains($0) }) {
        return (false, "Invalid characters")
    }

    return (true, nil)
}

// MARK: - Branch List View

struct BranchListView: View {
    @EnvironmentObject var appState: AppState
    let branches: [GitBranchItem]
    let currentBranch: String
    let isLoading: Bool
    @Binding var showCreateForm: Bool
    @Binding var newBranchName: String
    let onSelect: (String) -> Void
    let onCreateBranch: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Create new branch row
                CreateBranchRowView(
                    showCreateForm: $showCreateForm,
                    newBranchName: $newBranchName,
                    onCreateBranch: onCreateBranch
                )
                .environmentObject(appState)

                Divider()
                    .padding(.vertical, 4)

                // Branch list
                ForEach(branches) { branch in
                    BranchRowView(
                        branch: branch,
                        isCurrent: branch.name == currentBranch,
                        isSwitching: isSwitchingTo(branch.name),
                        onSelect: { onSelect(branch.name) }
                    )
                }
            }
        }
    }

    private func isSwitchingTo(_ branch: String) -> Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.branchSwitchInFlight[ws] == branch
    }
}

// MARK: - Create Branch Row View

struct CreateBranchRowView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showCreateForm: Bool
    @Binding var newBranchName: String
    let onCreateBranch: () -> Void

    @State private var isHovered: Bool = false

    private var validation: (valid: Bool, error: String?) {
        validateBranchName(newBranchName)
    }

    private var isCreating: Bool {
        guard let ws = appState.selectedWorkspaceKey else { return false }
        return appState.branchCreateInFlight[ws] != nil
    }

    private var branchExists: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getGitBranchCache(workspaceKey: ws) else { return false }
        let trimmed = newBranchName.trimmingCharacters(in: .whitespaces)
        return cache.branches.contains { $0.name == trimmed }
    }

    private var canCreate: Bool {
        validation.valid && !branchExists && !isCreating
    }

    private var errorMessage: String? {
        if let error = validation.error {
            return error
        }
        if branchExists {
            return "Branch already exists"
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if showCreateForm {
                // Create form
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                            .frame(width: 16)

                        TextField("New branch name", text: $newBranchName)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 12))
                            .disabled(isCreating)
                            .onSubmit {
                                if canCreate {
                                    onCreateBranch()
                                }
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    // Error message
                    if let error = errorMessage, !newBranchName.isEmpty {
                        HStack {
                            Spacer()
                                .frame(width: 28)
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                    }

                    // Buttons
                    HStack(spacing: 8) {
                        Spacer()

                        Button("Cancel") {
                            showCreateForm = false
                            newBranchName = ""
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .disabled(isCreating)

                        Button(action: onCreateBranch) {
                            HStack(spacing: 4) {
                                if isCreating {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .frame(width: 12, height: 12)
                                }
                                Text("Create")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canCreate)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            } else {
                // Collapsed row
                Button(action: { showCreateForm = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                            .frame(width: 16)

                        Text("Create new branch...")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.3) : Color.clear)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    isHovered = hovering
                }
            }
        }
    }
}

// MARK: - Branch Row View

struct BranchRowView: View {
    let branch: GitBranchItem
    let isCurrent: Bool
    let isSwitching: Bool
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Current branch indicator
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                        .frame(width: 16)
                } else {
                    Spacer()
                        .frame(width: 16)
                }

                // Branch icon
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                // Branch name
                Text(branch.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                // Switching indicator
                if isSwitching {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.3) : Color.clear)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isCurrent || isSwitching)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - State Views

struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.0)
            Text("Loading branches...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptySearchView: View {
    let searchText: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text("No branches match '\(searchText)'")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#if DEBUG
struct BranchPickerView_Previews: PreviewProvider {
    static var previews: some View {
        BranchPickerView(isPresented: .constant(true))
            .environmentObject(AppState())
    }
}
#endif
