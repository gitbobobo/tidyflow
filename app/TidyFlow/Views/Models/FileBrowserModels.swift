import Foundation
import Combine
import SwiftUI

// MARK: - Git 状态索引（资源管理器用）

/// Git 状态索引，支持 O(1) 路径查找和文件夹状态聚合
struct GitStatusIndex {
    /// 文件路径 -> 状态码（M, A, D, ??, R, C, U）
    private var fileStatus: [String: String] = [:]
    /// 文件夹路径 -> 聚合状态码（子文件中优先级最高的状态）
    private var folderStatus: [String: String] = [:]

    /// 状态优先级（数字越大优先级越高）
    private static let statusPriority: [String: Int] = [
        "U": 7,   // 冲突
        "M": 6,   // 修改
        "A": 5,   // 新增
        "D": 4,   // 删除
        "R": 3,   // 重命名
        "C": 2,   // 复制
        "??": 1,  // 未跟踪
        "!!": 0,  // 忽略
    ]

    /// 从 GitStatusCache 构建索引
    init(from cache: GitStatusCache) {
        // 1. 索引所有文件状态
        for item in cache.items {
            fileStatus[item.path] = item.status
        }

        // 2. 向上传播状态到父目录
        for item in cache.items {
            propagateToParents(path: item.path, status: item.status)
        }
    }

    /// 空索引
    init() {}

    /// 从 GitStatusItem 列表构建索引（适用于 iOS 端从 MobileWorkspaceGitDetailState 派生）
    init(fromItems items: [GitStatusItem]) {
        for item in items {
            fileStatus[item.path] = item.status
        }
        for item in items {
            propagateToParents(path: item.path, status: item.status)
        }
    }

    /// 向上传播状态到所有父目录
    private mutating func propagateToParents(path: String, status: String) {
        // 不传播到父目录的状态：
        // !! 忽略文件：用户关心的是有变更的文件
        // D 删除文件：删除状态无需向上传递，避免父目录显示删除标记
        // ?? 未跟踪文件：未纳入版本控制的文件不应影响父目录状态
        if status == "!!" || status == "D" || status == "??" { return }

        var currentPath = path
        while let lastSlash = currentPath.lastIndex(of: "/") {
            currentPath = String(currentPath[..<lastSlash])
            if currentPath.isEmpty { break }

            // 比较优先级，保留更高优先级的状态
            if let existing = folderStatus[currentPath] {
                let existingPriority = Self.statusPriority[existing] ?? 0
                let newPriority = Self.statusPriority[status] ?? 0
                if newPriority > existingPriority {
                    folderStatus[currentPath] = status
                }
            } else {
                folderStatus[currentPath] = status
            }
        }
    }

    /// 获取文件的 Git 状态
    func getFileStatus(_ path: String) -> String? {
        return fileStatus[path]
    }

    /// 获取文件夹的聚合 Git 状态
    func getFolderStatus(_ path: String) -> String? {
        return folderStatus[path]
    }

    /// 获取任意路径的状态（文件或文件夹）
    func getStatus(path: String, isDir: Bool) -> String? {
        if isDir {
            return folderStatus[path]
        } else {
            return fileStatus[path]
        }
    }

    /// 根据状态码返回对应颜色
    static func colorForStatus(_ status: String?) -> Color? {
        guard let status = status else { return nil }
        switch status {
        case "M": return .orange      // 修改
        case "A": return .green       // 新增
        case "D": return .red         // 删除
        case "??": return .gray       // 未跟踪
        case "R": return .blue        // 重命名
        case "C": return .cyan        // 复制
        case "U": return .purple      // 冲突
        case "!!": return .secondary.opacity(0.5)  // 忽略
        default: return nil
        }
    }
}

// MARK: - 文件浏览器模型
// FileEntry と FileListResult は TidyFlowShared/Protocol/FileProtocolModels.swift へ移行

class DirectoryNode: Identifiable, ObservableObject {
    let id: String
    let name: String
    let path: String
    @Published var isExpanded: Bool = false
    @Published var isLoading: Bool = false
    @Published var children: [FileEntry] = []
    @Published var error: String?
    
    init(name: String, path: String) {
        self.id = path.isEmpty ? "." : path
        self.name = name
        self.path = path
    }
}

/// 文件列表缓存（按目录路径缓存）
struct FileListCache {
    var items: [FileEntry]
    var isLoading: Bool
    var error: String?
    var updatedAt: Date?

    static func empty() -> FileListCache {
        FileListCache(items: [], isLoading: false, error: nil, updatedAt: nil)
    }

    var isExpired: Bool {
        guard let updatedAt = updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > 60 // 60秒后过期
    }
}
