import Foundation

// MARK: - v1.22: File Watcher Protocol Models

/// 文件读取结果
public struct FileReadResult {
    public let project: String
    public let workspace: String
    public let path: String
    public let content: [UInt8]
    public let size: UInt64

    public static func from(json: [String: Any]) -> FileReadResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let path = json["path"] as? String else {
            return nil
        }
        let content = WSBinary.decodeBytes(json["content"])
        let size: UInt64
        if let value = json["size"] as? UInt64 {
            size = value
        } else if let value = json["size"] as? Int, value >= 0 {
            size = UInt64(value)
        } else {
            size = UInt64(content.count)
        }
        return FileReadResult(
            project: project,
            workspace: workspace,
            path: path,
            content: content,
            size: size
        )
    }
}

/// 文件监控订阅成功结果
public struct WatchSubscribedResult {
    public let project: String
    public let workspace: String

    public static func from(json: [String: Any]) -> WatchSubscribedResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String else {
            return nil
        }
        return WatchSubscribedResult(project: project, workspace: workspace)
    }
}

/// 文件变化通知
public struct FileChangedNotification {
    public let project: String
    public let workspace: String
    public let paths: [String]
    public let kind: String  // "modify", "create", "delete"

    public static func from(json: [String: Any]) -> FileChangedNotification? {
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
public struct GitStatusChangedNotification {
    public let project: String
    public let workspace: String

    public static func from(json: [String: Any]) -> GitStatusChangedNotification? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String else {
            return nil
        }
        return GitStatusChangedNotification(project: project, workspace: workspace)
    }
}

// MARK: - v1.23: File Rename/Delete Protocol Models

/// 文件重命名结果
public struct FileRenameResult {
    public let project: String
    public let workspace: String
    public let oldPath: String
    public let newPath: String
    public let success: Bool
    public let message: String?

    public static func from(json: [String: Any]) -> FileRenameResult? {
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
public struct FileDeleteResult {
    public let project: String
    public let workspace: String
    public let path: String
    public let success: Bool
    public let message: String?

    public static func from(json: [String: Any]) -> FileDeleteResult? {
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
public struct FileMoveResult {
    public let project: String
    public let workspace: String
    public let oldPath: String
    public let newPath: String
    public let success: Bool
    public let message: String?

    public static func from(json: [String: Any]) -> FileMoveResult? {
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
public struct FileWriteResult {
    public let project: String
    public let workspace: String
    public let path: String
    public let success: Bool
    public let size: UInt64

    public static func from(json: [String: Any]) -> FileWriteResult? {
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
public struct FileCopyResult {
    public let project: String
    public let workspace: String
    public let sourceAbsolutePath: String
    public let destPath: String
    public let success: Bool
    public let message: String?

    public static func from(json: [String: Any]) -> FileCopyResult? {
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

// MARK: - 文件浏览器模型

/// 文件条目信息（对应 Core 的 FileEntryInfo）
public struct FileEntry: Identifiable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDir: Bool
    public let size: UInt64
    public let isIgnored: Bool
    public let isSymlink: Bool

    public init(name: String, path: String, isDir: Bool, size: UInt64, isIgnored: Bool, isSymlink: Bool) {
        self.name = name
        self.path = path
        self.isDir = isDir
        self.size = size
        self.isIgnored = isIgnored
        self.isSymlink = isSymlink
    }

    /// 从 JSON 解析
    public static func from(json: [String: Any], parentPath: String) -> FileEntry? {
        guard let name = json["name"] as? String,
              let isDir = json["is_dir"] as? Bool else {
            return nil
        }
        let size = json["size"] as? UInt64 ?? 0
        let isIgnored = json["is_ignored"] as? Bool ?? false
        let isSymlink = json["is_symlink"] as? Bool ?? false
        let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        return FileEntry(name: name, path: path, isDir: isDir, size: size, isIgnored: isIgnored, isSymlink: isSymlink)
    }
}

/// 文件列表请求结果
public struct FileListResult {
    public let project: String
    public let workspace: String
    public let path: String
    public let items: [FileEntry]

    public init(project: String, workspace: String, path: String, items: [FileEntry]) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.items = items
    }

    public static func from(json: [String: Any]) -> FileListResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let path = json["path"] as? String,
              let itemsJson = json["items"] as? [[String: Any]] else {
            return nil
        }

        let parentPath = path == "." ? "" : path
        let items = itemsJson.compactMap { FileEntry.from(json: $0, parentPath: parentPath) }
        return FileListResult(project: project, workspace: workspace, path: path, items: items)
    }
}
