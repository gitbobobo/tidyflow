import Foundation

// MARK: - 全局搜索共享语义层
//
// 此文件定义跨平台搜索状态、结果分组与预览格式化逻辑。
// macOS/iOS 均消费此共享层，不得各自重新推导搜索语义。

/// 搜索范围：当前固定为工作区级别
public enum GlobalSearchScope: String, Equatable, Sendable {
    case workspace
}

/// 搜索查询：封装查询参数
public struct GlobalSearchQuery: Equatable, Sendable {
    public let text: String
    public let caseSensitive: Bool
    public let scope: GlobalSearchScope

    public init(text: String, caseSensitive: Bool = false, scope: GlobalSearchScope = .workspace) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.scope = scope
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 搜索结果中的单条匹配（从 FileContentSearchItem 转换）
public struct GlobalSearchMatch: Identifiable, Equatable, Sendable {
    public let id: String
    public let project: String
    public let workspace: String
    public let path: String
    public let line: Int
    public let column: Int
    public let preview: String
    public let matchRanges: [FileContentSearchMatchRange]
    public let beforeContext: [String]
    public let afterContext: [String]

    /// 文件名（从 path 提取）
    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    /// 目录路径（从 path 提取，不含文件名）
    public var directoryPath: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }

    public init(
        project: String, workspace: String, item: FileContentSearchItem
    ) {
        self.id = "\(project):\(workspace):\(item.path):\(item.line):\(item.column)"
        self.project = project
        self.workspace = workspace
        self.path = item.path
        self.line = item.line
        self.column = item.column
        self.preview = item.preview
        self.matchRanges = item.matchRanges
        self.beforeContext = item.beforeContext
        self.afterContext = item.afterContext
    }
}

/// 搜索结果分组（按文件路径分组）
public struct GlobalSearchSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let fileName: String
    public let directoryPath: String
    public let matches: [GlobalSearchMatch]

    public var matchCount: Int { matches.count }
}

/// 搜索状态（按 project:workspace 隔离）
public struct GlobalSearchState: Equatable, Sendable {
    public var query: GlobalSearchQuery
    public var isLoading: Bool
    public var sections: [GlobalSearchSection]
    public var totalMatches: Int
    public var truncated: Bool
    public var searchDurationMs: Int
    public var error: String?

    public var isEmpty: Bool {
        sections.isEmpty && !isLoading && error == nil
    }

    public var hasResults: Bool {
        !sections.isEmpty
    }

    public static func empty() -> GlobalSearchState {
        GlobalSearchState(
            query: GlobalSearchQuery(text: ""),
            isLoading: false,
            sections: [],
            totalMatches: 0,
            truncated: false,
            searchDurationMs: 0,
            error: nil
        )
    }
}

// MARK: - 结果转换

public enum GlobalSearchResultBuilder {
    /// 将 Core 返回的 FileContentSearchResult 转换为分组后的搜索状态
    public static func buildSections(
        from result: FileContentSearchResult
    ) -> [GlobalSearchSection] {
        let matches = result.items.map {
            GlobalSearchMatch(project: result.project, workspace: result.workspace, item: $0)
        }
        // 按 path 分组
        var grouped: [String: [GlobalSearchMatch]] = [:]
        for match in matches {
            grouped[match.path, default: []].append(match)
        }
        // 按 path 排序
        return grouped.keys.sorted().map { path in
            let sectionMatches = grouped[path]!
            let fileName = (path as NSString).lastPathComponent
            let dirPath = (path as NSString).deletingLastPathComponent
            return GlobalSearchSection(
                id: "\(result.project):\(result.workspace):\(path)",
                path: path,
                fileName: fileName,
                directoryPath: dirPath.isEmpty ? "" : dirPath,
                matches: sectionMatches
            )
        }
    }
}

// MARK: - 预览高亮片段构建

public enum GlobalSearchPreviewFormatter {
    /// 从 match ranges 构建高亮片段数组
    /// 返回 [(text, isHighlighted)] 数组，用于 UI 渲染
    public static func highlightedSegments(
        preview: String,
        matchRanges: [FileContentSearchMatchRange]
    ) -> [(text: String, isHighlighted: Bool)] {
        guard !matchRanges.isEmpty else {
            return [(text: preview, isHighlighted: false)]
        }

        var segments: [(text: String, isHighlighted: Bool)] = []
        let chars = Array(preview)
        var currentIndex = 0

        for range in matchRanges.sorted(by: { $0.start < $1.start }) {
            let start = max(range.start, 0)
            let end = min(range.end, chars.count)
            guard start < end, start >= currentIndex else { continue }

            // 非高亮部分
            if currentIndex < start {
                let text = String(chars[currentIndex..<start])
                segments.append((text: text, isHighlighted: false))
            }

            // 高亮部分
            let text = String(chars[start..<end])
            segments.append((text: text, isHighlighted: true))
            currentIndex = end
        }

        // 剩余部分
        if currentIndex < chars.count {
            let text = String(chars[currentIndex..<chars.count])
            segments.append((text: text, isHighlighted: false))
        }

        return segments
    }
}
