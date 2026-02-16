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

    /// 当前 @ 触发符在文本中的位置（用于替换）
    var triggerLocation: Int?

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
        triggerLocation = nil
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
    autocomplete: AutocompleteState,
    slashCommands: [AutocompleteItem],
    fileItems: [String]
) {
    let trimmed = text.trimmingCharacters(in: .whitespaces)

    // 1. 文本以 / 开头且无空格 → slashCommand 模式
    if trimmed.hasPrefix("/") && !trimmed.contains(" ") {
        let query = String(trimmed.dropFirst())
        autocomplete.mode = .slashCommand
        autocomplete.query = query
        autocomplete.triggerLocation = 0
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

    // 2. 从文本末尾向前找 @，@ 后无空白 → fileRef 模式
    if let atRange = text.range(of: "@", options: .backwards) {
        let afterAt = text[atRange.upperBound...]
        // @ 后面不能有空白字符（表示正在输入文件路径）
        if !afterAt.contains(" ") && !afterAt.contains("\n") {
            let query = String(afterAt)
            let triggerLoc = text.distance(from: text.startIndex, to: atRange.lowerBound)
            autocomplete.mode = .fileRef
            autocomplete.query = query
            autocomplete.triggerLocation = triggerLoc
            if query.isEmpty {
                // 显示前 20 个文件
                autocomplete.items = fileItems.prefix(20).map { makeFileItem($0) }
            } else {
                let lower = query.lowercased()
                autocomplete.items = fileItems
                    .filter { $0.lowercased().contains(lower) }
                    .prefix(20)
                    .map { makeFileItem($0) }
            }
            autocomplete.selectedIndex = 0
            return
        }
    }

    // 3. 无匹配 → 重置
    autocomplete.reset()
}

/// 从发送文本中提取 @文件引用 路径列表
func extractFileRefs(from text: String) -> [String] {
    // 匹配 @后跟非空白字符序列
    let pattern = "@(\\S+)"
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
