import Foundation

/// AI 聊天 diff 解析器（纯函数，无 UI 依赖）
enum AIDiffParser {

    /// 解析 unified diff 文本，返回结构化结果
    static func parse(_ text: String) -> ParsedDiff? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        var filePath: String?
        var rows: [DiffRow] = []
        var oldLine: Int?
        var newLine: Int?
        var addedCount = 0
        var removedCount = 0
        var rowID = 0

        for line in lines {
            if line.hasPrefix("Index: ") || isSeparatorLine(line) || line.hasPrefix("--- ") {
                continue
            }
            if line.hasPrefix("diff --git ") {
                let parts = line.components(separatedBy: " ")
                if parts.count >= 4 {
                    filePath = normalizePath(parts[3])
                }
                continue
            }
            if line.hasPrefix("+++ "), !line.contains("/dev/null") {
                filePath = normalizePath(String(line.dropFirst(4)))
                continue
            }
            if line.hasPrefix("@@"), let (oldStart, newStart) = parseHunkHeader(line) {
                oldLine = oldStart
                newLine = newStart
                rows.append(DiffRow(
                    id: rowID, kind: .hunk, marker: "@@",
                    text: line, oldLine: nil, newLine: nil
                ))
                rowID += 1
                continue
            }

            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                rows.append(DiffRow(
                    id: rowID, kind: .added, marker: "+",
                    text: String(line.dropFirst()),
                    oldLine: nil, newLine: newLine
                ))
                addedCount += 1
                rowID += 1
                if let n = newLine { newLine = n + 1 }
                continue
            }
            if line.hasPrefix("-"), !line.hasPrefix("---") {
                rows.append(DiffRow(
                    id: rowID, kind: .removed, marker: "-",
                    text: String(line.dropFirst()),
                    oldLine: oldLine, newLine: nil
                ))
                removedCount += 1
                rowID += 1
                if let n = oldLine { oldLine = n + 1 }
                continue
            }
            if line.hasPrefix(" ") {
                rows.append(DiffRow(
                    id: rowID, kind: .context, marker: " ",
                    text: String(line.dropFirst()),
                    oldLine: oldLine, newLine: newLine
                ))
                rowID += 1
                if let n = oldLine { oldLine = n + 1 }
                if let n = newLine { newLine = n + 1 }
                continue
            }

            // 其他行（如 "\ No newline at end of file"）
            if !line.isEmpty {
                rows.append(DiffRow(
                    id: rowID, kind: .meta, marker: "",
                    text: line, oldLine: nil, newLine: nil
                ))
                rowID += 1
            }
        }

        guard !rows.isEmpty else { return nil }
        var parsed = ParsedDiff(
            filePath: filePath,
            addedCount: addedCount,
            removedCount: removedCount,
            rows: rows
        )
        DiffInlineHighlighter.annotate(&parsed)
        return parsed
    }

    // MARK: - 内部辅助

    private static func isSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0 == "=" }
    }

    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 3 else { return nil }
        guard let oldStart = parseHunkStart(parts[1], prefix: "-"),
              let newStart = parseHunkStart(parts[2], prefix: "+") else { return nil }
        return (oldStart, newStart)
    }

    private static func parseHunkStart(_ token: String, prefix: Character) -> Int? {
        guard token.first == prefix else { return nil }
        let body = token.dropFirst()
        let start = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
        return Int(start)
    }

    private static func normalizePath(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            value = String(value.dropFirst(2))
        }
        return value
    }
}
