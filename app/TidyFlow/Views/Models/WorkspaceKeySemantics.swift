import Foundation

/// 项目/工作区键语义层：统一所有缓存键生成、工作区别名归一化与前缀规则。
/// macOS 与 iOS 两端共用，禁止在其他地方重复散落同类字符串拼接逻辑。
enum WorkspaceKeySemantics {

    // MARK: - 工作区别名归一化

    /// 归一化工作区名称：将 "default" / "(default)"（不区分大小写）统一为 "default"。
    /// 同时去除首尾空白，保证不同来源的字符串可以安全比较。
    static func normalizeWorkspaceName(_ workspace: String) -> String {
        let trimmed = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("(default)") == .orderedSame ||
            trimmed.caseInsensitiveCompare("default") == .orderedSame {
            return "default"
        }
        return trimmed
    }

    // MARK: - 全局工作区键

    /// 生成全局唯一工作区键："{project}:{workspace}"。
    /// 用于区分不同项目下同名工作区；project 与 workspace 均先去除首尾空白。
    static func globalKey(project: String, workspace: String) -> String {
        let p = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(p):\(w)"
    }

    // MARK: - 文件缓存键

    /// 生成文件/目录缓存键："{project}:{workspace}:{path}"。
    /// path 维度保证不同目录的展开状态不互相覆盖。
    static func fileCacheKey(project: String, workspace: String, path: String) -> String {
        return "\(globalKey(project: project, workspace: workspace)):\(path)"
    }

    /// 生成文件缓存键前缀："{project}:{workspace}:"。
    /// 用于按工作区批量扫描或失效缓存。
    static func fileCachePrefix(project: String, workspace: String) -> String {
        return "\(globalKey(project: project, workspace: workspace)):"
    }
}
