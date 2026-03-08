import Foundation

// MARK: - 工作区身份标识

/// 工作区身份标识：唯一确定一个项目下的工作区。
/// macOS 与 iOS 共享此值类型，确保双端用同一种方式表达"当前选中的工作区"，
/// 不再由各平台各自从视图状态反推 project + workspace 组合。
struct WorkspaceIdentity: Equatable, Hashable, Sendable {
    let projectId: UUID
    let projectName: String
    let workspaceName: String

    /// 归一化后的全局键（"project:workspace"），用于缓存键与状态隔离。
    var globalKey: String {
        WorkspaceKeySemantics.globalKey(project: projectName, workspace: workspaceName)
    }

    /// 文件缓存前缀（"project:workspace:"），用于按工作区批量扫描或失效缓存。
    var fileCachePrefix: String {
        WorkspaceKeySemantics.fileCachePrefix(project: projectName, workspace: workspaceName)
    }

    /// 生成指定路径的文件缓存键。
    func fileCacheKey(path: String) -> String {
        WorkspaceKeySemantics.fileCacheKey(project: projectName, workspace: workspaceName, path: path)
    }
}

// MARK: - 工作区选择语义

/// 工作区选择语义层：双端共享的选择匹配、列表排序与多项目隔离规则。
/// macOS `AppState` 与 iOS `MobileAppState` 通过此层统一判定，
/// 视图只读取结果，不自行重复推导选择态。
enum WorkspaceSelectionSemantics {

    /// 判断给定的工作区是否匹配当前选择（project + workspace 维度）。
    static func matches(
        identity: WorkspaceIdentity?,
        projectName: String,
        workspaceName: String
    ) -> Bool {
        guard let identity else { return false }
        return identity.projectName == projectName && identity.workspaceName == workspaceName
    }

    /// 判断给定全局键是否匹配当前选中工作区。
    static func matchesGlobalKey(identity: WorkspaceIdentity?, globalKey: String) -> Bool {
        guard let identity else { return false }
        return identity.globalKey == globalKey
    }

    /// 工作区列表排序：默认工作区排在最前，其余按名称字母序。
    /// macOS 与 iOS 使用同一规则，不在视图层各自排序。
    static func sortedWorkspaces<W: WorkspaceSortable>(_ workspaces: [W]) -> [W] {
        workspaces.sorted { lhs, rhs in
            if lhs.isDefaultWorkspace != rhs.isDefaultWorkspace { return lhs.isDefaultWorkspace }
            return lhs.workspaceSortName.localizedCaseInsensitiveCompare(rhs.workspaceSortName) == .orderedAscending
        }
    }

    /// 从项目列表中查找指定 projectId 对应的项目名。
    /// 若找不到则返回 fallback（通常为当前 selectedProjectName），并记录错误。
    static func resolveProjectName<P: ProjectIdentifiable>(
        projectId: UUID,
        in projects: [P],
        fallback: String
    ) -> String {
        projects.first(where: { $0.projectUUID == projectId })?.projectDisplayName ?? fallback
    }
}

// MARK: - 排序协议抽象

/// 工作区排序所需的最小接口，让 WorkspaceModel 和 WorkspaceInfo 都能共享排序规则。
protocol WorkspaceSortable {
    var isDefaultWorkspace: Bool { get }
    var workspaceSortName: String { get }
}

/// 项目身份所需的最小接口，让 ProjectModel 和 ProjectInfo 都能共享查找规则。
protocol ProjectIdentifiable {
    var projectUUID: UUID { get }
    var projectDisplayName: String { get }
}

// MARK: - WorkspaceInfo 排序适配

/// 让 TidyFlowShared 中的 WorkspaceInfo 也能参与共享排序规则。
/// WorkspaceInfo 没有显式 isDefault 字段，通过名称归一化推断。
extension WorkspaceInfo: WorkspaceSortable {
    public var isDefaultWorkspace: Bool {
        WorkspaceKeySemantics.normalizeWorkspaceName(name) == "default"
    }
    public var workspaceSortName: String { name }
}

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

// MARK: - 项目排序语义层

/// 项目列表排序语义：双端共享排序规则，避免 macOS 与 iOS 各自维护同一套排序逻辑。
/// 排序优先级：有快捷键的项目靠前 → 同为快捷键项目按终端首次打开时间 → 按名称字母序。
enum ProjectSortingSemantics {

    /// 对项目列表进行共享排序。
    /// - Parameters:
    ///   - projects: 待排序的项目列表
    ///   - shortcutKeyFinder: 返回项目最小快捷键编号（无快捷键返回 Int.max）
    ///   - earliestTerminalTimeFinder: 返回项目最早终端打开时间
    ///   - nameExtractor: 返回项目的显示名称（用于字母序排序）
    static func sortedProjects<P>(
        _ projects: [P],
        shortcutKeyFinder: (P) -> Int,
        earliestTerminalTimeFinder: (P) -> Date?,
        nameExtractor: ((P) -> String)? = nil
    ) -> [P] {
        projects.sorted { lhs, rhs in
            let lhsHasShortcut = shortcutKeyFinder(lhs) < Int.max
            let rhsHasShortcut = shortcutKeyFinder(rhs) < Int.max
            if lhsHasShortcut != rhsHasShortcut {
                return lhsHasShortcut
            }

            if lhsHasShortcut && rhsHasShortcut {
                let lhsTime = earliestTerminalTimeFinder(lhs)
                let rhsTime = earliestTerminalTimeFinder(rhs)
                if let l = lhsTime, let r = rhsTime, l != r {
                    return l < r
                }
            }

            let extract = nameExtractor ?? { p in
                (p as? ProjectIdentifiable)?.projectDisplayName ?? "\(p)"
            }
            return extract(lhs).localizedCaseInsensitiveCompare(extract(rhs)) == .orderedAscending
        }
    }

    /// 返回排序后的索引数组（用于需要保持原数组引用的场景，如 macOS 侧边栏 Binding）。
    static func sortedIndices<P>(
        _ projects: [P],
        shortcutKeyFinder: (P) -> Int,
        earliestTerminalTimeFinder: (P) -> Date?,
        nameExtractor: ((P) -> String)? = nil
    ) -> [Int] {
        projects.indices.sorted { i, j in
            let lhs = projects[i]
            let rhs = projects[j]
            let lhsHasShortcut = shortcutKeyFinder(lhs) < Int.max
            let rhsHasShortcut = shortcutKeyFinder(rhs) < Int.max
            if lhsHasShortcut != rhsHasShortcut {
                return lhsHasShortcut
            }
            if lhsHasShortcut && rhsHasShortcut {
                let lhsTime = earliestTerminalTimeFinder(lhs)
                let rhsTime = earliestTerminalTimeFinder(rhs)
                if let l = lhsTime, let r = rhsTime, l != r {
                    return l < r
                }
            }
            let extract = nameExtractor ?? { p in
                (p as? ProjectIdentifiable)?.projectDisplayName ?? "\(p)"
            }
            return extract(lhs).localizedCaseInsensitiveCompare(extract(rhs)) == .orderedAscending
        }
    }
}
