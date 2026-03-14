import Foundation
import TidyFlowShared

extension AppState {
    // MARK: - 全局搜索

    /// 当前工作区的搜索状态
    var currentSearchState: GlobalSearchState {
        guard let key = currentGlobalWorkspaceKey else { return .empty() }
        return globalSearchStates[key] ?? .empty()
    }

    /// 执行文件内容搜索
    func performGlobalSearch(query: String, caseSensitive: Bool = false) {
        guard let workspace = selectedWorkspaceKey else { return }
        let globalKey = globalWorkspaceKey(projectName: selectedProjectName, workspaceName: workspace)

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空查询：清除结果
        if trimmed.isEmpty {
            globalSearchStates[globalKey] = .empty()
            return
        }

        // 设置 loading 状态
        var state = globalSearchStates[globalKey] ?? .empty()
        state.query = GlobalSearchQuery(text: trimmed, caseSensitive: caseSensitive)
        state.isLoading = true
        state.error = nil
        globalSearchStates[globalKey] = state

        // 发起搜索请求
        wsClient.requestFileContentSearch(
            project: selectedProjectName,
            workspace: workspace,
            query: trimmed,
            caseSensitive: caseSensitive,
            cacheMode: .forceRefresh
        )
    }

    /// 处理搜索结果（由 AppStateFileMessageHandlerAdapter 调用）
    func handleFileContentSearchResult(_ result: FileContentSearchResult) {
        let globalKey = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        var state = globalSearchStates[globalKey] ?? .empty()
        state.query = GlobalSearchQuery(text: result.query, caseSensitive: false)
        state.isLoading = false
        state.sections = GlobalSearchResultBuilder.buildSections(from: result)
        state.totalMatches = result.totalMatches
        state.truncated = result.truncated
        state.searchDurationMs = result.searchDurationMs
        state.error = nil
        globalSearchStates[globalKey] = state
    }

    /// 从搜索结果打开文件并跳转到指定行
    func openSearchResult(_ match: GlobalSearchMatch) {
        guard let workspace = selectedWorkspaceKey else { return }
        let workspaceKey = globalWorkspaceKey(projectName: selectedProjectName, workspaceName: workspace)
        addEditorTab(workspaceKey: workspaceKey, path: match.path, line: match.line)
    }
}
