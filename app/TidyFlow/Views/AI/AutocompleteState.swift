import Foundation
import Combine

private let autocompleteCandidateLimit = 200
private let autocompleteDisplayLimit = 50
private let autocompletePerfWarnMs = 20.0
private let perfAutocompleteIndexEnabled: Bool = {
    switch ProcessInfo.processInfo.environment["PERF_AUTOCOMPLETE_INDEX"]?.lowercased() {
    case "0", "false", "no", "off":
        return false
    default:
        return true
    }
}()

// MARK: - 自动补全模式

enum AutocompleteMode {
    case none
    case fileRef      // @ 触发的文件引用
    case projectMention  // @@ 触发的项目引用
    case slashCommand // / 触发的斜杠命令
    case codeCompletion // AI 代码补全（输入停顿或快捷键触发）
}

// MARK: - 自动补全条目

struct AutocompleteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    /// 选中后插入/执行的值
    let value: String
    /// 斜杠命令的执行方式："client" | "agent"（仅 slashCommand 模式有效）
    var action: String? = nil
    /// 斜杠命令输入提示（可选），用于插入参数模板
    var inputHint: String? = nil
}

// MARK: - 代码补全建议

struct CodeCompletionSuggestion {
    /// 补全建议文本（当前已接收内容，流式更新）
    var text: String
    /// 是否已完成（流结束）
    var isComplete: Bool
    /// 请求 ID
    var requestId: String
}

// MARK: - 自动补全状态

class AutocompleteState: ObservableObject {
    @Published var mode: AutocompleteMode = .none
    @Published var query: String = ""
    @Published var items: [AutocompleteItem] = []
    @Published var selectedIndex: Int = 0

    /// 代码补全建议（仅 mode == .codeCompletion 时有效）
    @Published var completionSuggestion: CodeCompletionSuggestion? = nil

    /// 当前触发 token 的替换范围（UTF16，左闭右开）
    var replaceRange: NSRange?

    /// 当前正在进行的补全请求 ID（用于取消去抖）
    var pendingCompletionRequestId: String? = nil

    var isVisible: Bool { mode != .none && (!items.isEmpty || completionSuggestion != nil) }

    func moveUp() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    func moveDown() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
    }

    func reset() {
        mode = .none
        query = ""
        items = []
        selectedIndex = 0
        replaceRange = nil
        completionSuggestion = nil
        pendingCompletionRequestId = nil
    }

    var selectedItem: AutocompleteItem? {
        guard !items.isEmpty, selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    // MARK: - 代码补全状态管理

    /// 开始一次新的代码补全流
    func beginCodeCompletion(requestId: String) {
        mode = .codeCompletion
        completionSuggestion = CodeCompletionSuggestion(
            text: "",
            isComplete: false,
            requestId: requestId
        )
        pendingCompletionRequestId = requestId
        items = []
        selectedIndex = 0
    }

    /// 追加补全分片（流式更新）
    func appendCompletionChunk(_ delta: String, requestId: String) {
        guard completionSuggestion?.requestId == requestId else { return }
        completionSuggestion?.text += delta
    }

    /// 完成补全流
    func finalizeCodeCompletion(requestId: String, fullText: String) {
        guard completionSuggestion?.requestId == requestId else { return }
        completionSuggestion?.text = fullText
        completionSuggestion?.isComplete = true
        if pendingCompletionRequestId == requestId {
            pendingCompletionRequestId = nil
        }
    }

    /// 接受当前补全建议，返回建议文本
    func acceptCompletion() -> String? {
        let text = completionSuggestion?.text
        reset()
        return text
    }
}

// MARK: - 触发检测

/// 根据输入文本更新自动补全状态
/// - slashCommands: 从后端获取的斜杠命令列表
/// - fileItems: 从后端获取的文件索引列表
func updateAutocomplete(
    text: String,
    cursorLocation: Int,
    autocomplete: AutocompleteState,
    slashCommands: [AutocompleteItem],
    fileItems: [String],
    projectItems: [String] = []
) {
    let nsText = text as NSString
    let safeCursor = min(max(cursorLocation, 0), nsText.length)
    let cursor = String.Index(utf16Offset: safeCursor, in: text)
    let tokenStart = tokenStartIndex(in: text, cursor: cursor)
    let token = text[tokenStart..<cursor]

    // 1. / 或 ／ 触发 slashCommand（仅允许位于整段输入首个非空白 token）
    if let first = token.first, first == "/" || first == "／" {
        let prefix = String(text[..<tokenStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty {
            let query = String(token.dropFirst())
            autocomplete.mode = .slashCommand
            autocomplete.query = query
            autocomplete.replaceRange = NSRange(tokenStart..<cursor, in: text)
            if query.isEmpty {
                autocomplete.items = slashCommands
            } else {
                let lower = query.lowercased()
                autocomplete.items = slashCommands.filter {
                    $0.value.lowercased().contains(lower)
                }
            }
            autocomplete.selectedIndex = 0
            return
        }
    }

    // 2. @@ 或 ＠＠ 触发 projectMention（需在单 @ 检测之前处理）
    if let doubleAtIndex = lastDoubleAtTriggerIndex(in: text, tokenStart: tokenStart, cursor: cursor) {
        // doubleAtIndex 指向第一个 @，query 从第二个 @ 之后开始
        let queryStart = text.index(doubleAtIndex, offsetBy: 2)
        let query = String(text[queryStart..<cursor])
        autocomplete.mode = .projectMention
        autocomplete.query = query
        autocomplete.replaceRange = NSRange(doubleAtIndex..<cursor, in: text)
        let matched: [String]
        if query.isEmpty {
            matched = projectItems
        } else {
            let lower = query.lowercased()
            matched = projectItems.filter { $0.lowercased().contains(lower) }
        }
        autocomplete.items = matched.prefix(autocompleteDisplayLimit).map { makeProjectItem($0) }
        autocomplete.selectedIndex = 0
        return
    }

    // 3. @ 或 ＠ 触发 fileRef（基于光标所在 token，避免整段末尾误判）
    if let triggerIndex = lastFileTriggerIndex(in: text, tokenStart: tokenStart, cursor: cursor) {
        let queryStart = text.index(after: triggerIndex)
        let query = String(text[queryStart..<cursor])
        autocomplete.mode = .fileRef
        autocomplete.query = query
        autocomplete.replaceRange = NSRange(triggerIndex..<cursor, in: text)
        let matched = matchFileItems(query: query, fileItems: fileItems)
        autocomplete.items = matched.prefix(autocompleteDisplayLimit).map { makeFileItem($0) }
        autocomplete.selectedIndex = 0
        return
    }

    // 4. 无匹配 -> 重置
    autocomplete.reset()
}

/// 从发送文本中提取 @文件引用 路径列表（跳过 @@ 项目引用）
func extractFileRefs(from text: String) -> [String] {
    // 匹配单 @ / ＠（不允许前面紧跟另一个 @ / ＠），后跟非空白字符序列
    // 使用负向后顾断言：(?<![@＠])[@＠]
    let pattern = "(?<![\\u0040\\uFF20])[\\u0040\\uFF20](\\S+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    return matches.compactMap { match -> String? in
        guard match.numberOfRanges >= 2 else { return nil }
        let ref = nsText.substring(with: match.range(at: 1))
        // 额外过滤：若 ref 以 @ 开头说明是 @@ 中第二个 @，跳过
        if ref.hasPrefix("@") || ref.hasPrefix("＠") { return nil }
        return ref
    }
}

/// 从发送文本中提取 @@项目引用 名称列表
func extractProjectMentions(from text: String) -> [String] {
    let pattern = "(?:@@|＠＠)([A-Za-z0-9_\\-\\.]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    var seen = Set<String>()
    var result: [String] = []
    for match in matches {
        guard match.numberOfRanges >= 2 else { continue }
        let name = nsText.substring(with: match.range(at: 1))
        if seen.insert(name).inserted {
            result.append(name)
        }
    }
    return result
}

// MARK: - 辅助

private func makeFileItem(_ path: String) -> AutocompleteItem {
    let filename = (path as NSString).lastPathComponent
    let dir = (path as NSString).deletingLastPathComponent
    let icon = fileIcon(for: filename)
    return AutocompleteItem(
        id: path,
        title: filename,
        subtitle: dir.isEmpty ? path : dir,
        icon: icon,
        value: path
    )
}

/// 构造项目引用补全条目
private func makeProjectItem(_ projectName: String) -> AutocompleteItem {
    AutocompleteItem(
        id: "project:\(projectName)",
        title: projectName,
        subtitle: "项目",
        icon: "folder",
        value: projectName
    )
}

private func fileIcon(for filename: String) -> String {
    let ext = (filename as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "rs": return "gearshape"
    case "js", "ts", "jsx", "tsx": return "curlybraces"
    case "json", "toml", "yaml", "yml": return "doc.text"
    case "md": return "doc.richtext"
    case "html", "css": return "globe"
    case "py": return "chevron.left.forwardslash.chevron.right"
    default: return "doc"
    }
}

private func tokenStartIndex(in text: String, cursor: String.Index) -> String.Index {
    var idx = cursor
    while idx > text.startIndex {
        let prev = text.index(before: idx)
        if text[prev].isWhitespace { break }
        idx = prev
    }
    return idx
}

private func isLikelyWordCharacter(_ char: Character) -> Bool {
    guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else {
        return false
    }
    if CharacterSet.alphanumerics.contains(scalar) { return true }
    return char == "_" || char == "-" || char == "."
}

private func matchFileItems(query: String, fileItems: [String]) -> [String] {
    let started = CFAbsoluteTimeGetCurrent()
    let result: [String]

    if query.isEmpty {
        result = Array(fileItems.prefix(autocompleteCandidateLimit))
    } else if perfAutocompleteIndexEnabled {
        result = matchFileItemsIndexed(query: query, fileItems: fileItems)
    } else {
        result = matchFileItemsLegacy(query: query, fileItems: fileItems)
    }

    let costMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
    if costMs >= autocompletePerfWarnMs {
        TFLog.app.info(
            "perf.autocomplete.match_ms=\(Int(costMs), privacy: .public) query_len=\(query.count, privacy: .public) files=\(fileItems.count, privacy: .public) hit=\(result.count, privacy: .public)"
        )
    }
    return result
}

/// 新匹配策略：单次遍历 + 分桶评分，限制候选规模，降低大索引下 CPU 压力。
private func matchFileItemsIndexed(query: String, fileItems: [String]) -> [String] {
    let lower = query.lowercased()
    var pathPrefix: [String] = []
    var filenamePrefix: [String] = []
    var contains: [String] = []
    pathPrefix.reserveCapacity(min(autocompleteCandidateLimit, 64))
    filenamePrefix.reserveCapacity(min(autocompleteCandidateLimit, 64))
    contains.reserveCapacity(min(autocompleteCandidateLimit, 64))

    for item in fileItems {
        if pathPrefix.count >= autocompleteCandidateLimit &&
            filenamePrefix.count >= autocompleteCandidateLimit &&
            contains.count >= autocompleteCandidateLimit {
            break
        }

        let pathLower = item.lowercased()
        if pathPrefix.count < autocompleteCandidateLimit, pathLower.hasPrefix(lower) {
            pathPrefix.append(item)
            continue
        }

        let filenameLower = (item as NSString).lastPathComponent.lowercased()
        if filenamePrefix.count < autocompleteCandidateLimit, filenameLower.hasPrefix(lower) {
            filenamePrefix.append(item)
            continue
        }

        if contains.count < autocompleteCandidateLimit, pathLower.contains(lower) {
            contains.append(item)
        }
    }

    var merged: [String] = []
    merged.reserveCapacity(autocompleteCandidateLimit)
    for item in pathPrefix {
        merged.append(item)
        if merged.count >= autocompleteCandidateLimit { return merged }
    }
    for item in filenamePrefix {
        merged.append(item)
        if merged.count >= autocompleteCandidateLimit { return merged }
    }
    for item in contains {
        merged.append(item)
        if merged.count >= autocompleteCandidateLimit { return merged }
    }
    return merged
}

private func matchFileItemsLegacy(query: String, fileItems: [String]) -> [String] {
    let lower = query.lowercased()
    var results: [String] = []
    var seen = Set<String>()

    for item in fileItems where item.lowercased().hasPrefix(lower) {
        if seen.insert(item).inserted {
            results.append(item)
            if results.count >= autocompleteCandidateLimit { return results }
        }
    }

    for item in fileItems {
        let name = (item as NSString).lastPathComponent.lowercased()
        guard name.hasPrefix(lower) else { continue }
        if seen.insert(item).inserted {
            results.append(item)
            if results.count >= autocompleteCandidateLimit { return results }
        }
    }

    for item in fileItems where item.lowercased().contains(lower) {
        if seen.insert(item).inserted {
            results.append(item)
            if results.count >= autocompleteCandidateLimit { return results }
        }
    }

    return results
}

private func lastFileTriggerIndex(
    in text: String,
    tokenStart: String.Index,
    cursor: String.Index
) -> String.Index? {
    var idx = cursor
    while idx > tokenStart {
        idx = text.index(before: idx)
        let ch = text[idx]
        guard ch == "@" || ch == "＠" else { continue }
        // 跳过双 @（项目引用），只处理单 @
        if idx > tokenStart {
            let prev = text.index(before: idx)
            if text[prev] == "@" || text[prev] == "＠" { continue }
        }
        if idx > tokenStart {
            let prev = text[text.index(before: idx)]
            // 邮箱/英文单词中间的 @ 不作为文件引用触发符（例如 foo@bar.com）
            if isLikelyWordCharacter(prev) { continue }
        }
        return idx
    }
    return nil
}

/// 在 token 范围内找到最近的双 @（`@@` 或 `＠＠`）触发位置，返回第一个 @ 的索引。
private func lastDoubleAtTriggerIndex(
    in text: String,
    tokenStart: String.Index,
    cursor: String.Index
) -> String.Index? {
    var idx = cursor
    while idx > tokenStart {
        idx = text.index(before: idx)
        let ch = text[idx]
        guard ch == "@" || ch == "＠" else { continue }
        // 确认前一字符也是 @
        guard idx > tokenStart else { continue }
        let prevIdx = text.index(before: idx)
        guard text[prevIdx] == "@" || text[prevIdx] == "＠" else { continue }
        return prevIdx
    }
    return nil
}
