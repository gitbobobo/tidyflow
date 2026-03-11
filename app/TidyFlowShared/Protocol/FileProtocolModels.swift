import Foundation

// MARK: - 文件系统统一状态机

/// 文件工作区相位：描述某个 (project, workspace) 的文件子系统聚合就绪状态。
///
/// 与 Core 的 `FileWorkspacePhase` 枚举语义一致（`core/src/server/protocol/file.rs`）。
/// macOS 与 iOS 共享此类型，不允许各自推导。
public enum FileWorkspacePhase: String, Equatable, Sendable {
    /// 文件子系统未激活
    case idle
    /// 文件索引扫描进行中
    case indexing
    /// watcher 已就绪，增量事件正常投递
    case watching
    /// watcher 遇到非致命错误，缓存可能过时
    case degraded
    /// 致命错误，文件操作不可用
    case error
    /// 正在从 error/degraded 恢复
    case recovering

    /// 是否允许执行文件写操作（仅 `error` 阶段阻塞写操作）
    public var allowsWrite: Bool {
        self != .error
    }

    /// 是否处于正常就绪状态
    public var isReady: Bool {
        self == .watching
    }

    /// 是否需要恢复关注
    public var needsAttention: Bool {
        switch self {
        case .degraded, .error, .recovering: return true
        default: return false
        }
    }
}

/// 文件变更事件类型。
///
/// 与 Core 的 `FileChangeKind` 枚举语义一致。
/// 替代原先 `FileChangedNotification.kind` 中的字符串字面量。
public enum FileChangeKind: String, Equatable, Sendable {
    case created
    case modified
    case removed
    case renamed

    /// 从字符串解析，不可识别值回退为 `.modified`
    public init(rawString: String) {
        switch rawString {
        case "created", "create": self = .created
        case "removed", "deleted", "delete", "remove": self = .removed
        case "renamed", "rename": self = .renamed
        default: self = .modified
        }
    }
}

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
        let content: [UInt8]
        if let contentBase64 = json["content_base64"] as? String,
           let data = Data(base64Encoded: contentBase64) {
            content = [UInt8](data)
        } else {
            content = WSBinary.decodeBytes(json["content"])
        }
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

    public init(project: String, workspace: String, path: String, content: [UInt8], size: UInt64) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.content = content
        self.size = size
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

    public init(project: String, workspace: String) {
        self.project = project
        self.workspace = workspace
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

    public init(project: String, workspace: String, paths: [String], kind: String) {
        self.project = project
        self.workspace = workspace
        self.paths = paths
        self.kind = kind
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

    public init(project: String, workspace: String) {
        self.project = project
        self.workspace = workspace
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

    public init(project: String, workspace: String, oldPath: String, newPath: String, success: Bool, message: String?) {
        self.project = project
        self.workspace = workspace
        self.oldPath = oldPath
        self.newPath = newPath
        self.success = success
        self.message = message
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

    public init(project: String, workspace: String, path: String, success: Bool, message: String?) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.success = success
        self.message = message
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

    public init(project: String, workspace: String, oldPath: String, newPath: String, success: Bool, message: String?) {
        self.project = project
        self.workspace = workspace
        self.oldPath = oldPath
        self.newPath = newPath
        self.success = success
        self.message = message
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

    public init(project: String, workspace: String, path: String, success: Bool, size: UInt64) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.success = success
        self.size = size
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

    public init(project: String, workspace: String, sourceAbsolutePath: String, destPath: String, success: Bool, message: String?) {
        self.project = project
        self.workspace = workspace
        self.sourceAbsolutePath = sourceAbsolutePath
        self.destPath = destPath
        self.success = success
        self.message = message
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

    public init(name: String, path: String, isDir: Bool, size: UInt64, isIgnored: Bool, isSymlink: Bool) {
        self.name = name
        self.path = path
        self.isDir = isDir
        self.size = size
        self.isIgnored = isIgnored
        self.isSymlink = isSymlink
    }
}

/// 文件列表请求结果
public struct FileListResult {
    public let project: String
    public let workspace: String
    public let path: String
    public let items: [FileEntry]

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

    public init(project: String, workspace: String, path: String, items: [FileEntry]) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.items = items
    }
}
