import Foundation
import Combine

// MARK: - 自动补全模式

enum AutocompleteMode {
    case none
    case fileRef      // @ 触发的文件引用
    case slashCommand // / 触发的斜杠命令
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
    var action: String?
}

// MARK: - 自动补全状态

class AutocompleteState: ObservableObject {
    @Published var mode: AutocompleteMode = .none
    @Published var query: String = ""
    @Published var items: [AutocompleteItem] = []
    @Published var selectedIndex: Int = 0

    /// 当前触发 token 的替换范围（UTF16，左闭右开）
    var replaceRange: NSRange?

    var isVisible: Bool { mode != .none && !items.isEmpty }

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
    }

    var selectedItem: AutocompleteItem? {
        guard !items.isEmpty, selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
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
    fileItems: [String]
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

    // 2. @ 或 ＠ 触发 fileRef（基于光标所在 token，避免整段末尾误判）
    if let triggerIndex = lastFileTriggerIndex(in: text, tokenStart: tokenStart, cursor: cursor) {
        let queryStart = text.index(after: triggerIndex)
        let query = String(text[queryStart..<cursor])
        autocomplete.mode = .fileRef
        autocomplete.query = query
        autocomplete.replaceRange = NSRange(triggerIndex..<cursor, in: text)
        let matched = matchFileItems(query: query, fileItems: fileItems)
        autocomplete.items = matched.prefix(20).map { makeFileItem($0) }
        autocomplete.selectedIndex = 0
        return
    }

    // 3. 无匹配 -> 重置
    autocomplete.reset()
}

/// 从发送文本中提取 @文件引用 路径列表
func extractFileRefs(from text: String) -> [String] {
    // 匹配 @ / ＠ 后跟非空白字符序列
    let pattern = "[@＠](\\S+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    return matches.compactMap { match -> String? in
        guard match.numberOfRanges >= 2 else { return nil }
        return nsText.substring(with: match.range(at: 1))
    }
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
    guard !query.isEmpty else { return fileItems }
    let lower = query.lowercased()
    var results: [String] = []
    var seen = Set<String>()

    let exactPrefix = fileItems.filter { $0.lowercased().hasPrefix(lower) }
    for item in exactPrefix where seen.insert(item).inserted {
        results.append(item)
    }

    let filenamePrefix = fileItems.filter {
        let name = ($0 as NSString).lastPathComponent.lowercased()
        return name.hasPrefix(lower)
    }
    for item in filenamePrefix where seen.insert(item).inserted {
        results.append(item)
    }

    let contains = fileItems.filter { $0.lowercased().contains(lower) }
    for item in contains where seen.insert(item).inserted {
        results.append(item)
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
        if idx > tokenStart {
            let prev = text[text.index(before: idx)]
            // 邮箱/英文单词中间的 @ 不作为文件引用触发符（例如 foo@bar.com）
            if isLikelyWordCharacter(prev) { continue }
        }
        return idx
    }
    return nil
}
