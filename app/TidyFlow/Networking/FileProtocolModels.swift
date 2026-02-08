import Foundation

// MARK: - v1.22: File Watcher Protocol Models

/// 文件监控订阅成功结果
struct WatchSubscribedResult {
    let project: String
    let workspace: String

    static func from(json: [String: Any]) -> WatchSubscribedResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String else {
            return nil
        }
        return WatchSubscribedResult(project: project, workspace: workspace)
    }
}

/// 文件变化通知
struct FileChangedNotification {
    let project: String
    let workspace: String
    let paths: [String]
    let kind: String  // "modify", "create", "delete"

    static func from(json: [String: Any]) -> FileChangedNotification? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let paths = json["paths"] as? [String],
              let kind = json["kind"] as? String else {
            return nil
        }
        return FileChangedNotification(
            project: project,
            workspace: workspace,
            paths: paths,
            kind: kind
        )
    }
}

/// Git 状态变化通知
struct GitStatusChangedNotification {
    let project: String
    let workspace: String

    static func from(json: [String: Any]) -> GitStatusChangedNotification? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String else {
            return nil
        }
        return GitStatusChangedNotification(project: project, workspace: workspace)
    }
}

// MARK: - v1.23: File Rename/Delete Protocol Models

/// 文件重命名结果
struct FileRenameResult {
    let project: String
    let workspace: String
    let oldPath: String
    let newPath: String
    let success: Bool
    let message: String?

    static func from(json: [String: Any]) -> FileRenameResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let oldPath = json["old_path"] as? String,
              let newPath = json["new_path"] as? String,
              let success = json["success"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        return FileRenameResult(
            project: project,
            workspace: workspace,
            oldPath: oldPath,
            newPath: newPath,
            success: success,
            message: message
        )
    }
}

/// 文件删除结果
struct FileDeleteResult {
    let project: String
    let workspace: String
    let path: String
    let success: Bool
    let message: String?

    static func from(json: [String: Any]) -> FileDeleteResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let path = json["path"] as? String,
              let success = json["success"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        return FileDeleteResult(
            project: project,
            workspace: workspace,
            path: path,
            success: success,
            message: message
        )
    }
}

// MARK: - v1.25: File Move Protocol Models

/// 文件移动结果
struct FileMoveResult {
    let project: String
    let workspace: String
    let oldPath: String
    let newPath: String
    let success: Bool
    let message: String?

    static func from(json: [String: Any]) -> FileMoveResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let oldPath = json["old_path"] as? String,
              let newPath = json["new_path"] as? String,
              let success = json["success"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        return FileMoveResult(
            project: project,
            workspace: workspace,
            oldPath: oldPath,
            newPath: newPath,
            success: success,
            message: message
        )
    }
}

/// 文件写入结果（新建文件）
struct FileWriteResult {
    let project: String
    let workspace: String
    let path: String
    let success: Bool
    let size: UInt64

    static func from(json: [String: Any]) -> FileWriteResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let path = json["path"] as? String,
              let success = json["success"] as? Bool else {
            return nil
        }
        let size = json["size"] as? UInt64 ?? 0
        return FileWriteResult(
            project: project,
            workspace: workspace,
            path: path,
            success: success,
            size: size
        )
    }
}

/// 文件复制结果
struct FileCopyResult {
    let project: String
    let workspace: String
    let sourceAbsolutePath: String
    let destPath: String
    let success: Bool
    let message: String?

    static func from(json: [String: Any]) -> FileCopyResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let sourceAbsolutePath = json["source_absolute_path"] as? String,
              let destPath = json["dest_path"] as? String,
              let success = json["success"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        return FileCopyResult(
            project: project,
            workspace: workspace,
            sourceAbsolutePath: sourceAbsolutePath,
            destPath: destPath,
            success: success,
            message: message
        )
    }
}
