import Foundation

// MARK: - Phase C2-2a: Git Diff Protocol Models

/// Result from git_diff request
public struct GitDiffResult {
    public let project: String
    public let workspace: String
    public let path: String
    public let code: String       // Git status code (M, A, D, etc.)
    public let format: String     // "unified"
    public let text: String       // The actual diff text
    public let isBinary: Bool
    public let truncated: Bool
    public let mode: String       // "working" or "staged"

    public static func from(json: [String: Any]) -> GitDiffResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let path = json["path"] as? String,
              let code = json["code"] as? String,
              let format = json["format"] as? String,
              let text = json["text"] as? String,
              let mode = json["mode"] as? String else {
            return nil
        }
        let isBinary = json["is_binary"] as? Bool ?? false
        let truncated = json["truncated"] as? Bool ?? false
        return GitDiffResult(
            project: project,
            workspace: workspace,
            path: path,
            code: code,
            format: format,
            text: text,
            isBinary: isBinary,
            truncated: truncated,
            mode: mode
        )
    }

    public init(project: String, workspace: String, path: String, code: String, format: String, text: String, isBinary: Bool, truncated: Bool, mode: String) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.code = code
        self.format = format
        self.text = text
        self.isBinary = isBinary
        self.truncated = truncated
        self.mode = mode
    }
}

/// Cached diff for a specific file/mode combination
public struct DiffCache: Equatable {
    public var text: String
    public var parsedLines: [DiffLine]
    public var isLoading: Bool
    public var error: String?
    public var isBinary: Bool
    public var truncated: Bool
    public var code: String       // Git status code
    public var updatedAt: Date

    public static func empty() -> DiffCache {
        DiffCache(
            text: "",
            parsedLines: [],
            isLoading: false,
            error: nil,
            isBinary: false,
            truncated: false,
            code: "",
            updatedAt: .distantPast
        )
    }

    public var isExpired: Bool {
        // Diff cache expires after 30 seconds (more volatile than file index)
        Date().timeIntervalSince(updatedAt) > 30
    }

    public init(text: String, parsedLines: [DiffLine], isLoading: Bool, error: String?, isBinary: Bool, truncated: Bool, code: String, updatedAt: Date) {
        self.text = text
        self.parsedLines = parsedLines
        self.isLoading = isLoading
        self.error = error
        self.isBinary = isBinary
        self.truncated = truncated
        self.code = code
        self.updatedAt = updatedAt
    }
}

/// Parsed diff line model
public struct DiffLine: Identifiable, Equatable {
    public let id: Int  // Line index in the diff
    public let kind: DiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String

    /// Whether this line can be clicked to navigate to editor
    public var isNavigable: Bool {
        switch kind {
        case .context, .add:
            return newLineNumber != nil
        case .del:
            // Deleted lines can navigate to the nearest context
            return newLineNumber != nil
        case .header, .hunk:
            return false
        }
    }

    /// The line number to navigate to in the editor
    public var targetLine: Int? {
        switch kind {
        case .context, .add:
            return newLineNumber
        case .del:
            // For deleted lines, use the new line number (context position)
            return newLineNumber
        case .header, .hunk:
            return nil
        }
    }

    public init(id: Int, kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public enum DiffLineKind: String, Equatable {
    case header   // diff --git, ---, +++
    case hunk     // @@ -x,y +a,b @@
    case context  // ' ' unchanged line
    case add      // '+' added line
    case del      // '-' removed line
}

// MARK: - Phase C2-2b: Split Diff View Mode

public enum DiffViewMode: String, Codable {
    case unified
    case split
}

// MARK: - Phase C2-2b: Split Diff Data Structures

/// A cell in the split diff view (left or right column)
public struct SplitCell {
    public let lineNumber: Int?
    public let text: String
    public let kind: DiffLineKind

    /// Whether this cell can be clicked to navigate
    public var isNavigable: Bool {
        switch kind {
        case .context, .add:
            return lineNumber != nil
        case .del:
            return lineNumber != nil
        case .header, .hunk:
            return false
        }
    }

    public init(lineNumber: Int?, text: String, kind: DiffLineKind) {
        self.lineNumber = lineNumber
        self.text = text
        self.kind = kind
    }
}

/// Row kind for split view layout
public enum SplitRowKind {
    case header      // Full-width header row
    case hunk        // Full-width hunk header row
    case code        // Left/right code columns
}

/// A row in the split diff view
public struct SplitRow: Identifiable {
    public let id: Int
    public let rowKind: SplitRowKind
    public let left: SplitCell?
    public let right: SplitCell?
    public let fullText: String?  // For header/hunk rows

    public init(id: Int, rowKind: SplitRowKind, left: SplitCell?, right: SplitCell?, fullText: String?) {
        self.id = id
        self.rowKind = rowKind
        self.left = left
        self.right = right
        self.fullText = fullText
    }
}

/// Builder to convert unified diff lines to split rows
public struct SplitBuilder {
    /// Maximum lines before split view is disabled
    public static let maxLinesForSplit = 5000

    /// Check if diff is too large for split view
    public static func isTooLargeForSplit(_ lines: [DiffLine]) -> Bool {
        return lines.count > maxLinesForSplit
    }

    /// Convert unified diff lines to split rows
    /// Simple algorithm: no alignment, just place lines in appropriate columns
    public static func build(from lines: [DiffLine]) -> [SplitRow] {
        var rows: [SplitRow] = []
        var rowIndex = 0

        for line in lines {
            switch line.kind {
            case .header:
                // Full-width header row
                rows.append(SplitRow(
                    id: rowIndex,
                    rowKind: .header,
                    left: nil,
                    right: nil,
                    fullText: line.text
                ))
                rowIndex += 1

            case .hunk:
                // Full-width hunk header row
                rows.append(SplitRow(
                    id: rowIndex,
                    rowKind: .hunk,
                    left: nil,
                    right: nil,
                    fullText: line.text
                ))
                rowIndex += 1

            case .context:
                // Context lines appear in both columns
                let leftCell = SplitCell(
                    lineNumber: line.oldLineNumber,
                    text: line.text,
                    kind: .context
                )
                let rightCell = SplitCell(
                    lineNumber: line.newLineNumber,
                    text: line.text,
                    kind: .context
                )
                rows.append(SplitRow(
                    id: rowIndex,
                    rowKind: .code,
                    left: leftCell,
                    right: rightCell,
                    fullText: nil
                ))
                rowIndex += 1

            case .del:
                // Deleted lines only in left column
                let leftCell = SplitCell(
                    lineNumber: line.oldLineNumber,
                    text: line.text,
                    kind: .del
                )
                // Store newLineNumber for navigation (nearest context)
                let rightCell = SplitCell(
                    lineNumber: line.newLineNumber,
                    text: "",
                    kind: .del
                )
                rows.append(SplitRow(
                    id: rowIndex,
                    rowKind: .code,
                    left: leftCell,
                    right: rightCell,
                    fullText: nil
                ))
                rowIndex += 1

            case .add:
                // Added lines only in right column
                let leftCell = SplitCell(
                    lineNumber: nil,
                    text: "",
                    kind: .add
                )
                let rightCell = SplitCell(
                    lineNumber: line.newLineNumber,
                    text: line.text,
                    kind: .add
                )
                rows.append(SplitRow(
                    id: rowIndex,
                    rowKind: .code,
                    left: leftCell,
                    right: rightCell,
                    fullText: nil
                ))
                rowIndex += 1
            }
        }

        return rows
    }
}

// MARK: - Diff Parser

public struct DiffParser {
    /// Parse unified diff text into structured lines
    public static func parse(_ text: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var lineIndex = 0
        var oldLine: Int = 0
        var newLine: Int = 0

        for rawLine in text.components(separatedBy: "\n") {
            let diffLine: DiffLine

            if rawLine.hasPrefix("diff --git") || rawLine.hasPrefix("---") || rawLine.hasPrefix("+++") ||
               rawLine.hasPrefix("index ") || rawLine.hasPrefix("new file") || rawLine.hasPrefix("deleted file") {
                // Header lines
                diffLine = DiffLine(
                    id: lineIndex,
                    kind: .header,
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    text: rawLine
                )
            } else if rawLine.hasPrefix("@@") {
                // Hunk header: @@ -oldStart,oldLen +newStart,newLen @@
                let (oldStart, newStart) = parseHunkHeader(rawLine)
                oldLine = oldStart
                newLine = newStart
                diffLine = DiffLine(
                    id: lineIndex,
                    kind: .hunk,
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    text: rawLine
                )
            } else if rawLine.hasPrefix("+") {
                // Added line
                diffLine = DiffLine(
                    id: lineIndex,
                    kind: .add,
                    oldLineNumber: nil,
                    newLineNumber: newLine,
                    text: String(rawLine.dropFirst())
                )
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                // Removed line
                diffLine = DiffLine(
                    id: lineIndex,
                    kind: .del,
                    oldLineNumber: oldLine,
                    newLineNumber: newLine > 0 ? newLine : nil,
                    text: String(rawLine.dropFirst())
                )
                oldLine += 1
            } else if rawLine.hasPrefix(" ") || (!rawLine.isEmpty && !rawLine.hasPrefix("\\")) {
                // Context line (or line without prefix in some edge cases)
                let displayText = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
                diffLine = DiffLine(
                    id: lineIndex,
                    kind: .context,
                    oldLineNumber: oldLine,
                    newLineNumber: newLine,
                    text: displayText
                )
                oldLine += 1
                newLine += 1
            } else {
                // Other lines (like "\ No newline at end of file")
                diffLine = DiffLine(
                    id: lineIndex,
                    kind: .header,
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    text: rawLine
                )
            }

            lines.append(diffLine)
            lineIndex += 1
        }

        return lines
    }

    /// Parse hunk header to extract starting line numbers
    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int) {
        // Format: @@ -oldStart,oldLen +newStart,newLen @@ optional context
        let pattern = #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return (1, 1)
        }

        let oldStart = Int(line[Range(match.range(at: 1), in: line)!]) ?? 1
        let newStart = Int(line[Range(match.range(at: 2), in: line)!]) ?? 1
        return (oldStart, newStart)
    }
}

// MARK: - Phase C3-1: Git Status Protocol Models

/// Single item in git status list
public struct GitStatusItem: Identifiable, Equatable, Sendable {
    public let id: String  // Use path as unique ID
    public let path: String
    public let status: String  // M, A, D, ??, R, C, etc.
    public let staged: Bool?   // If core provides staged info
    public let renameFrom: String?  // For renamed files
    public let additions: Int?   // 新增行数
    public let deletions: Int?   // 删除行数

    /// Human-readable status description
    public var statusDescription: String {
        switch status {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "??": return "Untracked"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "U": return "Unmerged"
        case "!": return "Ignored"
        default: return status
        }
    }

    /// Color for status badge
    public var statusColor: String {
        switch status {
        case "M": return "orange"
        case "A": return "green"
        case "D": return "red"
        case "??": return "gray"
        case "R": return "blue"
        case "C": return "cyan"
        case "U": return "purple"
        default: return "secondary"
        }
    }

    public init(id: String, path: String, status: String, staged: Bool?, renameFrom: String?, additions: Int?, deletions: Int?) {
        self.id = id
        self.path = path
        self.status = status
        self.staged = staged
        self.renameFrom = renameFrom
        self.additions = additions
        self.deletions = deletions
    }
}

/// Result from git_status request
public struct GitStatusResult {
    public let project: String
    public let workspace: String
    public let items: [GitStatusItem]
    public let isGitRepo: Bool
    public let error: String?
    public let hasStagedChanges: Bool
    public let stagedCount: Int
    public let currentBranch: String?
    public let defaultBranch: String?
    public let aheadBy: Int?
    public let behindBy: Int?
    public let comparedBranch: String?

    public static func from(json: [String: Any]) -> GitStatusResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String else {
            return nil
        }

        let isGitRepo = json["is_git_repo"] as? Bool ?? true
        let errorMsg = json["error"] as? String
        let hasStagedChanges = json["has_staged_changes"] as? Bool ?? false
        let stagedCount = json["staged_count"] as? Int ?? 0
        let currentBranch = json["current_branch"] as? String
        let defaultBranch = json["default_branch"] as? String
        let aheadBy = json["ahead_by"] as? Int
        let behindBy = json["behind_by"] as? Int
        let comparedBranch = json["compared_branch"] as? String

        var items: [GitStatusItem] = []
        if let itemsArray = json["items"] as? [[String: Any]] {
            for itemJson in itemsArray {
                if let path = itemJson["path"] as? String,
                   let status = itemJson["status"] as? String {
                    let staged = itemJson["staged"] as? Bool
                    let renameFrom = itemJson["rename_from"] as? String
                    let additions = itemJson["additions"] as? Int
                    let deletions = itemJson["deletions"] as? Int
                    items.append(GitStatusItem(
                        id: path,
                        path: path,
                        status: status,
                        staged: staged,
                        renameFrom: renameFrom,
                        additions: additions,
                        deletions: deletions
                    ))
                }
            }
        }

        return GitStatusResult(
            project: project,
            workspace: workspace,
            items: items,
            isGitRepo: isGitRepo,
            error: errorMsg,
            hasStagedChanges: hasStagedChanges,
            stagedCount: stagedCount,
            currentBranch: currentBranch,
            defaultBranch: defaultBranch,
            aheadBy: aheadBy,
            behindBy: behindBy,
            comparedBranch: comparedBranch
        )
    }

    public init(project: String, workspace: String, items: [GitStatusItem], isGitRepo: Bool, error: String?, hasStagedChanges: Bool, stagedCount: Int, currentBranch: String?, defaultBranch: String?, aheadBy: Int?, behindBy: Int?, comparedBranch: String?) {
        self.project = project
        self.workspace = workspace
        self.items = items
        self.isGitRepo = isGitRepo
        self.error = error
        self.hasStagedChanges = hasStagedChanges
        self.stagedCount = stagedCount
        self.currentBranch = currentBranch
        self.defaultBranch = defaultBranch
        self.aheadBy = aheadBy
        self.behindBy = behindBy
        self.comparedBranch = comparedBranch
    }
}

/// Cached git status for a workspace
public struct GitStatusCache: Equatable {
    public var items: [GitStatusItem]
    /// 预计算的暂存文件列表，避免视图层每次重绘都 filter
    public var stagedItems: [GitStatusItem]
    /// 预计算的未暂存文件列表
    public var unstagedItems: [GitStatusItem]
    public var isLoading: Bool
    public var error: String?
    public var isGitRepo: Bool
    public var updatedAt: Date
    public var hasStagedChanges: Bool
    public var stagedCount: Int
    public var currentBranch: String?
    public var defaultBranch: String?
    public var aheadBy: Int?
    public var behindBy: Int?
    public var comparedBranch: String?

    /// 从 items 构建缓存，自动拆分 staged/unstaged
    public init(items: [GitStatusItem], isLoading: Bool, error: String?, isGitRepo: Bool,
         updatedAt: Date, hasStagedChanges: Bool, stagedCount: Int,
         currentBranch: String?, defaultBranch: String?,
         aheadBy: Int?, behindBy: Int?, comparedBranch: String?) {
        self.items = items
        self.stagedItems = items.filter { $0.staged == true }
        self.unstagedItems = items.filter { $0.staged != true }
        self.isLoading = isLoading
        self.error = error
        self.isGitRepo = isGitRepo
        self.updatedAt = updatedAt
        self.hasStagedChanges = hasStagedChanges
        self.stagedCount = stagedCount
        self.currentBranch = currentBranch
        self.defaultBranch = defaultBranch
        self.aheadBy = aheadBy
        self.behindBy = behindBy
        self.comparedBranch = comparedBranch
    }

    public static func empty() -> GitStatusCache {
        GitStatusCache(
            items: [],
            isLoading: false,
            error: nil,
            isGitRepo: true,
            updatedAt: .distantPast,
            hasStagedChanges: false,
            stagedCount: 0,
            currentBranch: nil,
            defaultBranch: nil,
            aheadBy: nil,
            behindBy: nil,
            comparedBranch: nil
        )
    }

    public var isExpired: Bool {
        // Git status cache expires after 60 seconds
        Date().timeIntervalSince(updatedAt) > 60
    }

    /// 产出统一的 Git 面板语义快照，供 macOS/iOS 视图层无差别消费
    public var semanticSnapshot: GitPanelSemanticSnapshot {
        GitPanelSemanticSnapshot(
            stagedItems: stagedItems,
            trackedUnstagedItems: unstagedItems.filter { $0.status != "??" },
            untrackedItems: unstagedItems.filter { $0.status == "??" },
            isGitRepo: isGitRepo,
            isLoading: isLoading,
            currentBranch: currentBranch,
            defaultBranch: defaultBranch,
            aheadBy: aheadBy,
            behindBy: behindBy
        )
    }
}

// MARK: - Git 面板语义快照（macOS/iOS 共享）

/// 从 GitStatusCache 或 MobileWorkspaceGitDetailState 提炼出的统一展示语义。
/// 作为 macOS 与 iOS Git 面板的单一展示入口，消除两端重复的 status 字符串判断逻辑。
public struct GitPanelSemanticSnapshot: Equatable, Sendable {
    /// 已暂存的文件列表
    public let stagedItems: [GitStatusItem]
    /// 未暂存的已跟踪文件（status != "??"）
    public let trackedUnstagedItems: [GitStatusItem]
    /// 未跟踪文件（status == "??"）
    public let untrackedItems: [GitStatusItem]
    public let isGitRepo: Bool
    public let isLoading: Bool
    public let currentBranch: String?
    public let defaultBranch: String?
    public let aheadBy: Int?
    public let behindBy: Int?

    // MARK: - 派生属性

    public var hasStagedChanges: Bool { !stagedItems.isEmpty }
    public var hasTrackedChanges: Bool { !trackedUnstagedItems.isEmpty }
    public var hasUntrackedChanges: Bool { !untrackedItems.isEmpty }

    /// 所有未暂存文件（已跟踪 + 未跟踪），保留与 macOS/iOS 现有 API 兼容
    public var unstagedItems: [GitStatusItem] { trackedUnstagedItems + untrackedItems }

    /// 无 staged、无已跟踪更改、无未跟踪文件
    public var isEmpty: Bool {
        stagedItems.isEmpty && trackedUnstagedItems.isEmpty && untrackedItems.isEmpty
    }

    /// 所有变更文件（staged + unstaged）的 additions 汇总，macOS 与 iOS 共享同一计算路径
    public var totalAdditions: Int {
        (stagedItems + unstagedItems).reduce(0) { $0 + ($1.additions ?? 0) }
    }

    /// 所有变更文件（staged + unstaged）的 deletions 汇总，macOS 与 iOS 共享同一计算路径
    public var totalDeletions: Int {
        (stagedItems + unstagedItems).reduce(0) { $0 + ($1.deletions ?? 0) }
    }

    // MARK: - 分支 divergence 文案（macOS/iOS 共享格式）

    /// 产出分支差异展示文案，由 macOS 与 iOS 共享相同的格式化规则
    public var branchDivergenceText: String {
        GitPanelSemanticSnapshot.formatBranchDivergence(
            defaultBranch: defaultBranch,
            aheadBy: aheadBy,
            behindBy: behindBy,
            isLoading: isLoading
        )
    }

    /// 静态格式化方法，便于在单测中独立验证，不依赖实例状态
    public static func formatBranchDivergence(
        defaultBranch: String?,
        aheadBy: Int?,
        behindBy: Int?,
        isLoading: Bool
    ) -> String {
        if let base = defaultBranch,
           let ahead = aheadBy,
           let behind = behindBy {
            let branchPair = String(format: "%@ vs default", base)
            if ahead == 0 && behind == 0 {
                return "\(branchPair) | Up to date"
            }
            let aheadText = String(format: "+%d", ahead)
            let behindText = String(format: "-%d", behind)
            return "\(branchPair) | \(aheadText) | \(behindText)"
        }
        if isLoading {
            return "Loading…"
        }
        return "Unavailable"
    }

    public static func empty() -> GitPanelSemanticSnapshot {
        GitPanelSemanticSnapshot(
            stagedItems: [],
            trackedUnstagedItems: [],
            untrackedItems: [],
            isGitRepo: false,
            isLoading: false,
            currentBranch: nil,
            defaultBranch: nil,
            aheadBy: nil,
            behindBy: nil
        )
    }

    public init(stagedItems: [GitStatusItem], trackedUnstagedItems: [GitStatusItem], untrackedItems: [GitStatusItem], isGitRepo: Bool, isLoading: Bool, currentBranch: String?, defaultBranch: String?, aheadBy: Int?, behindBy: Int?) {
        self.stagedItems = stagedItems
        self.trackedUnstagedItems = trackedUnstagedItems
        self.untrackedItems = untrackedItems
        self.isGitRepo = isGitRepo
        self.isLoading = isLoading
        self.currentBranch = currentBranch
        self.defaultBranch = defaultBranch
        self.aheadBy = aheadBy
        self.behindBy = behindBy
    }
}

// MARK: - Git Log (Commit History) Protocol Models

/// 单条提交记录
public struct GitLogEntry: Identifiable, Equatable {
    public let id: String       // 使用 sha 作为 ID
    public let sha: String      // 短 SHA (7字符)
    public let message: String  // 提交消息（首行）
    public let author: String   // 作者名
    public let date: String     // ISO 日期
    public let refs: [String]   // HEAD, branch, tag 等引用
    
    /// 格式化的相对时间
    public var relativeDate: String {
        // 解析 ISO 日期并转换为相对时间
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        // 尝试多种格式
        if let parsedDate = formatter.date(from: date) {
            return formatRelativeDate(parsedDate)
        }
        
        // 尝试不带小数秒的格式
        formatter.formatOptions = [.withInternetDateTime]
        if let parsedDate = formatter.date(from: date) {
            return formatRelativeDate(parsedDate)
        }
        
        return date
    }
    
    private func formatRelativeDate(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return String(format: "%d min ago", minutes)
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return String(format: "%d hr ago", hours)
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return String(format: "%d days ago", days)
        } else if interval < 2592000 {
            let weeks = Int(interval / 604800)
            return String(format: "%d wks ago", weeks)
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            return dateFormatter.string(from: date)
        }
    }

    public init(id: String, sha: String, message: String, author: String, date: String, refs: [String]) {
        self.id = id
        self.sha = sha
        self.message = message
        self.author = author
        self.date = date
        self.refs = refs
    }
}

/// git_log 请求的响应结果
public struct GitLogResult {
    public let project: String
    public let workspace: String
    public let entries: [GitLogEntry]
    
    public static func from(json: [String: Any]) -> GitLogResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String else {
            return nil
        }
        
        var entries: [GitLogEntry] = []
        if let entriesArray = json["entries"] as? [[String: Any]] {
            for entryJson in entriesArray {
                if let sha = entryJson["sha"] as? String,
                   let message = entryJson["message"] as? String,
                   let author = entryJson["author"] as? String,
                   let date = entryJson["date"] as? String {
                    let refs = entryJson["refs"] as? [String] ?? []
                    entries.append(GitLogEntry(
                        id: sha,
                        sha: sha,
                        message: message,
                        author: author,
                        date: date,
                        refs: refs
                    ))
                }
            }
        }
        
        return GitLogResult(
            project: project,
            workspace: workspace,
            entries: entries
        )
    }

    public init(project: String, workspace: String, entries: [GitLogEntry]) {
        self.project = project
        self.workspace = workspace
        self.entries = entries
    }
}

/// Git 日志缓存
public struct GitLogCache: Equatable {
    public var entries: [GitLogEntry]
    public var isLoading: Bool
    public var error: String?
    public var updatedAt: Date
    
    public static func empty() -> GitLogCache {
        GitLogCache(
            entries: [],
            isLoading: false,
            error: nil,
            updatedAt: .distantPast
        )
    }
    
    public var isExpired: Bool {
        // Git log cache 过期时间：5 分钟
        Date().timeIntervalSince(updatedAt) > 300
    }

    public init(entries: [GitLogEntry], isLoading: Bool, error: String?, updatedAt: Date) {
        self.entries = entries
        self.isLoading = isLoading
        self.error = error
        self.updatedAt = updatedAt
    }
}

// MARK: - Git Show (单个 commit 详情)

/// Git show 文件变更条目
public struct GitShowFileEntry: Identifiable {
    public var id: String { path }
    public let status: String      // "M", "A", "D", "R" 等
    public let path: String
    public let oldPath: String?    // 重命名时的原路径

    public init(status: String, path: String, oldPath: String?) {
        self.status = status
        self.path = path
        self.oldPath = oldPath
    }
}

/// Git show 结果（单个 commit 详情）
public struct GitShowResult {
    public let project: String
    public let workspace: String
    public let sha: String
    public let fullSha: String
    public let message: String     // 完整提交消息
    public let author: String
    public let authorEmail: String
    public let date: String
    public let files: [GitShowFileEntry]
    
    public static func from(json: [String: Any]) -> GitShowResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let sha = json["sha"] as? String,
              let fullSha = json["full_sha"] as? String,
              let message = json["message"] as? String,
              let author = json["author"] as? String,
              let authorEmail = json["author_email"] as? String,
              let date = json["date"] as? String else {
            return nil
        }
        
        var files: [GitShowFileEntry] = []
        if let filesArray = json["files"] as? [[String: Any]] {
            for fileJson in filesArray {
                if let status = fileJson["status"] as? String,
                   let path = fileJson["path"] as? String {
                    let oldPath = fileJson["old_path"] as? String
                    files.append(GitShowFileEntry(
                        status: status,
                        path: path,
                        oldPath: oldPath
                    ))
                }
            }
        }
        
        return GitShowResult(
            project: project,
            workspace: workspace,
            sha: sha,
            fullSha: fullSha,
            message: message,
            author: author,
            authorEmail: authorEmail,
            date: date,
            files: files
        )
    }

    public init(project: String, workspace: String, sha: String, fullSha: String, message: String, author: String, authorEmail: String, date: String, files: [GitShowFileEntry]) {
        self.project = project
        self.workspace = workspace
        self.sha = sha
        self.fullSha = fullSha
        self.message = message
        self.author = author
        self.authorEmail = authorEmail
        self.date = date
        self.files = files
    }
}

/// Git show 缓存（按 SHA 索引）
public struct GitShowCache {
    public var result: GitShowResult?
    public var isLoading: Bool
    public var error: String?

    public init(result: GitShowResult?, isLoading: Bool, error: String?) {
        self.result = result
        self.isLoading = isLoading
        self.error = error
    }
}

// MARK: - Phase C3-2a: Git Stage/Unstage Protocol Models

/// Result from git_stage or git_unstage request
public struct GitOpResult {
    public let project: String
    public let workspace: String
    public let op: String       // "stage" or "unstage"
    public let ok: Bool
    public let message: String?
    public let path: String?
    public let scope: String    // "file" or "all"

    public static func from(json: [String: Any]) -> GitOpResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let op = json["op"] as? String,
              let ok = json["ok"] as? Bool,
              let scope = json["scope"] as? String else {
            return nil
        }
        let message = json["message"] as? String
        let path = json["path"] as? String
        return GitOpResult(
            project: project,
            workspace: workspace,
            op: op,
            ok: ok,
            message: message,
            path: path,
            scope: scope
        )
    }

    public init(project: String, workspace: String, op: String, ok: Bool, message: String?, path: String?, scope: String) {
        self.project = project
        self.workspace = workspace
        self.op = op
        self.ok = ok
        self.message = message
        self.path = path
        self.scope = scope
    }
}

/// Track in-flight git operations
public struct GitOpInFlight: Equatable, Hashable {
    public let op: String       // "stage", "unstage", "discard", or "switch_branch"
    public let path: String?    // nil for "all" scope
    public let scope: String    // "file", "all", or "branch"

    public init(op: String, path: String?, scope: String) {
        self.op = op
        self.path = path
        self.scope = scope
    }
}

// MARK: - Phase C3-3a: Git Branch Protocol Models

/// Single branch info
public struct GitBranchItem: Identifiable {
    public let id: String  // Use name as unique ID
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Result from git_branches request
public struct GitBranchesResult {
    public let project: String
    public let workspace: String
    public let current: String
    public let branches: [GitBranchItem]

    public static func from(json: [String: Any]) -> GitBranchesResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let current = json["current"] as? String else {
            return nil
        }

        var branches: [GitBranchItem] = []
        if let branchesArray = json["branches"] as? [[String: Any]] {
            for branchJson in branchesArray {
                if let name = branchJson["name"] as? String {
                    branches.append(GitBranchItem(id: name, name: name))
                }
            }
        }

        return GitBranchesResult(
            project: project,
            workspace: workspace,
            current: current,
            branches: branches
        )
    }

    public init(project: String, workspace: String, current: String, branches: [GitBranchItem]) {
        self.project = project
        self.workspace = workspace
        self.current = current
        self.branches = branches
    }
}

/// Cached git branches for a workspace
public struct GitBranchCache {
    public var current: String
    public var branches: [GitBranchItem]
    public var isLoading: Bool
    public var error: String?
    public var updatedAt: Date

    public static func empty() -> GitBranchCache {
        GitBranchCache(
            current: "",
            branches: [],
            isLoading: false,
            error: nil,
            updatedAt: .distantPast
        )
    }

    public init(current: String, branches: [GitBranchItem], isLoading: Bool, error: String?, updatedAt: Date) {
        self.current = current
        self.branches = branches
        self.isLoading = isLoading
        self.error = error
        self.updatedAt = updatedAt
    }
}

// MARK: - Phase C3-4a: Git Commit Protocol Models

/// Result from git_commit request
public struct GitCommitResult {
    public let project: String
    public let workspace: String
    public let ok: Bool
    public let message: String?
    public let sha: String?

    public static func from(json: [String: Any]) -> GitCommitResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let ok = json["ok"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        let sha = json["sha"] as? String
        return GitCommitResult(
            project: project,
            workspace: workspace,
            ok: ok,
            message: message,
            sha: sha
        )
    }

    public init(project: String, workspace: String, ok: Bool, message: String?, sha: String?) {
        self.project = project
        self.workspace = workspace
        self.ok = ok
        self.message = message
        self.sha = sha
    }
}

// MARK: - Phase UX-3a: Git Rebase Protocol Models

/// Git operation state enum
public enum GitOpState: String {
    case normal = "normal"
    case rebasing = "rebasing"
    case merging = "merging"

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .rebasing: return "Rebasing"
        case .merging: return "Merging"
        }
    }
}

/// Result from git_rebase request
public struct GitRebaseResult {
    public let project: String
    public let workspace: String
    public let ok: Bool
    public let state: String  // "completed", "conflict", "aborted", "error"
    public let message: String?
    public let conflicts: [String]
    /// 语义化冲突文件列表（v1.40+）
    public let conflictFiles: [ConflictFileEntry]

    public static func from(json: [String: Any]) -> GitRebaseResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let ok = json["ok"] as? Bool,
              let state = json["state"] as? String else {
            return nil
        }
        let message = json["message"] as? String
        let conflicts = json["conflicts"] as? [String] ?? []
        let conflictFiles = ConflictFileEntry.listFrom(json: json["conflict_files"])
        return GitRebaseResult(
            project: project,
            workspace: workspace,
            ok: ok,
            state: state,
            message: message,
            conflicts: conflicts,
            conflictFiles: conflictFiles
        )
    }

    public init(project: String, workspace: String, ok: Bool, state: String, message: String?, conflicts: [String], conflictFiles: [ConflictFileEntry] = []) {
        self.project = project
        self.workspace = workspace
        self.ok = ok
        self.state = state
        self.message = message
        self.conflicts = conflicts
        self.conflictFiles = conflictFiles
    }
}

/// Result from git_op_status request
public struct GitOpStatusResult {
    public let project: String
    public let workspace: String
    public let state: GitOpState
    public let conflicts: [String]
    /// 语义化冲突文件列表（v1.40+）
    public let conflictFiles: [ConflictFileEntry]
    public let head: String?
    public let onto: String?

    public static func from(json: [String: Any]) -> GitOpStatusResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let stateStr = json["state"] as? String else {
            return nil
        }
        let state = GitOpState(rawValue: stateStr) ?? .normal
        let conflicts = json["conflicts"] as? [String] ?? []
        let conflictFiles = ConflictFileEntry.listFrom(json: json["conflict_files"])
        let head = json["head"] as? String
        let onto = json["onto"] as? String
        return GitOpStatusResult(
            project: project,
            workspace: workspace,
            state: state,
            conflicts: conflicts,
            conflictFiles: conflictFiles,
            head: head,
            onto: onto
        )
    }

    public init(project: String, workspace: String, state: GitOpState, conflicts: [String], conflictFiles: [ConflictFileEntry] = [], head: String?, onto: String?) {
        self.project = project
        self.workspace = workspace
        self.state = state
        self.conflicts = conflicts
        self.conflictFiles = conflictFiles
        self.head = head
        self.onto = onto
    }
}

/// Cached git operation status for a workspace
public struct GitOpStatusCache {
    public var state: GitOpState
    public var conflicts: [String]
    /// 语义化冲突文件列表（v1.40+）
    public var conflictFiles: [ConflictFileEntry]
    public var isLoading: Bool
    public var updatedAt: Date

    public static func empty() -> GitOpStatusCache {
        GitOpStatusCache(
            state: .normal,
            conflicts: [],
            conflictFiles: [],
            isLoading: false,
            updatedAt: .distantPast
        )
    }

    public init(state: GitOpState, conflicts: [String], conflictFiles: [ConflictFileEntry] = [], isLoading: Bool, updatedAt: Date) {
        self.state = state
        self.conflicts = conflicts
        self.conflictFiles = conflictFiles
        self.isLoading = isLoading
        self.updatedAt = updatedAt
    }
}

// MARK: - Phase UX-3b: Git Merge Integration Protocol Models

/// Integration worktree state enum
public enum IntegrationState: String {
    case idle = "idle"
    case merging = "merging"
    case conflict = "conflict"
    case completed = "completed"
    case failed = "failed"
    // UX-4: Rebase states
    case rebasing = "rebasing"
    case rebaseConflict = "rebase_conflict"

    public var displayName: String {
        switch self {
        case .idle: return "Ready"
        case .merging: return "Merging"
        case .conflict: return "Merge Conflict"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .rebasing: return "Rebasing"
        case .rebaseConflict: return "Rebase Conflict"
        }
    }

    /// UX-4: Check if this is a rebase-related state
    public var isRebaseState: Bool {
        switch self {
        case .rebasing, .rebaseConflict: return true
        default: return false
        }
    }

    /// UX-4: Check if this is a merge-related state
    public var isMergeState: Bool {
        switch self {
        case .merging, .conflict: return true
        default: return false
        }
    }
}

/// Result from git_merge_to_default request
public struct GitMergeToDefaultResult {
    public let project: String
    public let ok: Bool
    public let state: IntegrationState
    public let message: String?
    public let conflicts: [String]
    /// 语义化冲突文件列表（v1.40+）
    public let conflictFiles: [ConflictFileEntry]
    public let headSha: String?
    public let integrationPath: String?

    public static func from(json: [String: Any]) -> GitMergeToDefaultResult? {
        guard let project = json["project"] as? String,
              let ok = json["ok"] as? Bool,
              let stateStr = json["state"] as? String else {
            return nil
        }
        let state = IntegrationState(rawValue: stateStr) ?? .failed
        let message = json["message"] as? String
        let conflicts = json["conflicts"] as? [String] ?? []
        let conflictFiles = ConflictFileEntry.listFrom(json: json["conflict_files"])
        let headSha = json["head_sha"] as? String
        let integrationPath = json["integration_path"] as? String
        return GitMergeToDefaultResult(
            project: project,
            ok: ok,
            state: state,
            message: message,
            conflicts: conflicts,
            conflictFiles: conflictFiles,
            headSha: headSha,
            integrationPath: integrationPath
        )
    }

    public init(project: String, ok: Bool, state: IntegrationState, message: String?, conflicts: [String], conflictFiles: [ConflictFileEntry] = [], headSha: String?, integrationPath: String?) {
        self.project = project
        self.ok = ok
        self.state = state
        self.message = message
        self.conflicts = conflicts
        self.conflictFiles = conflictFiles
        self.headSha = headSha
        self.integrationPath = integrationPath
    }
}

/// Result from git_integration_status request
public struct GitIntegrationStatusResult {
    public let project: String
    public let state: IntegrationState
    public let conflicts: [String]
    /// 语义化冲突文件列表（v1.40+）
    public let conflictFiles: [ConflictFileEntry]
    public let head: String?
    public let defaultBranch: String
    public let path: String
    public let isClean: Bool
    // UX-6: Branch divergence fields
    public let branchAheadBy: Int?
    public let branchBehindBy: Int?
    public let comparedBranch: String?

    public static func from(json: [String: Any]) -> GitIntegrationStatusResult? {
        guard let project = json["project"] as? String,
              let stateStr = json["state"] as? String,
              let defaultBranch = json["default_branch"] as? String,
              let path = json["path"] as? String,
              let isClean = json["is_clean"] as? Bool else {
            return nil
        }
        let state = IntegrationState(rawValue: stateStr) ?? .idle
        let conflicts = json["conflicts"] as? [String] ?? []
        let conflictFiles = ConflictFileEntry.listFrom(json: json["conflict_files"])
        let head = json["head"] as? String
        // UX-6: Parse branch divergence fields
        let branchAheadBy = json["branch_ahead_by"] as? Int
        let branchBehindBy = json["branch_behind_by"] as? Int
        let comparedBranch = json["compared_branch"] as? String
        return GitIntegrationStatusResult(
            project: project,
            state: state,
            conflicts: conflicts,
            conflictFiles: conflictFiles,
            head: head,
            defaultBranch: defaultBranch,
            path: path,
            isClean: isClean,
            branchAheadBy: branchAheadBy,
            branchBehindBy: branchBehindBy,
            comparedBranch: comparedBranch
        )
    }

    public init(project: String, state: IntegrationState, conflicts: [String], conflictFiles: [ConflictFileEntry] = [], head: String?, defaultBranch: String, path: String, isClean: Bool, branchAheadBy: Int?, branchBehindBy: Int?, comparedBranch: String?) {
        self.project = project
        self.state = state
        self.conflicts = conflicts
        self.conflictFiles = conflictFiles
        self.head = head
        self.defaultBranch = defaultBranch
        self.path = path
        self.isClean = isClean
        self.branchAheadBy = branchAheadBy
        self.branchBehindBy = branchBehindBy
        self.comparedBranch = comparedBranch
    }
}

/// Cached integration status for a project
public struct GitIntegrationStatusCache {
    public var state: IntegrationState
    public var conflicts: [String]
    /// 语义化冲突文件列表（v1.40+）
    public var conflictFiles: [ConflictFileEntry]
    public var isLoading: Bool
    public var updatedAt: Date
    public var integrationPath: String?
    public var defaultBranch: String
    // UX-6: Branch divergence fields
    public var branchAheadBy: Int?
    public var branchBehindBy: Int?
    public var comparedBranch: String?

    public static func empty() -> GitIntegrationStatusCache {
        GitIntegrationStatusCache(
            state: .idle,
            conflicts: [],
            conflictFiles: [],
            isLoading: false,
            updatedAt: .distantPast,
            integrationPath: nil,
            defaultBranch: "main",
            branchAheadBy: nil,
            branchBehindBy: nil,
            comparedBranch: nil
        )
    }

    public init(state: IntegrationState, conflicts: [String], conflictFiles: [ConflictFileEntry] = [], isLoading: Bool, updatedAt: Date, integrationPath: String?, defaultBranch: String, branchAheadBy: Int?, branchBehindBy: Int?, comparedBranch: String?) {
        self.state = state
        self.conflicts = conflicts
        self.conflictFiles = conflictFiles
        self.isLoading = isLoading
        self.updatedAt = updatedAt
        self.integrationPath = integrationPath
        self.defaultBranch = defaultBranch
        self.branchAheadBy = branchAheadBy
        self.branchBehindBy = branchBehindBy
        self.comparedBranch = comparedBranch
    }
}

// MARK: - Phase UX-4: Git Rebase onto Default Protocol Models

/// Result from git_rebase_onto_default request
public struct GitRebaseOntoDefaultResult {
    public let project: String
    public let ok: Bool
    public let state: IntegrationState
    public let message: String?
    public let conflicts: [String]
    /// 语义化冲突文件列表（v1.40+）
    public let conflictFiles: [ConflictFileEntry]
    public let headSha: String?
    public let integrationPath: String?

    public static func from(json: [String: Any]) -> GitRebaseOntoDefaultResult? {
        guard let project = json["project"] as? String,
              let ok = json["ok"] as? Bool,
              let stateStr = json["state"] as? String else {
            return nil
        }
        let state = IntegrationState(rawValue: stateStr) ?? .failed
        let message = json["message"] as? String
        let conflicts = json["conflicts"] as? [String] ?? []
        let conflictFiles = ConflictFileEntry.listFrom(json: json["conflict_files"])
        let headSha = json["head_sha"] as? String
        let integrationPath = json["integration_path"] as? String
        return GitRebaseOntoDefaultResult(
            project: project,
            ok: ok,
            state: state,
            message: message,
            conflicts: conflicts,
            conflictFiles: conflictFiles,
            headSha: headSha,
            integrationPath: integrationPath
        )
    }

    public init(project: String, ok: Bool, state: IntegrationState, message: String?, conflicts: [String], conflictFiles: [ConflictFileEntry] = [], headSha: String?, integrationPath: String?) {
        self.project = project
        self.ok = ok
        self.state = state
        self.message = message
        self.conflicts = conflicts
        self.conflictFiles = conflictFiles
        self.headSha = headSha
        self.integrationPath = integrationPath
    }
}

// MARK: - Phase UX-5: Git Reset Integration Worktree Protocol Models

/// Result from git_reset_integration_worktree request
public struct GitResetIntegrationWorktreeResult {
    public let project: String
    public let ok: Bool
    public let message: String?
    public let path: String?

    public static func from(json: [String: Any]) -> GitResetIntegrationWorktreeResult? {
        guard let project = json["project"] as? String,
              let ok = json["ok"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        let path = json["path"] as? String
        return GitResetIntegrationWorktreeResult(
            project: project,
            ok: ok,
            message: message,
            path: path
        )
    }

    public init(project: String, ok: Bool, message: String?, path: String?) {
        self.project = project
        self.ok = ok
        self.message = message
        self.path = path
    }
}

// MARK: - AI Git Commit Models

/// AI Git commit 信息
public struct AIGitCommit {
    public let sha: String
    public let message: String
    public let files: [String]

    public static func from(json: [String: Any]) -> AIGitCommit? {
        guard let sha = json["sha"] as? String,
              let message = json["message"] as? String,
              let files = json["files"] as? [String] else {
            return nil
        }
        return AIGitCommit(sha: sha, message: message, files: files)
    }

    public init(sha: String, message: String, files: [String]) {
        self.sha = sha
        self.message = message
        self.files = files
    }
}

/// Evolution AutoCommit 结果
public struct EvoAutoCommitResult {
    public let project: String
    public let workspace: String
    public let success: Bool
    public let message: String
    public let commits: [AIGitCommit]

    public static func from(json: [String: Any]) -> EvoAutoCommitResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let success = json["success"] as? Bool,
              let message = json["message"] as? String,
              let commitsArray = json["commits"] as? [[String: Any]] else {
            return nil
        }
        let commits = commitsArray.compactMap { AIGitCommit.from(json: $0) }
        return EvoAutoCommitResult(project: project, workspace: workspace, success: success, message: message, commits: commits)
    }

    public init(project: String, workspace: String, success: Bool, message: String, commits: [AIGitCommit]) {
        self.project = project
        self.workspace = workspace
        self.success = success
        self.message = message
        self.commits = commits
    }
}

/// AI Git 合并结果（v1.33）
public struct GitAIMergeResult {
    public let project: String
    public let workspace: String
    public let success: Bool
    public let message: String
    public let conflicts: [String]

    public static func from(json: [String: Any]) -> GitAIMergeResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let success = json["success"] as? Bool,
              let message = json["message"] as? String else {
            return nil
        }
        let conflicts = json["conflicts"] as? [String] ?? []
        return GitAIMergeResult(project: project, workspace: workspace, success: success, message: message, conflicts: conflicts)
    }

    public init(project: String, workspace: String, success: Bool, message: String, conflicts: [String]) {
        self.project = project
        self.workspace = workspace
        self.success = success
        self.message = message
        self.conflicts = conflicts
    }
}

// MARK: - v1.37: AI 任务取消确认

/// AI 任务取消确认
public struct AITaskCancelled {
    public let project: String
    public let workspace: String
    public let operationType: String

    public static func from(json: [String: Any]) -> AITaskCancelled? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let operationType = json["operation_type"] as? String else {
            return nil
        }
        return AITaskCancelled(project: project, workspace: workspace, operationType: operationType)
    }

    public init(project: String, workspace: String, operationType: String) {
        self.project = project
        self.workspace = workspace
        self.operationType = operationType
    }
}

/// 任务快照条目（iOS 重连恢复用）
public struct TaskSnapshotEntry {
    public let taskId: String
    public let project: String
    public let workspace: String
    public let taskType: String
    public let commandId: String?
    public let title: String
    public let status: String
    public let message: String?
    public let startedAt: Int64
    public let completedAt: Int64?
    /// 运行耗时（毫秒），由 Core 权威输出
    public let durationMs: UInt64?
    /// 失败诊断码（仅 status=failed 时填充）
    public let errorCode: String?
    /// 失败诊断详情（仅 status=failed 时填充）
    public let errorDetail: String?
    /// 是否可安全重试（Core 判定）
    public let retryable: Bool

    public static func from(json: [String: Any]) -> TaskSnapshotEntry? {
        guard let taskId = json["task_id"] as? String,
              let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let taskType = json["task_type"] as? String,
              let title = json["title"] as? String,
              let status = json["status"] as? String,
              let startedAt = json["started_at"] as? Int64 else {
            return nil
        }
        return TaskSnapshotEntry(
            taskId: taskId,
            project: project,
            workspace: workspace,
            taskType: taskType,
            commandId: json["command_id"] as? String,
            title: title,
            status: status,
            message: json["message"] as? String,
            startedAt: startedAt,
            completedAt: json["completed_at"] as? Int64,
            durationMs: json["duration_ms"] as? UInt64,
            errorCode: json["error_code"] as? String,
            errorDetail: json["error_detail"] as? String,
            retryable: json["retryable"] as? Bool ?? false
        )
    }

    public init(taskId: String, project: String, workspace: String, taskType: String, commandId: String?, title: String, status: String, message: String?, startedAt: Int64, completedAt: Int64?, durationMs: UInt64? = nil, errorCode: String? = nil, errorDetail: String? = nil, retryable: Bool = false) {
        self.taskId = taskId
        self.project = project
        self.workspace = workspace
        self.taskType = taskType
        self.commandId = commandId
        self.title = title
        self.status = status
        self.message = message
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.errorCode = errorCode
        self.errorDetail = errorDetail
        self.retryable = retryable
    }
}

// MARK: - v1.40: Git 冲突向导协议模型

/// 单个冲突文件条目（语义化，替代裸路径字符串）
public struct ConflictFileEntry: Equatable {
    /// 文件路径（相对工作区根）
    public let path: String
    /// 冲突类型：content | add_add | delete_modify | modify_delete
    public let conflictType: String
    /// 是否已暂存（标记为已解决）
    public let staged: Bool

    public init(path: String, conflictType: String, staged: Bool) {
        self.path = path
        self.conflictType = conflictType
        self.staged = staged
    }

    public static func from(dict: [String: Any]) -> ConflictFileEntry? {
        guard let path = dict["path"] as? String,
              let conflictType = dict["conflict_type"] as? String else {
            return nil
        }
        let staged = dict["staged"] as? Bool ?? false
        return ConflictFileEntry(path: path, conflictType: conflictType, staged: staged)
    }

    /// 从 JSON any 值中解析列表（兼容 nil/空）
    public static func listFrom(json: Any?) -> [ConflictFileEntry] {
        guard let arr = json as? [[String: Any]] else { return [] }
        return arr.compactMap { ConflictFileEntry.from(dict: $0) }
    }
}

/// 冲突快照（整个上下文的冲突状态摘要）
public struct ConflictSnapshot: Equatable {
    /// 上下文来源：workspace | integration
    public let context: String
    /// 当前冲突文件列表
    public let files: [ConflictFileEntry]
    /// 是否所有冲突已解决
    public let allResolved: Bool

    public init(context: String, files: [ConflictFileEntry], allResolved: Bool) {
        self.context = context
        self.files = files
        self.allResolved = allResolved
    }

    public static func from(dict: [String: Any]) -> ConflictSnapshot? {
        guard let context = dict["context"] as? String else { return nil }
        let files = ConflictFileEntry.listFrom(json: dict["files"])
        let allResolved = dict["all_resolved"] as? Bool ?? files.isEmpty
        return ConflictSnapshot(context: context, files: files, allResolved: allResolved)
    }
}

/// 单文件冲突详情（四路对比内容）
public struct GitConflictDetailResult {
    public let project: String
    public let workspace: String
    /// 上下文来源：workspace | integration
    public let context: String
    public let path: String
    public let baseContent: String?
    public let oursContent: String?
    public let theirsContent: String?
    public let currentContent: String
    public let conflictMarkersCount: Int
    public let isBinary: Bool

    public static func from(json: [String: Any]) -> GitConflictDetailResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let context = json["context"] as? String,
              let path = json["path"] as? String,
              let currentContent = json["current_content"] as? String else {
            return nil
        }
        return GitConflictDetailResult(
            project: project,
            workspace: workspace,
            context: context,
            path: path,
            baseContent: json["base_content"] as? String,
            oursContent: json["ours_content"] as? String,
            theirsContent: json["theirs_content"] as? String,
            currentContent: currentContent,
            conflictMarkersCount: json["conflict_markers_count"] as? Int ?? 0,
            isBinary: json["is_binary"] as? Bool ?? false
        )
    }

    public init(project: String, workspace: String, context: String, path: String, baseContent: String?, oursContent: String?, theirsContent: String?, currentContent: String, conflictMarkersCount: Int, isBinary: Bool) {
        self.project = project
        self.workspace = workspace
        self.context = context
        self.path = path
        self.baseContent = baseContent
        self.oursContent = oursContent
        self.theirsContent = theirsContent
        self.currentContent = currentContent
        self.conflictMarkersCount = conflictMarkersCount
        self.isBinary = isBinary
    }
}

/// 冲突解决动作结果（含最新快照）
public struct GitConflictActionResult {
    public let project: String
    public let workspace: String
    /// 上下文来源：workspace | integration
    public let context: String
    public let path: String
    /// 已执行动作：accept_ours | accept_theirs | accept_both | mark_resolved
    public let action: String
    public let ok: Bool
    public let message: String?
    /// 操作后的冲突快照
    public let snapshot: ConflictSnapshot

    public static func from(json: [String: Any]) -> GitConflictActionResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let context = json["context"] as? String,
              let path = json["path"] as? String,
              let action = json["action"] as? String,
              let ok = json["ok"] as? Bool,
              let snapshotDict = json["snapshot"] as? [String: Any],
              let snapshot = ConflictSnapshot.from(dict: snapshotDict) else {
            return nil
        }
        return GitConflictActionResult(
            project: project,
            workspace: workspace,
            context: context,
            path: path,
            action: action,
            ok: ok,
            message: json["message"] as? String,
            snapshot: snapshot
        )
    }

    public init(project: String, workspace: String, context: String, path: String, action: String, ok: Bool, message: String?, snapshot: ConflictSnapshot) {
        self.project = project
        self.workspace = workspace
        self.context = context
        self.path = path
        self.action = action
        self.ok = ok
        self.message = message
        self.snapshot = snapshot
    }
}

/// 冲突向导缓存（按 project:workspace 或 project 作为键）
public struct ConflictWizardCache: Equatable {
    /// 当前冲突快照
    public var snapshot: ConflictSnapshot?
    /// 当前选中的冲突文件路径
    public var selectedFilePath: String?
    /// 最后一次读取的冲突详情
    public var currentDetail: GitConflictDetailResultCache?
    /// 是否正在加载
    public var isLoading: Bool
    public var updatedAt: Date

    public static func empty() -> ConflictWizardCache {
        ConflictWizardCache(
            snapshot: nil,
            selectedFilePath: nil,
            currentDetail: nil,
            isLoading: false,
            updatedAt: .distantPast
        )
    }

    public init(snapshot: ConflictSnapshot?, selectedFilePath: String?, currentDetail: GitConflictDetailResultCache?, isLoading: Bool, updatedAt: Date) {
        self.snapshot = snapshot
        self.selectedFilePath = selectedFilePath
        self.currentDetail = currentDetail
        self.isLoading = isLoading
        self.updatedAt = updatedAt
    }

    /// 是否有活跃冲突（有 snapshot 且未全部解决）
    public var hasActiveConflicts: Bool {
        guard let snapshot = snapshot else { return false }
        return !snapshot.allResolved && !snapshot.files.isEmpty
    }

    /// 可用的冲突文件数
    public var conflictFileCount: Int {
        snapshot?.files.count ?? 0
    }
}

/// 冲突详情缓存（存储最后读取的四路内容）
public struct GitConflictDetailResultCache: Equatable {
    public let path: String
    public let context: String
    public let baseContent: String?
    public let oursContent: String?
    public let theirsContent: String?
    public let currentContent: String
    public let conflictMarkersCount: Int
    public let isBinary: Bool

    public init(from result: GitConflictDetailResult) {
        self.path = result.path
        self.context = result.context
        self.baseContent = result.baseContent
        self.oursContent = result.oursContent
        self.theirsContent = result.theirsContent
        self.currentContent = result.currentContent
        self.conflictMarkersCount = result.conflictMarkersCount
        self.isBinary = result.isBinary
    }
}

// MARK: - 跨端 Diff 描述符（四元组唯一键）

/// 按 project/workspace/path/mode 四元组唯一标识一个 Diff 请求与缓存条目。
/// macOS 和 iOS 均使用此结构体作为 Diff 缓存的唯一键，避免各自定义独立的字符串拼接规则。
public struct DiffDescriptor: Hashable, Equatable {
    public let project: String
    public let workspace: String
    public let path: String
    public let mode: String  // "working" | "staged"

    public init(project: String, workspace: String, path: String, mode: String) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.mode = mode
    }

    /// 生成用于字典键的规范化字符串（与 GitCacheState.diffCacheKey 保持一致）
    public var cacheKey: String {
        "\(project):\(workspace):\(path):\(mode)"
    }

    public static func working(project: String, workspace: String, path: String) -> DiffDescriptor {
        DiffDescriptor(project: project, workspace: workspace, path: path, mode: "working")
    }

    public static func staged(project: String, workspace: String, path: String) -> DiffDescriptor {
        DiffDescriptor(project: project, workspace: workspace, path: path, mode: "staged")
    }
}
