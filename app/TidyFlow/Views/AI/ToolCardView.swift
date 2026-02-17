import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 工具调用卡片：按工具类型展示关键字段，并保留通用 JSON 兜底。
struct ToolCardView: View {
    let name: String
    let state: [String: Any]?
    let callID: String?
    let partMetadata: [String: Any]?

    @State private var expandedSections: Set<String> = []

    private var normalizedToolID: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var invocation: AIToolInvocationState? {
        AIToolInvocationState.from(state: state)
    }

    private var headerDiffStats: (added: Int, removed: Int)? {
        guard ["edit", "write", "apply_patch", "multiedit"].contains(normalizedToolID),
              let invocation,
              let metadata = invocation.metadata,
              let diff = metadata["diff"] as? String,
              let parsed = AIDiffParser.parse(diff) else { return nil }
        return (parsed.addedCount, parsed.removedCount)
    }

    private var showsCopyButton: Bool {
        !["edit", "write", "apply_patch", "multiedit"].contains(normalizedToolID)
    }

    private var presentation: AIToolPresentation {
        guard let invocation else {
            var sections: [AIToolSection] = []
            if let partMetadata, !partMetadata.isEmpty {
                sections.append(section(id: "tool-part-metadata", title: "part_metadata", any: partMetadata))
            }
            if let state {
                sections.append(
                    AIToolSection(
                        id: "raw-state",
                        title: "state",
                        content: jsonText(state) ?? String(describing: state),
                        isCode: true
                    )
                )
            }
            return AIToolPresentation(
                toolID: normalizedToolID,
                displayTitle: name,
                statusText: "unknown",
                summary: nil,
                sections: sections
            )
        }

        var sections = buildSections(toolID: normalizedToolID, invocation: invocation)
        if let partMetadata, !partMetadata.isEmpty {
            sections.append(section(id: "tool-part-metadata", title: "part_metadata", any: partMetadata))
        }
        let displayTitle = invocation.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? invocation.title!
            : toolDisplayName(normalizedToolID)

        return AIToolPresentation(
            toolID: normalizedToolID,
            displayTitle: displayTitle,
            statusText: invocation.status.text,
            summary: toolSummary(toolID: normalizedToolID, invocation: invocation),
            sections: sections
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let summary = presentation.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(presentation.sections) { section in
                sectionBlock(section)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: toolIconName(toolID: presentation.toolID))
                .foregroundColor(statusColor)

            Text(presentation.displayTitle)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            if let duration = formattedDuration {
                Text(duration)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if let stats = headerDiffStats {
                Text("+\(stats.added)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.green)
                Text("-\(stats.removed)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.red)
            } else {
                Text(presentation.statusText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(statusColor)
            }
        }
    }

    private var statusColor: Color {
        guard let invocation else { return .secondary }
        switch invocation.status {
        case .pending, .running:
            return .orange
        case .completed:
            return .green
        case .error:
            return .red
        case .unknown:
            return .secondary
        }
    }

    private var formattedDuration: String? {
        guard let invocation else { return nil }
        guard let durationMs = invocation.durationMs else { return nil }
        if durationMs < 1000 {
            return String(format: "%.0fms", durationMs)
        }
        return String(format: "%.2fs", durationMs / 1000)
    }

    @ViewBuilder
    private func sectionBlock(_ section: AIToolSection) -> some View {
        if section.id == "edit-diff" {
            editDiffSectionBlock(section)
        } else if section.id == "read-file-path" {
            diagnosticsFileSectionBlock(section)
        } else if section.id == "lsp-diagnostics-file" {
            diagnosticsFileSectionBlock(section)
        } else if section.id == "edit-diagnostics" || section.id == "lsp-diagnostics-issues" {
            diagnosticsSectionBlock(section)
        } else {
            genericSectionBlock(section)
        }
    }

    @ViewBuilder
    private func genericSectionBlock(_ section: AIToolSection) -> some View {
        let lines = section.content.components(separatedBy: "\n")
        let needsCollapse = lines.count > 12
        let expanded = expandedSections.contains(section.id)
        let displayText = (!needsCollapse || expanded) ? section.content : lines.prefix(12).joined(separator: "\n")

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(section.title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                if needsCollapse {
                    Button(expanded ? "折叠" : "展开") {
                        if expanded {
                            expandedSections.remove(section.id)
                        } else {
                            expandedSections.insert(section.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                }
                if showsCopyButton {
                    Button("复制") {
                        copyToClipboard(section.content)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                }
            }

            Text(displayText)
                .textSelection(.enabled)
                .font(.system(size: 11, design: section.isCode ? .monospaced : .default))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if needsCollapse && !expanded {
                Text("…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(.top, 2)
    }

    private func buildSections(toolID: String, invocation: AIToolInvocationState) -> [AIToolSection] {
        switch toolID {
        case "read":
            return buildReadSections(invocation)
        case "edit", "write", "apply_patch", "multiedit":
            return buildEditLikeSections(invocation)
        case "lsp_diagnostics":
            return buildLspDiagnosticsSections(invocation)
        case "lsp":
            return buildLspSections(invocation)
        case "bash":
            return buildBashSections(invocation)
        case "grep", "glob", "list", "websearch", "codesearch", "webfetch":
            return buildSearchSections(invocation)
        case "task", "skill", "question", "plan_enter", "plan_exit", "todowrite", "todoread", "batch":
            return buildTaskSections(invocation)
        default:
            return buildGenericSections(invocation)
        }
    }

    private func buildReadSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []

        if let filePath = readFilePath(invocation), !filePath.isEmpty {
            sections.append(AIToolSection(id: "read-file-path", title: "file", content: filePath, isCode: true))
        }

        if let error = invocation.error, !error.isEmpty {
            sections.append(AIToolSection(id: "read-error", title: "error", content: error, isCode: false))
        }

        if sections.isEmpty {
            sections = buildGenericSections(invocation)
        }
        return sections
    }

    private func buildEditLikeSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []

        if let metadata = invocation.metadata {
            if let diff = metadata["diff"] as? String, !diff.isEmpty {
                sections.append(AIToolSection(id: "edit-diff", title: "diff", content: diff, isCode: true))
            }
            if let files = metadata["files"] as? [[String: Any]], !files.isEmpty {
                if let filesText = formattedEditFiles(files), !filesText.isEmpty {
                    sections.append(AIToolSection(id: "edit-files", title: "files", content: filesText, isCode: true))
                }
            }
            if let diagnostics = metadata["diagnostics"] {
                let parsedDiagnostics = parseDiagnosticsAny(diagnostics)
                if !parsedDiagnostics.isEmpty {
                    sections.append(section(id: "edit-diagnostics", title: "diagnostics", any: diagnostics))
                }
            }
            if sections.isEmpty && !invocation.input.isEmpty {
                sections.append(section(id: "edit-input", title: "input", any: compactEditInput(invocation.input)))
            }
            if sections.isEmpty, !metadata.isEmpty {
                sections.append(section(id: "edit-metadata", title: "metadata", any: metadata))
            }
        } else if !invocation.input.isEmpty {
            sections.append(section(id: "edit-input", title: "input", any: compactEditInput(invocation.input)))
        }

        if let error = invocation.error, !error.isEmpty {
            sections.append(AIToolSection(id: "edit-error", title: "error", content: error, isCode: false))
        }

        return sections
    }

    private func buildLspDiagnosticsSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []

        if let filePath = lspDiagnosticsFilePath(invocation), !filePath.isEmpty {
            sections.append(AIToolSection(id: "lsp-diagnostics-file", title: "file", content: filePath, isCode: true))
        }

        if let (items, raw) = lspDiagnosticsItems(invocation), !items.isEmpty {
            sections.append(section(id: "lsp-diagnostics-issues", title: "issues", any: raw))
        }

        if let error = invocation.error, !error.isEmpty {
            sections.append(AIToolSection(id: "lsp-diagnostics-error", title: "error", content: error, isCode: false))
        }

        return sections
    }

    private func buildLspSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []

        if !invocation.input.isEmpty {
            sections.append(section(id: "lsp-input", title: "input", any: invocation.input))
        }

        if let output = invocation.output, !output.isEmpty {
            sections.append(AIToolSection(id: "lsp-output", title: "output", content: output, isCode: true))
        }

        if let metadata = invocation.metadata, !metadata.isEmpty {
            sections.append(section(id: "lsp-metadata", title: "metadata", any: metadata))
        }

        if let error = invocation.error, !error.isEmpty {
            sections.append(AIToolSection(id: "lsp-error", title: "error", content: error, isCode: false))
        }

        return sections
    }

    private func buildBashSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []

        if let command = stringValue(invocation.input["command"]),
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(AIToolSection(id: "bash-command", title: "command", content: command, isCode: true))
        }

        var remainingInput = invocation.input
        remainingInput.removeValue(forKey: "command")
        remainingInput.removeValue(forKey: "description")
        if !remainingInput.isEmpty {
            sections.append(section(id: "bash-input", title: "input", any: remainingInput))
        }

        if let output = invocation.output, !output.isEmpty {
            sections.append(AIToolSection(id: "bash-output", title: "output", content: output, isCode: true))
        }

        if let error = invocation.error, !error.isEmpty {
            sections.append(AIToolSection(id: "bash-error", title: "error", content: error, isCode: false))
        }

        return sections
    }

    private func buildSearchSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []

        if !invocation.input.isEmpty {
            sections.append(section(id: "search-input", title: "input", any: invocation.input))
        }

        if let output = invocation.output, !output.isEmpty {
            sections.append(AIToolSection(id: "search-output", title: "output", content: output, isCode: true))
        }

        if let metadata = invocation.metadata, !metadata.isEmpty {
            sections.append(section(id: "search-metadata", title: "metadata", any: metadata))
        }

        if let error = invocation.error, !error.isEmpty {
            sections.append(AIToolSection(id: "search-error", title: "error", content: error, isCode: false))
        }

        return sections
    }

    private func buildTaskSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []

        if !invocation.input.isEmpty {
            sections.append(section(id: "task-input", title: "input", any: invocation.input))
        }

        if let output = invocation.output, !output.isEmpty {
            sections.append(AIToolSection(id: "task-output", title: "output", content: output, isCode: true))
        }

        if let metadata = invocation.metadata, !metadata.isEmpty {
            sections.append(section(id: "task-metadata", title: "metadata", any: metadata))
        }

        if let error = invocation.error, !error.isEmpty {
            sections.append(AIToolSection(id: "task-error", title: "error", content: error, isCode: false))
        }

        return sections
    }

    private func buildGenericSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []

        if !invocation.input.isEmpty {
            sections.append(section(id: "generic-input", title: "input", any: invocation.input))
        }

        if let raw = invocation.raw, !raw.isEmpty {
            sections.append(AIToolSection(id: "generic-raw", title: "raw", content: raw, isCode: true))
        }

        if let output = invocation.output, !output.isEmpty {
            sections.append(AIToolSection(id: "generic-output", title: "output", content: output, isCode: true))
        }

        if let error = invocation.error, !error.isEmpty {
            sections.append(AIToolSection(id: "generic-error", title: "error", content: error, isCode: false))
        }

        if let metadata = invocation.metadata, !metadata.isEmpty {
            sections.append(section(id: "generic-metadata", title: "metadata", any: metadata))
        }

        if let attachments = invocation.attachments, !attachments.isEmpty {
            sections.append(section(id: "generic-attachments", title: "attachments", any: attachments))
        }

        return sections
    }

    private func toolSummary(toolID: String, invocation: AIToolInvocationState) -> String? {
        switch toolID {
        case "read":
            return nil
        case "edit", "write", "apply_patch", "multiedit":
            return nil
        case "lsp_diagnostics":
            return nil
        case "lsp":
            let op = stringValue(invocation.input["operation"]) ?? "lsp"
            let file = stringValue(invocation.input["filePath"]) ?? ""
            let line = stringValue(invocation.input["line"]) ?? ""
            let ch = stringValue(invocation.input["character"]) ?? ""
            return [op, file, [line, ch].filter { !$0.isEmpty }.joined(separator: ":")]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case "bash":
            return nil
        case "grep", "glob", "list", "websearch", "codesearch", "webfetch":
            return stringValue(invocation.input["query"]) ??
                stringValue(invocation.input["pattern"]) ??
                stringValue(invocation.input["url"]) ??
                stringValue(invocation.input["path"])
        default:
            return nil
        }
    }

    private func toolDisplayName(_ toolID: String) -> String {
        switch toolID {
        case "read": return "read"
        case "edit": return "edit"
        case "write": return "write"
        case "apply_patch": return "apply_patch"
        case "lsp_diagnostics": return "lsp_diagnostics"
        case "lsp": return "lsp"
        case "bash": return "bash"
        case "grep": return "grep"
        case "glob": return "glob"
        case "list": return "list"
        case "websearch": return "websearch"
        case "codesearch": return "codesearch"
        case "webfetch": return "webfetch"
        case "task": return "task"
        case "skill": return "skill"
        case "question": return "question"
        case "plan_enter": return "plan_enter"
        case "plan_exit": return "plan_exit"
        case "todowrite": return "todowrite"
        case "todoread": return "todoread"
        case "batch": return "batch"
        default: return toolID.isEmpty ? "tool" : toolID
        }
    }

    private func toolIconName(toolID: String) -> String {
        switch toolID {
        case "read":
            return "eye"
        case "edit", "write", "apply_patch", "multiedit":
            return "square.and.pencil"
        case "lsp_diagnostics":
            return "stethoscope"
        case "lsp":
            return "point.3.connected.trianglepath.dotted"
        case "bash":
            return "terminal"
        case "grep", "glob", "list", "websearch", "codesearch", "webfetch":
            return "magnifyingglass"
        case "task", "skill", "question", "plan_enter", "plan_exit":
            return "list.bullet.clipboard"
        case "todowrite", "todoread":
            return "checklist"
        case "batch":
            return "square.stack.3d.up"
        default:
            return "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    private func editDiffSectionBlock(_ section: AIToolSection) -> some View {
        if let parsed = AIDiffParser.parse(section.content) {
            UnifiedDiffView(diff: parsed)
                .padding(.top, 2)
        } else {
            genericSectionBlock(section)
        }
    }

    @ViewBuilder
    private func diagnosticsFileSectionBlock(_ section: AIToolSection) -> some View {
        Text(section.content)
            .textSelection(.enabled)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    @ViewBuilder
    private func diagnosticsSectionBlock(_ section: AIToolSection) -> some View {
        let diagnostics = parseDiagnostics(section.content)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(section.title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }

            if diagnostics.isEmpty {
                Text(section.content)
                    .textSelection(.enabled)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(diagnostics) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.severity.uppercased())
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(diagnosticSeverityColor(item.severity))
                                if let location = item.location, !location.isEmpty {
                                    Text(location)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(item.message)
                                .textSelection(.enabled)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let code = item.code, !code.isEmpty {
                                Text(code)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func diagnosticSeverityColor(_ severity: String) -> Color {
        switch severity {
        case "error":
            return .red
        case "warning":
            return .orange
        case "hint":
            return .mint
        default:
            return .secondary
        }
    }

    private func parseDiagnostics(_ jsonString: String) -> [ToolDiagnosticItem] {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return parseDiagnosticsAny(root)
    }

    private func parseDiagnosticsAny(_ root: Any) -> [ToolDiagnosticItem] {
        if let array = root as? [[String: Any]] {
            return array.enumerated().compactMap { parseDiagnostic(dict: $0.element, index: $0.offset, fallbackPath: nil) }
        }
        if let dict = root as? [String: Any] {
            if let items = dict["items"] as? [[String: Any]] {
                return items.enumerated().compactMap { parseDiagnostic(dict: $0.element, index: $0.offset, fallbackPath: nil) }
            }
            var perFileItems: [ToolDiagnosticItem] = []
            var idx = 0
            for (filePath, value) in dict.sorted(by: { $0.key < $1.key }) {
                if let diagArray = value as? [[String: Any]] {
                    for diag in diagArray {
                        if let parsed = parseDiagnostic(dict: diag, index: idx, fallbackPath: filePath) {
                            perFileItems.append(parsed)
                            idx += 1
                        }
                    }
                } else if let diagDict = value as? [String: Any] {
                    if let parsed = parseDiagnostic(dict: diagDict, index: idx, fallbackPath: filePath) {
                        perFileItems.append(parsed)
                        idx += 1
                    }
                }
            }
            if !perFileItems.isEmpty { return perFileItems }
            if let single = parseDiagnostic(dict: dict, index: 0, fallbackPath: nil) {
                return [single]
            }
        }
        return []
    }

    private func lspDiagnosticsFilePath(_ invocation: AIToolInvocationState) -> String? {
        stringValue(invocation.input["filePath"]) ??
            stringValue(invocation.input["path"]) ??
            stringValue(invocation.input["file"]) ??
            stringValue(invocation.input["uri"])
    }

    private func readFilePath(_ invocation: AIToolInvocationState) -> String? {
        stringValue(invocation.input["filePath"]) ??
            stringValue(invocation.input["path"]) ??
            stringValue(invocation.input["file"]) ??
            stringValue(invocation.input["uri"])
    }

    private func lspDiagnosticsItems(_ invocation: AIToolInvocationState) -> (items: [ToolDiagnosticItem], raw: Any)? {
        if let metadata = invocation.metadata {
            let metadataCandidates: [Any] = [
                metadata["diagnostics"],
                metadata["items"],
                metadata["issues"],
                metadata["problems"],
                metadata
            ].compactMap { $0 }
            for candidate in metadataCandidates {
                let items = parseDiagnosticsAny(candidate)
                if !items.isEmpty {
                    return (items, candidate)
                }
            }
        }

        if let output = invocation.output,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = output.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) {
            let items = parseDiagnosticsAny(raw)
            if !items.isEmpty {
                return (items, raw)
            }
        }

        return nil
    }

    private func parseDiagnostic(dict: [String: Any], index: Int, fallbackPath: String?) -> ToolDiagnosticItem? {
        let message =
            stringValue(dict["message"]) ??
            stringValue(dict["msg"]) ??
            stringValue(dict["text"]) ??
            stringValue(dict["detail"]) ?? ""
        guard !message.isEmpty else { return nil }
        let severityRaw =
            stringValue(dict["severity"]) ??
            stringValue(dict["level"]) ??
            stringValue(dict["type"]) ?? "info"
        let severity = normalizeSeverity(severityRaw)
        let path =
            stringValue(dict["path"]) ??
            stringValue(dict["filePath"]) ??
            stringValue(dict["file"]) ??
            stringValue(dict["uri"]) ?? fallbackPath
        let line = intValue(dict["line"]) ?? intValue(dict["row"]) ?? nestedInt(dict, keys: ["range", "start", "line"])
        let column = intValue(dict["column"]) ?? intValue(dict["col"]) ?? intValue(dict["character"]) ??
            nestedInt(dict, keys: ["range", "start", "character"])
        let location: String? = {
            var parts: [String] = []
            if let path, !path.isEmpty { parts.append(path) }
            var lineCol = ""
            if let line {
                lineCol = String(line)
                if let column { lineCol += ":\(column)" }
            }
            if !lineCol.isEmpty { parts.append(lineCol) }
            return parts.isEmpty ? nil : parts.joined(separator: ":")
        }()
        let code = stringValue(dict["code"]) ?? stringValue(dict["rule"]) ?? stringValue(dict["source"])
        return ToolDiagnosticItem(
            id: "diag-\(index)-\(message)", severity: severity,
            message: message, location: location, code: code
        )
    }

    private func normalizeSeverity(_ raw: String) -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if token == "1" || token.contains("error") { return "error" }
        if token == "2" || token.contains("warn") { return "warning" }
        if token == "3" || token.contains("info") { return "info" }
        if token == "4" || token.contains("hint") { return "hint" }
        return token.isEmpty ? "info" : token
    }

    private func formattedEditFiles(_ files: [[String: Any]]) -> String? {
        let lines = files.compactMap { file -> String? in
            let path =
                stringValue(file["path"]) ??
                stringValue(file["filePath"]) ??
                stringValue(file["file"]) ??
                stringValue(file["filepath"])
            let change =
                stringValue(file["change"]) ??
                stringValue(file["status"]) ??
                stringValue(file["action"]) ??
                stringValue(file["type"])
            let parts: [String] = [change, path].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "  ")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func compactEditInput(_ input: [String: Any]) -> [String: Any] {
        let hiddenKeys: Set<String> = [
            "oldString", "newString", "content", "patch", "diff", "replacement", "original"
        ]
        var compact: [String: Any] = [:]
        for (key, value) in input {
            guard !hiddenKeys.contains(key) else { continue }
            compact[key] = value
        }
        return compact.isEmpty ? input : compact
    }

    private func nestedInt(_ dict: [String: Any], keys: [String]) -> Int? {
        guard !keys.isEmpty else { return nil }
        var current: Any = dict
        for key in keys {
            guard let object = current as? [String: Any], let next = object[key] else { return nil }
            current = next
        }
        return intValue(current)
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let v as Int:
            return v
        case let v as Int64:
            return Int(v)
        case let v as UInt:
            return Int(v)
        case let v as NSNumber:
            return v.intValue
        case let v as String:
            return Int(v)
        default:
            return nil
        }
    }

    private func section(id: String, title: String, any: Any) -> AIToolSection {
        AIToolSection(
            id: id,
            title: title,
            content: jsonText(any) ?? String(describing: any),
            isCode: true
        )
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let v as String:
            return v
        case let v as Bool:
            return v ? "true" : "false"
        case let v as NSNumber:
            return v.stringValue
        case let v as [String: Any]:
            return jsonText(v)
        case let v as [Any]:
            return jsonText(v)
        default:
            return nil
        }
    }

    private func jsonText(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

private struct ToolDiagnosticItem: Identifiable {
    let id: String
    let severity: String
    let message: String
    let location: String?
    let code: String?
}
