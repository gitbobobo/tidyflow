import SwiftUI

/// 聊天消息 Markdown 渲染器：
/// 1) 先做行级解析（标题/列表/代码围栏）
/// 2) 再做行内 Markdown（粗体、斜体、行内代码）
struct MarkdownTextView: View {
    let text: String
    var baseFontSize: CGFloat = 13
    var textColor: Color = .primary
    private let bodyLineSpacing: CGFloat = 3

    private enum MarkdownBlock {
        case text(AttributedString)
        case divider
    }

    var body: some View {
        let blocks = parseMarkdownBlocks(text)
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: bodyLineSpacing) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let attributed):
                        Text(attributed)
                            .foregroundColor(textColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .divider:
                        Divider()
                            .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(.system(size: baseFontSize))
                .foregroundColor(textColor)
                .lineSpacing(bodyLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func parseMarkdownBlocks(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let rawLines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var inCodeFence = false

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeFence.toggle()
                continue
            }

            if inCodeFence {
                var code = AttributedString("  \(rawLine)")
                code.font = .system(size: baseFontSize, design: .monospaced)
                code.foregroundColor = .primary
                blocks.append(.text(code))
                continue
            }

            if trimmed.isEmpty {
                blocks.append(.text(AttributedString("")))
                continue
            }

            if isThematicBreakLine(rawLine) {
                blocks.append(.divider)
                continue
            }

            if let heading = parseHeadingLine(rawLine) {
                let size = headingFontSize(level: heading.level)
                var content = parseInlineMarkdown(heading.content, defaultFont: .system(size: size, weight: .semibold))
                content.font = .system(size: size, weight: .semibold)
                blocks.append(.text(content))
                continue
            }

            if let item = parseUnorderedListLine(rawLine) {
                var prefix = AttributedString(" • ")
                prefix.font = .system(size: baseFontSize)
                let content = parseInlineMarkdown(item, defaultFont: .system(size: baseFontSize))
                blocks.append(.text(prefix + content))
                continue
            }

            if let item = parseOrderedListLine(rawLine) {
                var prefix = AttributedString("  \(item.index). ")
                prefix.font = .system(size: baseFontSize)
                let content = parseInlineMarkdown(item.content, defaultFont: .system(size: baseFontSize))
                blocks.append(.text(prefix + content))
                continue
            }

            if let quote = parseQuoteLine(rawLine) {
                var prefix = AttributedString("│ ")
                prefix.font = .system(size: baseFontSize, weight: .medium)
                prefix.foregroundColor = .secondary
                var content = parseInlineMarkdown(quote, defaultFont: .system(size: baseFontSize))
                content.foregroundColor = .secondary
                blocks.append(.text(prefix + content))
                continue
            }

            blocks.append(.text(parseInlineMarkdown(rawLine, defaultFont: .system(size: baseFontSize))))
        }

        return blocks
    }

    private func parseInlineMarkdown(_ source: String, defaultFont: Font) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible

        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            var fallback = AttributedString(source)
            fallback.font = defaultFont
            return fallback
        }
        return applyInlineIntentStyles(to: parsed, defaultFont: defaultFont)
    }

    private func applyInlineIntentStyles(to parsed: AttributedString, defaultFont: Font) -> AttributedString {
        var styled = parsed
        for run in styled.runs {
            let intent = run.inlinePresentationIntent
            var font = defaultFont

            if intent?.contains(.code) == true {
                font = .system(size: baseFontSize, design: .monospaced)
                styled[run.range].foregroundColor = .primary
            } else {
                if intent?.contains(.stronglyEmphasized) == true {
                    font = font.weight(.bold)
                }
                if intent?.contains(.emphasized) == true {
                    font = font.italic()
                }
            }

            styled[run.range].font = font
        }
        return styled
    }

    private func headingFontSize(level: Int) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 4
        case 2: return baseFontSize + 3
        case 3: return baseFontSize + 2
        case 4: return baseFontSize + 1
        case 5: return baseFontSize + 0.5
        default: return baseFontSize
        }
    }

    private func parseHeadingLine(_ line: String) -> (level: Int, content: String)? {
        let chars = Array(line)
        var idx = 0
        while idx < chars.count && (chars[idx] == " " || chars[idx] == "\t") {
            idx += 1
        }

        let hashStart = idx
        while idx < chars.count && chars[idx] == "#" && (idx - hashStart) < 6 {
            idx += 1
        }

        let level = idx - hashStart
        guard level > 0 else { return nil }
        guard idx < chars.count, chars[idx] == " " else { return nil }

        let contentStart = line.index(line.startIndex, offsetBy: idx + 1)
        let content = String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }

        return (level, content)
    }

    private func parseUnorderedListLine(_ line: String) -> String? {
        let chars = Array(line)
        var idx = 0
        while idx < chars.count && (chars[idx] == " " || chars[idx] == "\t") {
            idx += 1
        }
        guard idx + 1 < chars.count else { return nil }
        guard chars[idx] == "-" || chars[idx] == "*" || chars[idx] == "+" else { return nil }
        guard chars[idx + 1] == " " else { return nil }

        let contentStart = line.index(line.startIndex, offsetBy: idx + 2)
        let content = String(line[contentStart...])
        return content.isEmpty ? nil : content
    }

    private func parseOrderedListLine(_ line: String) -> (index: String, content: String)? {
        let chars = Array(line)
        var idx = 0
        while idx < chars.count && (chars[idx] == " " || chars[idx] == "\t") {
            idx += 1
        }

        let numberStart = idx
        while idx < chars.count && chars[idx].isNumber {
            idx += 1
        }
        guard idx > numberStart else { return nil }
        guard idx + 1 < chars.count, chars[idx] == ".", chars[idx + 1] == " " else { return nil }

        let number = String(chars[numberStart..<idx])
        let contentStart = line.index(line.startIndex, offsetBy: idx + 2)
        let content = String(line[contentStart...])
        guard !content.isEmpty else { return nil }

        return (number, content)
    }

    private func parseQuoteLine(_ line: String) -> String? {
        let chars = Array(line)
        var idx = 0
        while idx < chars.count && (chars[idx] == " " || chars[idx] == "\t") {
            idx += 1
        }
        guard idx < chars.count, chars[idx] == ">" else { return nil }
        let contentStartOffset = (idx + 1 < chars.count && chars[idx + 1] == " ") ? (idx + 2) : (idx + 1)
        let contentStart = line.index(line.startIndex, offsetBy: contentStartOffset)
        let content = String(line[contentStart...])
        return content.isEmpty ? nil : content
    }

    private func isThematicBreakLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        let charset = Set(compact)
        guard charset.count == 1, let token = charset.first else { return false }
        return token == "-" || token == "*" || token == "_"
    }

}
