import SwiftUI

/// 聊天消息 Markdown 渲染器：
/// 1) 先做行级解析（标题/列表/代码围栏）
/// 2) 再做行内 Markdown（粗体、斜体、行内代码）
struct MarkdownTextView: View {
    let text: String
    var baseFontSize: CGFloat = 13
    var textColor: Color = .primary
    private let bodyLineSpacing: CGFloat = 3

    var body: some View {
        if let attributed = parseMarkdown(text) {
            Text(attributed)
                .foregroundColor(textColor)
                .lineSpacing(bodyLineSpacing)
                .textSelection(.enabled)
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

    private func parseMarkdown(_ source: String) -> AttributedString? {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let rawLines = normalized.components(separatedBy: "\n")
        var lines: [AttributedString] = []
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
                code.backgroundColor = Color.secondary.opacity(0.18)
                lines.append(code)
                continue
            }

            if trimmed.isEmpty {
                lines.append(AttributedString(""))
                continue
            }

            if let heading = parseHeadingLine(rawLine) {
                let size = headingFontSize(level: heading.level)
                var content = parseInlineMarkdown(heading.content, defaultFont: .system(size: size, weight: .semibold))
                content.font = .system(size: size, weight: .semibold)
                lines.append(content)
                continue
            }

            if let item = parseUnorderedListLine(rawLine) {
                var prefix = AttributedString(" • ")
                prefix.font = .system(size: baseFontSize)
                let content = parseInlineMarkdown(item, defaultFont: .system(size: baseFontSize))
                lines.append(prefix + content)
                continue
            }

            if let item = parseOrderedListLine(rawLine) {
                var prefix = AttributedString("  \(item.index). ")
                prefix.font = .system(size: baseFontSize)
                let content = parseInlineMarkdown(item.content, defaultFont: .system(size: baseFontSize))
                lines.append(prefix + content)
                continue
            }

            if let quote = parseQuoteLine(rawLine) {
                var prefix = AttributedString("│ ")
                prefix.font = .system(size: baseFontSize, weight: .medium)
                prefix.foregroundColor = .secondary
                var content = parseInlineMarkdown(quote, defaultFont: .system(size: baseFontSize))
                content.foregroundColor = .secondary
                lines.append(prefix + content)
                continue
            }

            lines.append(parseInlineMarkdown(rawLine, defaultFont: .system(size: baseFontSize)))
        }

        guard !lines.isEmpty else { return nil }

        var result = AttributedString()
        for idx in lines.indices {
            if idx > 0 {
                result += AttributedString("\n")
            }
            result += lines[idx]
        }
        return result
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
                styled[run.range].backgroundColor = Color.secondary.opacity(0.2)
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

}
