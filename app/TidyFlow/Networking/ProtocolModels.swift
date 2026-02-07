import Foundation

// MARK: - UX-2: Project Import Protocol Models

/// Workspace info returned from import/create operations
struct WorkspaceImportInfo {
    let name: String
    let root: String
    let branch: String
    let status: String

    static func from(json: [String: Any]) -> WorkspaceImportInfo? {
        guard let name = json["name"] as? String,
              let root = json["root"] as? String,
              let branch = json["branch"] as? String,
              let status = json["status"] as? String else {
            return nil
        }
        return WorkspaceImportInfo(name: name, root: root, branch: branch, status: status)
    }
}

/// Result from import_project request
struct ProjectImportedResult {
    let name: String
    let root: String
    let defaultBranch: String
    let workspace: WorkspaceImportInfo?

    static func from(json: [String: Any]) -> ProjectImportedResult? {
        guard let name = json["name"] as? String,
              let root = json["root"] as? String,
              let defaultBranch = json["default_branch"] as? String else {
            return nil
        }
        var workspace: WorkspaceImportInfo? = nil
        if let wsJson = json["workspace"] as? [String: Any] {
            workspace = WorkspaceImportInfo.from(json: wsJson)
        }
        return ProjectImportedResult(
            name: name,
            root: root,
            defaultBranch: defaultBranch,
            workspace: workspace
        )
    }
}

/// Result from create_workspace request
struct WorkspaceCreatedResult {
    let project: String
    let workspace: WorkspaceImportInfo

    static func from(json: [String: Any]) -> WorkspaceCreatedResult? {
        guard let project = json["project"] as? String,
              let wsJson = json["workspace"] as? [String: Any],
              let workspace = WorkspaceImportInfo.from(json: wsJson) else {
            return nil
        }
        return WorkspaceCreatedResult(project: project, workspace: workspace)
    }
}

/// Project info returned from list_projects
struct ProjectInfo {
    let name: String
    let root: String
    let workspaceCount: Int

    static func from(json: [String: Any]) -> ProjectInfo? {
        guard let name = json["name"] as? String,
              let root = json["root"] as? String else {
            return nil
        }
        let workspaceCount = json["workspace_count"] as? Int ?? 0
        return ProjectInfo(name: name, root: root, workspaceCount: workspaceCount)
    }
}

/// Result from list_projects request (server sends "projects" message)
struct ProjectsListResult {
    let items: [ProjectInfo]

    static func from(json: [String: Any]) -> ProjectsListResult? {
        guard let itemsArray = json["items"] as? [[String: Any]] else {
            return nil
        }
        
        var items: [ProjectInfo] = []
        for itemJson in itemsArray {
            if let info = ProjectInfo.from(json: itemJson) {
                items.append(info)
            }
        }
        
        return ProjectsListResult(items: items)
    }
}

/// Workspace info returned from list_workspaces
struct WorkspaceInfo {
    let name: String
    let root: String
    let branch: String
    let status: String

    static func from(json: [String: Any]) -> WorkspaceInfo? {
        guard let name = json["name"] as? String,
              let root = json["root"] as? String,
              let branch = json["branch"] as? String,
              let status = json["status"] as? String else {
            return nil
        }
        return WorkspaceInfo(name: name, root: root, branch: branch, status: status)
    }
}

/// Result from list_workspaces request (server sends "workspaces" message)
struct WorkspacesListResult {
    let project: String
    let items: [WorkspaceInfo]

    static func from(json: [String: Any]) -> WorkspacesListResult? {
        guard let project = json["project"] as? String,
              let itemsArray = json["items"] as? [[String: Any]] else {
            return nil
        }
        
        var items: [WorkspaceInfo] = []
        for itemJson in itemsArray {
            if let info = WorkspaceInfo.from(json: itemJson) {
                items.append(info)
            }
        }
        
        return WorkspacesListResult(project: project, items: items)
    }
}

/// Result from remove_project request
struct ProjectRemovedResult {
    let name: String
    let ok: Bool
    let message: String?

    static func from(json: [String: Any]) -> ProjectRemovedResult? {
        guard let name = json["name"] as? String,
              let ok = json["ok"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        return ProjectRemovedResult(name: name, ok: ok, message: message)
    }
}

/// Result from remove_workspace request
struct WorkspaceRemovedResult {
    let project: String
    let workspace: String
    let ok: Bool
    let message: String?

    static func from(json: [String: Any]) -> WorkspaceRemovedResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let ok = json["ok"] as? Bool else {
            return nil
        }
        let message = json["message"] as? String
        return WorkspaceRemovedResult(project: project, workspace: workspace, ok: ok, message: message)
    }
}

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

// MARK: - Phase C2-2a: Git Diff Protocol Models

/// Result from git_diff request
struct GitDiffResult {
    let project: String
    let workspace: String
    let path: String
    let code: String       // Git status code (M, A, D, etc.)
    let format: String     // "unified"
    let text: String       // The actual diff text
    let isBinary: Bool
    let truncated: Bool
    let mode: String       // "working" or "staged"

    static func from(json: [String: Any]) -> GitDiffResult? {
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
}

/// Cached diff for a specific file/mode combination
struct DiffCache {
    var text: String
    var parsedLines: [DiffLine]
    var isLoading: Bool
    var error: String?
    var isBinary: Bool
    var truncated: Bool
    var code: String       // Git status code
    var updatedAt: Date

    static func empty() -> DiffCache {
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

    var isExpired: Bool {
        // Diff cache expires after 30 seconds (more volatile than file index)
        Date().timeIntervalSince(updatedAt) > 30
    }
}

/// Parsed diff line model
struct DiffLine: Identifiable {
    let id: Int  // Line index in the diff
    let kind: DiffLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String

    /// Whether this line can be clicked to navigate to editor
    var isNavigable: Bool {
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
    var targetLine: Int? {
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
}

enum DiffLineKind: String {
    case header   // diff --git, ---, +++
    case hunk     // @@ -x,y +a,b @@
    case context  // ' ' unchanged line
    case add      // '+' added line
    case del      // '-' removed line
}

// MARK: - Phase C2-2b: Split Diff View Mode

enum DiffViewMode: String, Codable {
    case unified
    case split
}

// MARK: - Phase C2-2b: Split Diff Data Structures

/// A cell in the split diff view (left or right column)
struct SplitCell {
    let lineNumber: Int?
    let text: String
    let kind: DiffLineKind

    /// Whether this cell can be clicked to navigate
    var isNavigable: Bool {
        switch kind {
        case .context, .add:
            return lineNumber != nil
        case .del:
            return lineNumber != nil
        case .header, .hunk:
            return false
        }
    }
}

/// Row kind for split view layout
enum SplitRowKind {
    case header      // Full-width header row
    case hunk        // Full-width hunk header row
    case code        // Left/right code columns
}

/// A row in the split diff view
struct SplitRow: Identifiable {
    let id: Int
    let rowKind: SplitRowKind
    let left: SplitCell?
    let right: SplitCell?
    let fullText: String?  // For header/hunk rows
}

/// Builder to convert unified diff lines to split rows
struct SplitBuilder {
    /// Maximum lines before split view is disabled
    static let maxLinesForSplit = 5000

    /// Check if diff is too large for split view
    static func isTooLargeForSplit(_ lines: [DiffLine]) -> Bool {
        return lines.count > maxLinesForSplit
    }

    /// Convert unified diff lines to split rows
    /// Simple algorithm: no alignment, just place lines in appropriate columns
    static func build(from lines: [DiffLine]) -> [SplitRow] {
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

struct DiffParser {
    /// Parse unified diff text into structured lines
    static func parse(_ text: String) -> [DiffLine] {
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
struct GitStatusItem: Identifiable {
    let id: String  // Use path as unique ID
    let path: String
    let status: String  // M, A, D, ??, R, C, etc.
    let staged: Bool?   // If core provides staged info
    let renameFrom: String?  // For renamed files
    let additions: Int?   // 新增行数
    let deletions: Int?   // 删除行数

    /// Human-readable status description
    var statusDescription: String {
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
    var statusColor: String {
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
}

/// Result from git_status request
struct GitStatusResult {
    let project: String
    let workspace: String
    let items: [GitStatusItem]
    let isGitRepo: Bool
    let error: String?
    let hasStagedChanges: Bool
    let stagedCount: Int
    let currentBranch: String?
    let defaultBranch: String?
    let aheadBy: Int?
    let behindBy: Int?
    let comparedBranch: String?

    static func from(json: [String: Any]) -> GitStatusResult? {
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
}

/// Cached git status for a workspace
struct GitStatusCache {
    var items: [GitStatusItem]
    var isLoading: Bool
    var error: String?
    var isGitRepo: Bool
    var updatedAt: Date
    var hasStagedChanges: Bool
    var stagedCount: Int
    var currentBranch: String?
    var defaultBranch: String?
    var aheadBy: Int?
    var behindBy: Int?
    var comparedBranch: String?

    static func empty() -> GitStatusCache {
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

    var isExpired: Bool {
        // Git status cache expires after 60 seconds
        Date().timeIntervalSince(updatedAt) > 60
    }
}

// MARK: - Git Log (Commit History) Protocol Models

/// 单条提交记录
struct GitLogEntry: Identifiable {
    let id: String       // 使用 sha 作为 ID
    let sha: String      // 短 SHA (7字符)
    let message: String  // 提交消息（首行）
    let author: String   // 作者名
    let date: String     // ISO 日期
    let refs: [String]   // HEAD, branch, tag 等引用
    
    /// 格式化的相对时间
    var relativeDate: String {
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
            return "time.justNow".localized
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return String(format: "time.minutesAgo".localized, minutes)
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return String(format: "time.hoursAgo".localized, hours)
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return String(format: "time.daysAgo".localized, days)
        } else if interval < 2592000 {
            let weeks = Int(interval / 604800)
            return String(format: "time.weeksAgo".localized, weeks)
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            return dateFormatter.string(from: date)
        }
    }
}

/// git_log 请求的响应结果
struct GitLogResult {
    let project: String
    let workspace: String
    let entries: [GitLogEntry]
    
    static func from(json: [String: Any]) -> GitLogResult? {
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
}

/// Git 日志缓存
struct GitLogCache {
    var entries: [GitLogEntry]
    var isLoading: Bool
    var error: String?
    var updatedAt: Date
    
    static func empty() -> GitLogCache {
        GitLogCache(
            entries: [],
            isLoading: false,
            error: nil,
            updatedAt: .distantPast
        )
    }
    
    var isExpired: Bool {
        // Git log cache 过期时间：5 分钟
        Date().timeIntervalSince(updatedAt) > 300
    }
}

// MARK: - Git Show (单个 commit 详情)

/// Git show 文件变更条目
struct GitShowFileEntry: Identifiable {
    var id: String { path }
    let status: String      // "M", "A", "D", "R" 等
    let path: String
    let oldPath: String?    // 重命名时的原路径
}

/// Git show 结果（单个 commit 详情）
struct GitShowResult {
    let project: String
    let workspace: String
    let sha: String
    let fullSha: String
    let message: String     // 完整提交消息
    let author: String
    let authorEmail: String
    let date: String
    let files: [GitShowFileEntry]
    
    static func from(json: [String: Any]) -> GitShowResult? {
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
}

/// Git show 缓存（按 SHA 索引）
struct GitShowCache {
    var result: GitShowResult?
    var isLoading: Bool
    var error: String?
}

// MARK: - Phase C3-2a: Git Stage/Unstage Protocol Models

/// Result from git_stage or git_unstage request
struct GitOpResult {
    let project: String
    let workspace: String
    let op: String       // "stage" or "unstage"
    let ok: Bool
    let message: String?
    let path: String?
    let scope: String    // "file" or "all"

    static func from(json: [String: Any]) -> GitOpResult? {
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
}

/// Track in-flight git operations
struct GitOpInFlight: Equatable, Hashable {
    let op: String       // "stage", "unstage", "discard", or "switch_branch"
    let path: String?    // nil for "all" scope
    let scope: String    // "file", "all", or "branch"
}

// MARK: - Phase C3-3a: Git Branch Protocol Models

/// Single branch info
struct GitBranchItem: Identifiable {
    let id: String  // Use name as unique ID
    let name: String
}

/// Result from git_branches request
struct GitBranchesResult {
    let project: String
    let workspace: String
    let current: String
    let branches: [GitBranchItem]

    static func from(json: [String: Any]) -> GitBranchesResult? {
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
}

/// Cached git branches for a workspace
struct GitBranchCache {
    var current: String
    var branches: [GitBranchItem]
    var isLoading: Bool
    var error: String?
    var updatedAt: Date

    static func empty() -> GitBranchCache {
        GitBranchCache(
            current: "",
            branches: [],
            isLoading: false,
            error: nil,
            updatedAt: .distantPast
        )
    }
}

// MARK: - Phase C3-4a: Git Commit Protocol Models

/// Result from git_commit request
struct GitCommitResult {
    let project: String
    let workspace: String
    let ok: Bool
    let message: String?
    let sha: String?

    static func from(json: [String: Any]) -> GitCommitResult? {
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
}

// MARK: - Phase UX-3a: Git Rebase Protocol Models

/// Git operation state enum
enum GitOpState: String {
    case normal = "normal"
    case rebasing = "rebasing"
    case merging = "merging"

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .rebasing: return "Rebasing"
        case .merging: return "Merging"
        }
    }
}

/// Result from git_rebase request
struct GitRebaseResult {
    let project: String
    let workspace: String
    let ok: Bool
    let state: String  // "completed", "conflict", "aborted", "error"
    let message: String?
    let conflicts: [String]

    static func from(json: [String: Any]) -> GitRebaseResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let ok = json["ok"] as? Bool,
              let state = json["state"] as? String else {
            return nil
        }
        let message = json["message"] as? String
        let conflicts = json["conflicts"] as? [String] ?? []
        return GitRebaseResult(
            project: project,
            workspace: workspace,
            ok: ok,
            state: state,
            message: message,
            conflicts: conflicts
        )
    }
}

/// Result from git_op_status request
struct GitOpStatusResult {
    let project: String
    let workspace: String
    let state: GitOpState
    let conflicts: [String]
    let head: String?
    let onto: String?

    static func from(json: [String: Any]) -> GitOpStatusResult? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let stateStr = json["state"] as? String else {
            return nil
        }
        let state = GitOpState(rawValue: stateStr) ?? .normal
        let conflicts = json["conflicts"] as? [String] ?? []
        let head = json["head"] as? String
        let onto = json["onto"] as? String
        return GitOpStatusResult(
            project: project,
            workspace: workspace,
            state: state,
            conflicts: conflicts,
            head: head,
            onto: onto
        )
    }
}

/// Cached git operation status for a workspace
struct GitOpStatusCache {
    var state: GitOpState
    var conflicts: [String]
    var isLoading: Bool
    var updatedAt: Date

    static func empty() -> GitOpStatusCache {
        GitOpStatusCache(
            state: .normal,
            conflicts: [],
            isLoading: false,
            updatedAt: .distantPast
        )
    }
}

// MARK: - Phase UX-3b: Git Merge Integration Protocol Models

/// Integration worktree state enum
enum IntegrationState: String {
    case idle = "idle"
    case merging = "merging"
    case conflict = "conflict"
    case completed = "completed"
    case failed = "failed"
    // UX-4: Rebase states
    case rebasing = "rebasing"
    case rebaseConflict = "rebase_conflict"

    var displayName: String {
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
    var isRebaseState: Bool {
        switch self {
        case .rebasing, .rebaseConflict: return true
        default: return false
        }
    }

    /// UX-4: Check if this is a merge-related state
    var isMergeState: Bool {
        switch self {
        case .merging, .conflict: return true
        default: return false
        }
    }
}

/// Result from git_merge_to_default request
struct GitMergeToDefaultResult {
    let project: String
    let ok: Bool
    let state: IntegrationState
    let message: String?
    let conflicts: [String]
    let headSha: String?
    let integrationPath: String?

    static func from(json: [String: Any]) -> GitMergeToDefaultResult? {
        guard let project = json["project"] as? String,
              let ok = json["ok"] as? Bool,
              let stateStr = json["state"] as? String else {
            return nil
        }
        let state = IntegrationState(rawValue: stateStr) ?? .failed
        let message = json["message"] as? String
        let conflicts = json["conflicts"] as? [String] ?? []
        let headSha = json["head_sha"] as? String
        let integrationPath = json["integration_path"] as? String
        return GitMergeToDefaultResult(
            project: project,
            ok: ok,
            state: state,
            message: message,
            conflicts: conflicts,
            headSha: headSha,
            integrationPath: integrationPath
        )
    }
}

/// Result from git_integration_status request
struct GitIntegrationStatusResult {
    let project: String
    let state: IntegrationState
    let conflicts: [String]
    let head: String?
    let defaultBranch: String
    let path: String
    let isClean: Bool
    // UX-6: Branch divergence fields
    let branchAheadBy: Int?
    let branchBehindBy: Int?
    let comparedBranch: String?

    static func from(json: [String: Any]) -> GitIntegrationStatusResult? {
        guard let project = json["project"] as? String,
              let stateStr = json["state"] as? String,
              let defaultBranch = json["default_branch"] as? String,
              let path = json["path"] as? String,
              let isClean = json["is_clean"] as? Bool else {
            return nil
        }
        let state = IntegrationState(rawValue: stateStr) ?? .idle
        let conflicts = json["conflicts"] as? [String] ?? []
        let head = json["head"] as? String
        // UX-6: Parse branch divergence fields
        let branchAheadBy = json["branch_ahead_by"] as? Int
        let branchBehindBy = json["branch_behind_by"] as? Int
        let comparedBranch = json["compared_branch"] as? String
        return GitIntegrationStatusResult(
            project: project,
            state: state,
            conflicts: conflicts,
            head: head,
            defaultBranch: defaultBranch,
            path: path,
            isClean: isClean,
            branchAheadBy: branchAheadBy,
            branchBehindBy: branchBehindBy,
            comparedBranch: comparedBranch
        )
    }
}

/// Cached integration status for a project
struct GitIntegrationStatusCache {
    var state: IntegrationState
    var conflicts: [String]
    var isLoading: Bool
    var updatedAt: Date
    var integrationPath: String?
    var defaultBranch: String
    // UX-6: Branch divergence fields
    var branchAheadBy: Int?
    var branchBehindBy: Int?
    var comparedBranch: String?

    static func empty() -> GitIntegrationStatusCache {
        GitIntegrationStatusCache(
            state: .idle,
            conflicts: [],
            isLoading: false,
            updatedAt: .distantPast,
            integrationPath: nil,
            defaultBranch: "main",
            branchAheadBy: nil,
            branchBehindBy: nil,
            comparedBranch: nil
        )
    }
}

// MARK: - Phase UX-4: Git Rebase onto Default Protocol Models

/// Result from git_rebase_onto_default request
struct GitRebaseOntoDefaultResult {
    let project: String
    let ok: Bool
    let state: IntegrationState
    let message: String?
    let conflicts: [String]
    let headSha: String?
    let integrationPath: String?

    static func from(json: [String: Any]) -> GitRebaseOntoDefaultResult? {
        guard let project = json["project"] as? String,
              let ok = json["ok"] as? Bool,
              let stateStr = json["state"] as? String else {
            return nil
        }
        let state = IntegrationState(rawValue: stateStr) ?? .failed
        let message = json["message"] as? String
        let conflicts = json["conflicts"] as? [String] ?? []
        let headSha = json["head_sha"] as? String
        let integrationPath = json["integration_path"] as? String
        return GitRebaseOntoDefaultResult(
            project: project,
            ok: ok,
            state: state,
            message: message,
            conflicts: conflicts,
            headSha: headSha,
            integrationPath: integrationPath
        )
    }
}

// MARK: - Phase UX-5: Git Reset Integration Worktree Protocol Models

/// Result from git_reset_integration_worktree request
struct GitResetIntegrationWorktreeResult {
    let project: String
    let ok: Bool
    let message: String?
    let path: String?

    static func from(json: [String: Any]) -> GitResetIntegrationWorktreeResult? {
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
}

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

// MARK: - AI Git Commit Models

/// AI Git commit 信息
struct AIGitCommit {
    let sha: String
    let message: String
    let files: [String]

    static func from(json: [String: Any]) -> AIGitCommit? {
        guard let sha = json["sha"] as? String,
              let message = json["message"] as? String,
              let files = json["files"] as? [String] else {
            return nil
        }
        return AIGitCommit(sha: sha, message: message, files: files)
    }
}

/// AI Git commit 结果
struct GitAICommitResult {
    let success: Bool
    let message: String
    let commits: [AIGitCommit]

    static func from(json: [String: Any]) -> GitAICommitResult? {
        guard let success = json["success"] as? Bool,
              let message = json["message"] as? String,
              let commitsArray = json["commits"] as? [[String: Any]] else {
            return nil
        }
        let commits = commitsArray.compactMap { AIGitCommit.from(json: $0) }
        return GitAICommitResult(success: success, message: message, commits: commits)
    }
}
