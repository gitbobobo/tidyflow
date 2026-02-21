import Foundation

extension AppState {
    func handleFileIndexResult(_ result: FileIndexResult) {
        let cache = FileIndexCache(
            items: result.items,
            truncated: result.truncated,
            updatedAt: Date(),
            isLoading: false,
            error: nil
        )
        fileIndexCache[result.workspace] = cache
    }

    // MARK: - v1.31 LSP diagnostics

    func handleLspDiagnostics(_ result: LspDiagnosticsResult) {
        let key = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        workspaceLspLoading[key] = false
        let items = result.items.map { item in
            ProjectDiagnosticItem(
                severity: DiagnosticSeverity.from(token: item.severity),
                displayPath: item.path,
                editorPath: item.path.isEmpty ? nil : item.path,
                line: max(1, item.line),
                column: item.column > 0 ? item.column : nil,
                summary: item.message,
                rawLine: item.message
            )
        }.sorted {
            if $0.severity.rank != $1.severity.rank {
                return $0.severity.rank > $1.severity.rank
            }
            if $0.displayPath != $1.displayPath {
                return $0.displayPath < $1.displayPath
            }
            if $0.line != $1.line {
                return $0.line < $1.line
            }
            return ($0.column ?? 0) < ($1.column ?? 0)
        }

        let highest = items.first?.severity ?? DiagnosticSeverity.from(token: result.highestSeverity)
        let updatedAt = Self.parseISO8601(result.updatedAt) ?? Date()
        workspaceDiagnostics[key] = WorkspaceDiagnosticsSnapshot(
            items: items,
            highestSeverity: highest,
            updatedAt: updatedAt,
            sourceCommandId: nil
        )
    }

    func handleLspStatus(_ result: LspStatusResult) {
        let key = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        workspaceLspStatus[key] = WorkspaceLspStatusSnapshot(
            runningLanguages: result.runningLanguages,
            missingLanguages: result.missingLanguages,
            message: result.message,
            updatedAt: Date()
        )
    }

    func lspStatusSnapshot(for workspaceGlobalKey: String?) -> WorkspaceLspStatusSnapshot? {
        guard let key = workspaceGlobalKey else { return nil }
        return workspaceLspStatus[key]
    }

    func isLspLoading(for workspaceGlobalKey: String?) -> Bool {
        guard let key = workspaceGlobalKey else { return false }
        return workspaceLspLoading[key] ?? false
    }

    func markLspLoading(project: String, workspace: String, loading: Bool) {
        let key = globalWorkspaceKey(projectName: project, workspaceName: workspace)
        workspaceLspLoading[key] = loading
    }

    static func parseISO8601(_ text: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        return fmt.date(from: text)
    }
}
