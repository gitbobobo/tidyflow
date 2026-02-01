import Foundation

/// Result from file_index request
struct FileIndexResult {
    let project: String
    let workspace: String
    let items: [String]
    let truncated: Bool

    static func from(json: [String: Any]) -> FileIndexResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let items = json["items"] as? [String] else {
            return nil
        }
        let truncated = json["truncated"] as? Bool ?? false
        return FileIndexResult(project: project, workspace: workspace, items: items, truncated: truncated)
    }
}

/// Cached file index for a workspace
struct FileIndexCache {
    var items: [String]
    var truncated: Bool
    var updatedAt: Date
    var isLoading: Bool
    var error: String?

    static func empty() -> FileIndexCache {
        FileIndexCache(items: [], truncated: false, updatedAt: .distantPast, isLoading: false, error: nil)
    }

    var isExpired: Bool {
        // Cache expires after 10 minutes
        Date().timeIntervalSince(updatedAt) > 600
    }
}
