import Foundation

public struct HTTPQueryKeyItem: Hashable, Sendable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

public struct HTTPQueryKey: Hashable, Sendable {
    public let baseURLString: String
    public let path: String
    public let queryItems: [HTTPQueryKeyItem]
    public let fallbackAction: String

    public init(baseURL: URL, path: String, queryItems: [URLQueryItem], fallbackAction: String) {
        self.baseURLString = baseURL.absoluteString
        self.path = path
        self.queryItems = queryItems
            .map { HTTPQueryKeyItem(name: $0.name, value: $0.value) }
            .sorted {
                if $0.name != $1.name {
                    return $0.name < $1.name
                }
                return ($0.value ?? "") < ($1.value ?? "")
            }
        self.fallbackAction = fallbackAction
    }
}

public enum HTTPQueryCacheMode: Equatable, Sendable {
    case `default`
    case forceRefresh
}

public struct HTTPQueryPolicy: Equatable, Sendable {
    public let staleTime: TimeInterval
    public let gcTime: TimeInterval
    public let shouldServeStaleWhileRevalidate: Bool

    public init(staleTime: TimeInterval, gcTime: TimeInterval, shouldServeStaleWhileRevalidate: Bool = true) {
        self.staleTime = staleTime
        self.gcTime = gcTime
        self.shouldServeStaleWhileRevalidate = shouldServeStaleWhileRevalidate
    }
}

public struct HTTPQueryEntry: Sendable {
    public let payload: Data?
    public let lastSuccessAt: Date?
    public let lastErrorDescription: String?
    public let lastAccessedAt: Date

    public init(payload: Data?, lastSuccessAt: Date?, lastErrorDescription: String?, lastAccessedAt: Date) {
        self.payload = payload
        self.lastSuccessAt = lastSuccessAt
        self.lastErrorDescription = lastErrorDescription
        self.lastAccessedAt = lastAccessedAt
    }
}

public enum HTTPQueryCachedValue: Sendable {
    case fresh(Data)
    case stale(Data)
}

public actor HTTPQueryClient {
    private struct Entry {
        var payload: Data?
        var lastSuccessAt: Date?
        var lastErrorDescription: String?
        var lastAccessedAt: Date
        var inFlightTask: Task<Data, Error>?
    }

    private var entries: [HTTPQueryKey: Entry] = [:]

    public init() {}

    public static func policy(forFallbackAction fallbackAction: String) -> HTTPQueryPolicy {
        switch fallbackAction {
        case
            "file_list_result",
            "git_status_result",
            "git_branches_result",
            "git_op_status_result",
            "git_integration_status_result",
            "ai_session_list",
            "ai_session_messages",
            "ai_session_status_result",
            "evo_snapshot",
            "evidence_snapshot",
            "system_snapshot":
            return HTTPQueryPolicy(staleTime: 30, gcTime: 600)
        case
            "file_index_result",
            "projects",
            "workspaces",
            "term_list",
            "client_settings_result",
            "templates",
            "tasks_snapshot",
            "ai_provider_list",
            "ai_agent_list",
            "ai_slash_commands",
            "ai_session_config_options",
            "evo_agent_profile",
            "evo_cycle_history":
            return HTTPQueryPolicy(staleTime: 300, gcTime: 1800)
        case
            "file_read_result",
            "git_diff_result",
            "git_log_result",
            "git_show_result",
            "git_conflict_detail_result",
            "template_exported",
            "evidence_item_chunk",
            "evidence_rebuild_prompt":
            return HTTPQueryPolicy(staleTime: 600, gcTime: 3600)
        default:
            return HTTPQueryPolicy(staleTime: 300, gcTime: 1800)
        }
    }

    public func cachedValue(
        for key: HTTPQueryKey,
        policy: HTTPQueryPolicy,
        mode: HTTPQueryCacheMode,
        now: Date = Date()
    ) -> HTTPQueryCachedValue? {
        evictGarbageCollectedEntries(now: now)
        guard mode == .default,
              var entry = entries[key],
              let payload = entry.payload,
              let lastSuccessAt = entry.lastSuccessAt else {
            return nil
        }
        entry.lastAccessedAt = now
        entries[key] = entry
        if now.timeIntervalSince(lastSuccessAt) <= policy.staleTime {
            return .fresh(payload)
        }
        guard policy.shouldServeStaleWhileRevalidate else {
            return nil
        }
        return .stale(payload)
    }

    public func fetch(
        key: HTTPQueryKey,
        policy: HTTPQueryPolicy,
        force: Bool,
        now: Date = Date(),
        fetcher: @escaping () async throws -> Data
    ) async throws -> Data {
        evictGarbageCollectedEntries(now: now)

        if !force,
           let cached = cachedValue(for: key, policy: policy, mode: .default, now: now) {
            switch cached {
            case let .fresh(data), let .stale(data):
                return data
            }
        }

        if let existingTask = entries[key]?.inFlightTask {
            return try await existingTask.value
        }

        var entry = entries[key] ?? Entry(
            payload: nil,
            lastSuccessAt: nil,
            lastErrorDescription: nil,
            lastAccessedAt: now,
            inFlightTask: nil
        )

        let task = Task<Data, Error> {
            try await fetcher()
        }
        entry.lastAccessedAt = now
        entry.inFlightTask = task
        entries[key] = entry

        do {
            let data = try await task.value
            var updated = entries[key] ?? entry
            updated.payload = data
            updated.lastSuccessAt = Date()
            updated.lastErrorDescription = nil
            updated.lastAccessedAt = Date()
            updated.inFlightTask = nil
            entries[key] = updated
            return data
        } catch {
            var updated = entries[key] ?? entry
            updated.lastErrorDescription = error.localizedDescription
            updated.lastAccessedAt = Date()
            updated.inFlightTask = nil
            entries[key] = updated
            throw error
        }
    }

    public func invalidate(key: HTTPQueryKey) {
        entries.removeValue(forKey: key)
    }

    public func invalidateAll() {
        entries.removeAll()
    }

    public func invalidate(matching predicate: @Sendable (HTTPQueryKey) -> Bool) {
        entries.keys
            .filter(predicate)
            .forEach { entries.removeValue(forKey: $0) }
    }

    public func entry(for key: HTTPQueryKey) -> HTTPQueryEntry? {
        guard let entry = entries[key] else { return nil }
        return HTTPQueryEntry(
            payload: entry.payload,
            lastSuccessAt: entry.lastSuccessAt,
            lastErrorDescription: entry.lastErrorDescription,
            lastAccessedAt: entry.lastAccessedAt
        )
    }

    private func evictGarbageCollectedEntries(now: Date) {
        entries.keys
            .filter { key in
                guard let lastAccessedAt = entries[key]?.lastAccessedAt else { return true }
                let policy = Self.policy(forFallbackAction: key.fallbackAction)
                return now.timeIntervalSince(lastAccessedAt) > policy.gcTime
            }
            .forEach { entries.removeValue(forKey: $0) }
    }
}
