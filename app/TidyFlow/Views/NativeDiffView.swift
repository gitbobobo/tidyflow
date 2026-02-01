import SwiftUI

// MARK: - Phase C2-2a/C2-2b: Native Unified & Split Diff View

struct NativeDiffView: View {
    let path: String
    @Binding var currentMode: DiffMode
    @Binding var currentViewMode: DiffViewMode
    let onModeChange: (DiffMode) -> Void
    let onViewModeChange: (DiffViewMode) -> Void
    let onLineClick: (Int) -> Void  // Navigate to line in editor

    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with mode toggle and refresh
            NativeDiffToolbar(
                currentMode: $currentMode,
                currentViewMode: $currentViewMode,
                splitDisabled: isSplitDisabled,
                splitDisabledReason: splitDisabledReason,
                onModeChange: onModeChange,
                onViewModeChange: onViewModeChange,
                onRefresh: { appState.refreshActiveDiff() }
            )

            // Main diff content
            diffContent

            // Status bar
            NativeDiffStatusBar(path: path, mode: currentMode, viewMode: currentViewMode)
        }
        .onAppear {
            loadDiffIfNeeded()
        }
        .onChange(of: currentMode) { _ in
            loadDiffIfNeeded()
        }
        .onChange(of: path) { _ in
            loadDiffIfNeeded()
        }
    }

    /// Check if split view should be disabled
    private var isSplitDisabled: Bool {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getDiffCache(workspaceKey: ws, path: path, mode: currentMode) else {
            return false
        }
        return cache.isBinary || SplitBuilder.isTooLargeForSplit(cache.parsedLines)
    }

    /// Reason why split is disabled
    private var splitDisabledReason: String? {
        guard let ws = appState.selectedWorkspaceKey,
              let cache = appState.getDiffCache(workspaceKey: ws, path: path, mode: currentMode) else {
            return nil
        }
        if cache.isBinary {
            return "Binary file"
        }
        if SplitBuilder.isTooLargeForSplit(cache.parsedLines) {
            return "Diff too large (>\(SplitBuilder.maxLinesForSplit) lines)"
        }
        return nil
    }

    @ViewBuilder
    private var diffContent: some View {
        if let ws = appState.selectedWorkspaceKey,
           let cache = appState.getDiffCache(workspaceKey: ws, path: path, mode: currentMode) {

            if cache.isLoading {
                loadingView
            } else if let error = cache.error {
                errorView(error)
            } else if cache.isBinary {
                binaryFileView
            } else if cache.truncated {
                truncatedView(cache)
            } else if cache.parsedLines.isEmpty || cache.text.isEmpty {
                emptyDiffView
            } else {
                diffLinesView(cache)
            }
        } else {
            loadingView
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading diff...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text("Error loading diff")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Retry") {
                appState.refreshActiveDiff()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private var binaryFileView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("Binary file")
                .font(.headline)
            Text("Cannot display diff for binary files")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func truncatedView(_ cache: DiffCache) -> some View {
        VStack(spacing: 0) {
            // Warning banner
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Diff truncated (file too large)")
                    .font(.caption)
                Spacer()
            }
            .padding(8)
            .background(Color.orange.opacity(0.1))

            // Show available content
            diffLinesView(cache)
        }
    }

    private var emptyDiffView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundColor(.green)
            Text("No changes")
                .font(.headline)
            Text(currentMode == .working ? "No unstaged changes" : "No staged changes")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func diffLinesView(_ cache: DiffCache) -> some View {
        let isDeleted = cache.code.hasPrefix("D")
        let effectiveViewMode = isSplitDisabled ? .unified : currentViewMode

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Native Diff indicator
                HStack {
                    Text("Native Diff")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.8))
                        .cornerRadius(3)

                    if effectiveViewMode == .split {
                        Text("Split View")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.8))
                            .cornerRadius(3)
                    }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                if effectiveViewMode == .split {
                    // Split view
                    let splitRows = SplitBuilder.build(from: cache.parsedLines)
                    ForEach(splitRows) { row in
                        SplitRowView(
                            row: row,
                            isFileDeleted: isDeleted,
                            onTap: { targetLine in
                                if !isDeleted {
                                    onLineClick(targetLine)
                                }
                            }
                        )
                    }
                } else {
                    // Unified view
                    ForEach(cache.parsedLines) { line in
                        DiffLineRow(
                            line: line,
                            isFileDeleted: isDeleted,
                            onTap: { targetLine in
                                if !isDeleted {
                                    onLineClick(targetLine)
                                }
                            }
                        )
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func loadDiffIfNeeded() {
        guard let ws = appState.selectedWorkspaceKey else { return }

        // Check if we need to fetch
        if let cache = appState.getDiffCache(workspaceKey: ws, path: path, mode: currentMode) {
            if !cache.isLoading && cache.error == nil && !cache.isExpired {
                return  // Use cached data
            }
        }

        appState.fetchGitDiff(workspaceKey: ws, path: path, mode: currentMode)
    }
}

// MARK: - Diff Line Row

struct DiffLineRow: View {
    let line: DiffLine
    let isFileDeleted: Bool
    let onTap: (Int) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Line numbers column
            lineNumbersColumn

            // Separator
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1)

            // Text content
            textColumn
        }
        .background(backgroundColor)
        .onHover { hovering in
            isHovered = hovering && line.isNavigable && !isFileDeleted
        }
        .onTapGesture {
            if let target = line.targetLine, !isFileDeleted {
                onTap(target)
            }
        }
        .help(helpText)
    }

    private var lineNumbersColumn: some View {
        HStack(spacing: 0) {
            // Old line number
            Text(line.oldLineNumber.map { String($0) } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 4)

            // New line number
            Text(line.newLineNumber.map { String($0) } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 4)
        }
        .frame(width: 88)
        .background(lineNumberBackground)
    }

    private var textColumn: some View {
        HStack(spacing: 0) {
            // Line prefix indicator
            Text(linePrefix)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(prefixColor)
                .frame(width: 16)

            // Line text
            Text(line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
    }

    private var linePrefix: String {
        switch line.kind {
        case .add: return "+"
        case .del: return "-"
        case .context: return " "
        case .header, .hunk: return ""
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .add: return .green
        case .del: return .red
        default: return .secondary
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .header: return .secondary
        case .hunk: return .blue
        default: return .primary
        }
    }

    private var backgroundColor: Color {
        if isHovered {
            return Color.accentColor.opacity(0.15)
        }
        switch line.kind {
        case .add: return Color.green.opacity(0.1)
        case .del: return Color.red.opacity(0.1)
        case .hunk: return Color.blue.opacity(0.05)
        default: return .clear
        }
    }

    private var lineNumberBackground: Color {
        switch line.kind {
        case .add: return Color.green.opacity(0.05)
        case .del: return Color.red.opacity(0.05)
        default: return Color(NSColor.controlBackgroundColor).opacity(0.5)
        }
    }

    private var helpText: String {
        if isFileDeleted {
            return "File deleted - cannot open in editor"
        }
        if line.isNavigable, let target = line.targetLine {
            return "Click to go to line \(target)"
        }
        return ""
    }
}

// MARK: - Native Diff Toolbar

struct NativeDiffToolbar: View {
    @Binding var currentMode: DiffMode
    @Binding var currentViewMode: DiffViewMode
    let splitDisabled: Bool
    let splitDisabledReason: String?
    let onModeChange: (DiffMode) -> Void
    let onViewModeChange: (DiffViewMode) -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // View mode toggle (Unified / Split)
            Picker("", selection: Binding(
                get: { currentViewMode },
                set: { onViewModeChange($0) }
            )) {
                Text("Unified").tag(DiffViewMode.unified)
                Text("Split").tag(DiffViewMode.split)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .disabled(splitDisabled)
            .help(splitDisabledReason ?? "Toggle between unified and split diff view")

            Divider()
                .frame(height: 16)

            // Mode toggle (Working / Staged)
            Picker("", selection: Binding(
                get: { currentMode },
                set: { onModeChange($0) }
            )) {
                Text("Working").tag(DiffMode.working)
                Text("Staged").tag(DiffMode.staged)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .help("Working: unstaged changes (git diff)\nStaged: staged changes (git diff --cached)")

            // Refresh button
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Refresh diff")

            Spacer()

            // Info text
            Text("Click a line to open in editor")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Native Diff Status Bar

struct NativeDiffStatusBar: View {
    let path: String
    let mode: DiffMode
    let viewMode: DiffViewMode

    var body: some View {
        HStack {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11))
                .foregroundColor(.orange)

            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(viewMode == .split ? "Split" : "Unified")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            Text(mode == .working ? "Working Changes" : "Staged Changes")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Phase C2-2b: Split Row View

struct SplitRowView: View {
    let row: SplitRow
    let isFileDeleted: Bool
    let onTap: (Int) -> Void

    var body: some View {
        switch row.rowKind {
        case .header:
            // Full-width header
            HStack(spacing: 0) {
                Text(row.fullText ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))

        case .hunk:
            // Full-width hunk header
            HStack(spacing: 0) {
                Text(row.fullText ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.05))

        case .code:
            // Side-by-side code columns
            HStack(spacing: 0) {
                // Left column (old)
                SplitCellView(
                    cell: row.left,
                    isLeft: true,
                    isFileDeleted: isFileDeleted,
                    onTap: onTap
                )

                // Vertical divider
                Rectangle()
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 1)

                // Right column (new)
                SplitCellView(
                    cell: row.right,
                    isLeft: false,
                    isFileDeleted: isFileDeleted,
                    onTap: onTap
                )
            }
        }
    }
}

// MARK: - Split Cell View

struct SplitCellView: View {
    let cell: SplitCell?
    let isLeft: Bool
    let isFileDeleted: Bool
    let onTap: (Int) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Line number
            Text(cell?.lineNumber.map { String($0) } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 4)
                .background(lineNumberBackground)

            // Separator
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1)

            // Prefix indicator
            Text(linePrefix)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(prefixColor)
                .frame(width: 16)

            // Text content
            Text(cell?.text ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering && isNavigable && !isFileDeleted
        }
        .onTapGesture {
            if let targetLine = targetLine, !isFileDeleted {
                onTap(targetLine)
            }
        }
        .help(helpText)
    }

    private var isNavigable: Bool {
        guard let cell = cell else { return false }
        return cell.isNavigable
    }

    private var targetLine: Int? {
        guard let cell = cell else { return nil }
        // For right column: use lineNumber directly
        // For left column with del: use the stored newLineNumber (nearest context)
        if !isLeft {
            return cell.lineNumber
        } else if cell.kind == .del {
            // For deleted lines, we stored newLineNumber in right cell
            return cell.lineNumber  // This is oldLineNumber, but we navigate to nearest
        }
        return cell.lineNumber
    }

    private var linePrefix: String {
        guard let cell = cell else { return " " }
        switch cell.kind {
        case .add: return "+"
        case .del: return "-"
        case .context: return " "
        case .header, .hunk: return ""
        }
    }

    private var prefixColor: Color {
        guard let cell = cell else { return .secondary }
        switch cell.kind {
        case .add: return .green
        case .del: return .red
        default: return .secondary
        }
    }

    private var textColor: Color {
        guard let cell = cell else { return .secondary.opacity(0.3) }
        if cell.text.isEmpty && (cell.kind == .add || cell.kind == .del) {
            return .secondary.opacity(0.3)
        }
        return .primary
    }

    private var backgroundColor: Color {
        if isHovered {
            return Color.accentColor.opacity(0.15)
        }
        guard let cell = cell else { return Color.gray.opacity(0.03) }
        switch cell.kind {
        case .add:
            return cell.text.isEmpty ? Color.gray.opacity(0.03) : Color.green.opacity(0.1)
        case .del:
            return cell.text.isEmpty ? Color.gray.opacity(0.03) : Color.red.opacity(0.1)
        default:
            return .clear
        }
    }

    private var lineNumberBackground: Color {
        guard let cell = cell else { return Color(NSColor.controlBackgroundColor).opacity(0.5) }
        switch cell.kind {
        case .add:
            return cell.text.isEmpty ? Color(NSColor.controlBackgroundColor).opacity(0.5) : Color.green.opacity(0.05)
        case .del:
            return cell.text.isEmpty ? Color(NSColor.controlBackgroundColor).opacity(0.5) : Color.red.opacity(0.05)
        default:
            return Color(NSColor.controlBackgroundColor).opacity(0.5)
        }
    }

    private var helpText: String {
        if isFileDeleted {
            return "File deleted - cannot open in editor"
        }
        if let target = targetLine, isNavigable {
            return "Click to go to line \(target)"
        }
        return ""
    }
}
