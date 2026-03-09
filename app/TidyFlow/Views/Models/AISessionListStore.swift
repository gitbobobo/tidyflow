import Foundation

final class AISessionListStore: ObservableObject {
    @Published private(set) var pageStates: [String: AISessionListPageState] = [:]

    private var requestInFlightAt: [String: Date] = [:]
    private var requestLastSuccessAt: [String: Date] = [:]
    private(set) var bootstrapWorkspaceKey: String?
    private var dedupDropTotal: Int = 0

    func pageState(project: String, workspace: String, filter: AISessionListFilter) -> AISessionListPageState {
        pageStates[AISessionListSemantics.pageKey(project: project, workspace: workspace, filter: filter)] ?? .empty()
    }

    @discardableResult
    func request(
        project: String,
        workspace: String,
        filter: AISessionListFilter,
        limit: Int,
        cursor: String?,
        append: Bool,
        force: Bool,
        performanceTracer: TFPerformanceTracer,
        sendRequest: () -> Void
    ) -> Bool {
        let perfEvent: TFPerformanceEvent = append ? .aiSessionListPage : .aiSessionListRequest
        let perfTraceId = performanceTracer.begin(TFPerformanceContext(
            event: perfEvent,
            project: project,
            workspace: workspace,
            metadata: ["filter": filter.id, "append": String(append), "limit": String(limit)]
        ))
        defer { performanceTracer.end(perfTraceId) }

        let pageKey = AISessionListSemantics.pageKey(project: project, workspace: workspace, filter: filter)
        let requestKey = Self.requestDedupKey(
            project: project,
            workspace: workspace,
            filter: filter,
            cursor: cursor
        )
        let now = Date()
        if let startedAt = requestInFlightAt[requestKey] {
            if now.timeIntervalSince(startedAt) < 5 {
                dedupDropTotal += 1
                TFLog.perf.info("perf ai_session_list_dedup_drop_total=\(self.dedupDropTotal, privacy: .public)")
                return false
            }
            requestInFlightAt.removeValue(forKey: requestKey)
        }
        if !force,
           let lastSuccessAt = requestLastSuccessAt[requestKey],
           now.timeIntervalSince(lastSuccessAt) < 1 {
            dedupDropTotal += 1
            TFLog.perf.info("perf ai_session_list_dedup_drop_total=\(self.dedupDropTotal, privacy: .public)")
            return false
        }

        var pageState = pageStates[pageKey] ?? .empty()
        if append {
            guard !pageState.isLoadingNextPage else { return false }
            pageState.isLoadingNextPage = true
        } else {
            guard !pageState.isLoadingInitial else { return false }
            if cursor == nil {
                pageState = .empty()
            }
            pageState.isLoadingInitial = true
            pageState.isLoadingNextPage = false
        }
        pageStates[pageKey] = pageState
        requestInFlightAt[requestKey] = now
        sendRequest()
        return true
    }

    func loadNextPage(
        project: String,
        workspace: String,
        filter: AISessionListFilter,
        limit: Int,
        performanceTracer: TFPerformanceTracer,
        sendRequest: (_ cursor: String) -> Void
    ) -> Bool {
        let pageState = pageState(project: project, workspace: workspace, filter: filter)
        guard pageState.hasMore, let nextCursor = pageState.nextCursor, !nextCursor.isEmpty else { return false }
        return request(
            project: project,
            workspace: workspace,
            filter: filter,
            limit: limit,
            cursor: nextCursor,
            append: true,
            force: false,
            performanceTracer: performanceTracer
        ) {
            sendRequest(nextCursor)
        }
    }

    @discardableResult
    func bootstrapIfNeeded(
        project: String,
        workspace: String,
        resetFilter: () -> Void,
        requestInitialPage: () -> Bool
    ) -> Bool {
        let globalKey = WorkspaceKeySemantics.globalKey(project: project, workspace: workspace)
        guard bootstrapWorkspaceKey != globalKey else { return false }
        bootstrapWorkspaceKey = globalKey
        resetFilter()
        return requestInitialPage()
    }

    @discardableResult
    func handleResponse(
        project: String,
        workspace: String,
        filter: AISessionListFilter,
        sessions: [AISessionInfo],
        hasMore: Bool,
        nextCursor: String?,
        performanceTracer: TFPerformanceTracer
    ) -> AISessionListPageState {
        let perfTraceId = performanceTracer.begin(TFPerformanceContext(
            event: .aiSessionListRefresh,
            project: project,
            workspace: workspace,
            metadata: ["filter": filter.id, "session_count": String(sessions.count)]
        ))
        defer { performanceTracer.end(perfTraceId) }

        markRequestCompleted(project: project, workspace: workspace, filter: filter)
        var pageState = pageState(project: project, workspace: workspace, filter: filter)
        let orderedMergedSessions: [AISessionInfo]
        if pageState.isLoadingNextPage {
            let mergedSessions = (pageState.sessions + sessions).reduce(into: [String: AISessionInfo]()) { result, session in
                result[session.sessionKey] = session
            }
            let orderedKeys = (pageState.sessions + sessions).map(\.sessionKey)
            var seen = Set<String>()
            orderedMergedSessions = orderedKeys.compactMap { key in
                guard seen.insert(key).inserted else { return nil }
                return mergedSessions[key]
            }
        } else {
            orderedMergedSessions = sessions
        }
        pageState.sessions = orderedMergedSessions
        pageState.hasMore = hasMore
        pageState.nextCursor = nextCursor
        pageState.isLoadingInitial = false
        pageState.isLoadingNextPage = false
        pageStates[AISessionListSemantics.pageKey(project: project, workspace: workspace, filter: filter)] = pageState
        return pageState
    }

    func clear() {
        pageStates = [:]
        requestInFlightAt.removeAll()
        requestLastSuccessAt.removeAll()
        bootstrapWorkspaceKey = nil
    }

    func handleClientError() {
        pageStates = pageStates.mapValues { state in
            var updated = state
            updated.isLoadingInitial = false
            updated.isLoadingNextPage = false
            return updated
        }
        requestInFlightAt.removeAll()
    }

    func upsertVisibleSession(_ session: AISessionInfo) {
        pageStates = pageStates.reduce(into: [:]) { result, item in
            let (key, state) = item
            var updated = state
            let allKey = AISessionListSemantics.pageKey(
                project: session.projectName,
                workspace: session.workspaceName,
                filter: .all
            )
            let toolKey = AISessionListSemantics.pageKey(
                project: session.projectName,
                workspace: session.workspaceName,
                filter: .tool(session.aiTool)
            )
            if key == allKey || key == toolKey {
                updated.sessions.removeAll { $0.sessionKey == session.sessionKey }
                if session.isVisibleInDefaultSessionList {
                    updated.sessions.insert(session, at: 0)
                }
            }
            result[key] = updated
        }
    }

    func removeSession(sessionId: String, tool: AIChatTool) {
        pageStates = pageStates.mapValues { state in
            var updated = state
            updated.sessions.removeAll { $0.aiTool == tool && $0.id == sessionId }
            return updated
        }
    }

    func renameSession(_ session: AISessionInfo, newTitle: String) {
        pageStates = pageStates.mapValues { state in
            var updated = state
            updated.sessions = updated.sessions.map { current in
                guard current.sessionKey == session.sessionKey else { return current }
                return AISessionInfo(
                    projectName: current.projectName,
                    workspaceName: current.workspaceName,
                    aiTool: current.aiTool,
                    id: current.id,
                    title: newTitle,
                    updatedAt: current.updatedAt,
                    origin: current.origin
                )
            }
            return updated
        }
    }

    private func markRequestCompleted(project: String, workspace: String, filter: AISessionListFilter) {
        let prefix = "\(project)::\(workspace)::\(filter.id)::"
        let now = Date()
        for key in requestInFlightAt.keys.filter({ $0.hasPrefix(prefix) }) {
            requestInFlightAt.removeValue(forKey: key)
            requestLastSuccessAt[key] = now
        }
    }

    private static func requestDedupKey(
        project: String,
        workspace: String,
        filter: AISessionListFilter,
        cursor: String?
    ) -> String {
        let normalizedCursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(project)::\(workspace)::\(filter.id)::\(normalizedCursor)"
    }
}
