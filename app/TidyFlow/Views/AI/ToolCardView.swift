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
    let pendingQuestion: AIQuestionRequestInfo?
    let onQuestionReply: (([[String]]) -> Void)?
    let onQuestionReject: (() -> Void)?

    init(
        name: String,
        state: [String: Any]?,
        callID: String?,
        partMetadata: [String: Any]?,
        pendingQuestion: AIQuestionRequestInfo? = nil,
        onQuestionReply: (([[String]]) -> Void)? = nil,
        onQuestionReject: (() -> Void)? = nil
    ) {
        self.name = name
        self.state = state
        self.callID = callID
        self.partMetadata = partMetadata
        self.pendingQuestion = pendingQuestion
        self.onQuestionReply = onQuestionReply
        self.onQuestionReject = onQuestionReject
    }

    @State private var expandedSections: Set<String> = []

    private struct CachedRenderModel {
        let invocation: AIToolInvocationState?
        let presentation: AIToolPresentation
        let headerDiffStats: (added: Int, removed: Int)?
    }

    private static let renderCacheLimit = 200
    private static let renderCacheLock = NSLock()
    private static var renderCache: [String: CachedRenderModel] = [:]
    private static var renderCacheOrder: [String] = []

    private var normalizedToolID: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var renderCacheKey: String {
        [
            normalizedToolID,
            callID ?? "",
            stableRenderHash(state),
            stableRenderHash(partMetadata),
            pendingQuestion?.id ?? ""
        ].joined(separator: "|")
    }

    private var renderModel: CachedRenderModel {
        if let cached = Self.cachedRenderModel(forKey: renderCacheKey) {
            return cached
        }
        let built = buildRenderModel()
        Self.storeRenderModel(built, forKey: renderCacheKey)
        return built
    }

    private var invocation: AIToolInvocationState? {
        renderModel.invocation
    }

    private var headerDiffStats: (added: Int, removed: Int)? {
        renderModel.headerDiffStats
    }

    private var showsCopyButton: Bool {
        !["edit", "write", "apply_patch", "multiedit"].contains(normalizedToolID)
    }

    private var presentation: AIToolPresentation {
        renderModel.presentation
    }

    private var questionPromptItems: [ToolQuestionPromptItem] {
        questionPromptItems(from: invocation)
    }

    private var questionPromptInteractive: Bool {
        questionPromptInteractive(toolID: normalizedToolID, invocation: invocation)
    }

    private var shouldShowQuestionPrompt: Bool {
        shouldShowQuestionPrompt(
            toolID: normalizedToolID,
            invocation: invocation,
            promptItems: questionPromptItems
        )
    }

    private func buildRenderModel() -> CachedRenderModel {
        let invocation = AIToolInvocationState.from(state: state)
        let headerDiffStats: (added: Int, removed: Int)? = {
            guard ["edit", "write", "apply_patch", "multiedit"].contains(normalizedToolID),
                  let invocation,
                  let metadata = invocation.metadata,
                  let diff = metadata["diff"] as? String,
                  let parsed = AIDiffParser.parse(diff) else { return nil }
            return (parsed.addedCount, parsed.removedCount)
        }()

        guard let invocation else {
            var sections: [AIToolSection] = []
            if normalizedToolID != "question",
               let partMetadata,
               !partMetadata.isEmpty {
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
            let presentation = AIToolPresentation(
                toolID: normalizedToolID,
                displayTitle: name,
                statusText: "unknown",
                summary: nil,
                sections: sections
            )
            return CachedRenderModel(
                invocation: nil,
                presentation: presentation,
                headerDiffStats: headerDiffStats
            )
        }

        var sections = buildSections(toolID: normalizedToolID, invocation: invocation)
        if normalizedToolID != "question",
           let partMetadata,
           !partMetadata.isEmpty {
            sections.append(section(id: "tool-part-metadata", title: "part_metadata", any: partMetadata))
        }
        let displayTitle = toolCardTitle(toolID: normalizedToolID, invocation: invocation)

        let presentation = AIToolPresentation(
            toolID: normalizedToolID,
            displayTitle: displayTitle,
            statusText: invocation.status.text,
            summary: toolSummary(toolID: normalizedToolID, invocation: invocation),
            sections: sections
        )
        return CachedRenderModel(
            invocation: invocation,
            presentation: presentation,
            headerDiffStats: headerDiffStats
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let summary = presentation.summary, !summary.isEmpty, !isTodoTool {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if shouldShowQuestionPrompt {
                ToolQuestionPromptView(
                    items: questionPromptItems,
                    interactive: questionPromptInteractive,
                    onReply: onQuestionReply,
                    onReject: onQuestionReject
                )
                .id(pendingQuestion?.id ?? "question-prompt-\(callID ?? "")")
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
                .foregroundColor(.primary)

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

    private var isTodoTool: Bool {
        presentation.toolID == "todowrite" || presentation.toolID == "todoread"
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
        } else if section.id == "todo-items" {
            todoSectionBlock(section)
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
        case "grep":
            return buildGrepSections(invocation)
        case "edit", "write", "apply_patch", "multiedit":
            return buildEditLikeSections(invocation)
        case "lsp_diagnostics":
            return buildLspDiagnosticsSections(invocation)
        case "lsp":
            return buildLspSections(invocation)
        case "bash":
            return buildBashSections(invocation)
        case "glob", "list", "websearch", "codesearch", "webfetch":
            return buildSearchSections(invocation)
        case "todowrite", "todoread":
            return buildTodoSections(invocation)
        case "question":
            return buildQuestionSections(invocation)
        case "task", "skill", "plan_enter", "plan_exit", "batch":
            return buildTaskSections(invocation)
        default:
            return buildGenericSections(invocation)
        }
    }

    private func buildReadSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        // read 卡片仅展示头部（标题 + 状态），不展示正文内容区
        _ = invocation
        return []
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

    private func buildGrepSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []

        if let error = invocation.error, !error.isEmpty {
            sections.append(AIToolSection(id: "grep-error", title: "error", content: error, isCode: false))
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

    private func buildQuestionSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []
        let promptItems = questionPromptItems(from: invocation)
        // 避免在 renderModel 构建链路中反向读取 shouldShowQuestionPrompt 触发递归。
        let showPrompt = shouldShowQuestionPrompt(
            toolID: normalizedToolID,
            invocation: invocation,
            promptItems: promptItems
        )

        // question 处于待回答阶段时，交互区已单独渲染；避免重复展示大段 input JSON。
        if !showPrompt, !invocation.input.isEmpty {
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

    private func buildTodoSections(_ invocation: AIToolInvocationState) -> [AIToolSection] {
        var sections: [AIToolSection] = []
        let items = todoItems(invocation)

        if !items.isEmpty {
            let payload = items.map { item in
                var dict: [String: String] = [
                    "content": item.content,
                    "status": item.status
                ]
                if let priority = item.priority, !priority.isEmpty {
                    dict["priority"] = priority
                }
                return dict
            }
            if let text = jsonText(payload) {
                sections.append(AIToolSection(id: "todo-items", title: "todos", content: text, isCode: true))
            }
        } else {
            sections.append(AIToolSection(id: "todo-empty", title: "todos", content: "暂无任务", isCode: false))
        }

        if let error = invocation.error, !error.isEmpty {
            sections.append(AIToolSection(id: "todo-error", title: "error", content: error, isCode: false))
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
        case "grep":
            return grepStatsSummary(invocation)
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
        case "glob", "list", "websearch", "codesearch", "webfetch":
            return stringValue(invocation.input["query"]) ??
                stringValue(invocation.input["pattern"]) ??
                stringValue(invocation.input["url"]) ??
                stringValue(invocation.input["path"])
        case "todowrite", "todoread":
            return nil
        default:
            return nil
        }
    }

    private func toolCardTitle(toolID: String, invocation: AIToolInvocationState) -> String {
        if toolID == "grep", let keyword = grepKeyword(invocation), !keyword.isEmpty {
            return "grep(\(keyword))"
        }
        if toolID == "todowrite" || toolID == "todoread" {
            return todoSummary(invocation) ?? "任务列表"
        }
        if let title = invocation.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return toolDisplayName(toolID)
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
        case "question":
            return "questionmark.circle"
        case "task", "skill", "plan_enter", "plan_exit":
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

    @ViewBuilder
    private func todoSectionBlock(_ section: AIToolSection) -> some View {
        let items = parseTodoItems(section.content)

        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Text("暂无任务")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(todoStatusLabel(item.status))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(todoStatusColor(item.status))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(todoStatusColor(item.status).opacity(0.12))
                                .cornerRadius(6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.content)
                                    .textSelection(.enabled)
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let priority = item.priority, !priority.isEmpty {
                                    Text("优先级：\(priority)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
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

    private func grepStatsSummary(_ invocation: AIToolInvocationState) -> String? {
        var stats: String?
        if let metadata = invocation.metadata {
            let matchCount =
                intValue(metadata["matches"]) ??
                intValue(metadata["matchCount"]) ??
                intValue(metadata["matched"])
            let fileCount =
                intValue(metadata["files"]) ??
                intValue(metadata["fileCount"])
            if let matchCount, let fileCount {
                stats = "Found \(matchCount) match(es) in \(fileCount) file(s)"
            } else if let matchCount {
                stats = "Found \(matchCount) match(es)"
            }
        }

        if stats == nil, let output = invocation.output {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
            if let statsLine = lines.first(where: { $0.contains("match(es)") && $0.contains("file(s)") }) {
                stats = statsLine.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let first = lines.first {
                stats = first.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return stats
    }

    private func grepKeyword(_ invocation: AIToolInvocationState) -> String? {
        stringValue(invocation.input["pattern"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ??
            stringValue(invocation.input["query"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func todoSummary(_ invocation: AIToolInvocationState) -> String? {
        let items = todoItems(invocation)
        guard !items.isEmpty else { return nil }

        let total = items.count
        let completed = items.filter { $0.status == "completed" }.count
        let running = items.filter { $0.status == "in_progress" }.count
        let pending = items.filter { $0.status == "pending" }.count

        var parts: [String] = ["\(total) 项任务"]
        if completed > 0 { parts.append("已完成 \(completed)") }
        if running > 0 { parts.append("进行中 \(running)") }
        if pending > 0 { parts.append("待处理 \(pending)") }
        return parts.joined(separator: " · ")
    }

    private func todoItems(_ invocation: AIToolInvocationState) -> [ToolTodoItem] {
        var candidates: [Any] = []

        if let metadata = invocation.metadata {
            candidates.append(metadata)
            if let todos = metadata["todos"] { candidates.append(todos) }
            if let items = metadata["items"] { candidates.append(items) }
            if let tasks = metadata["tasks"] { candidates.append(tasks) }
        }

        if !invocation.input.isEmpty {
            candidates.append(invocation.input)
            if let todos = invocation.input["todos"] { candidates.append(todos) }
            if let items = invocation.input["items"] { candidates.append(items) }
            if let tasks = invocation.input["tasks"] { candidates.append(tasks) }
        }

        if let output = invocation.output,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let parsed = parseJSONText(output) {
            candidates.append(parsed)
        }

        if let raw = invocation.raw,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let parsed = parseJSONText(raw) {
            candidates.append(parsed)
        }

        for candidate in candidates {
            let parsed = parseTodoItemsAny(candidate)
            if !parsed.isEmpty {
                return parsed
            }
        }
        return []
    }

    private func parseTodoItems(_ jsonString: String) -> [ToolTodoItem] {
        guard let root = parseJSONText(jsonString) else { return [] }
        return parseTodoItemsAny(root)
    }

    private func parseJSONText(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func parseTodoItemsAny(_ root: Any) -> [ToolTodoItem] {
        if let array = root as? [[String: Any]] {
            return array.enumerated().compactMap { parseTodoItem(dict: $0.element, index: $0.offset) }
        }
        if let dict = root as? [String: Any] {
            if let todos = dict["todos"] {
                let parsed = parseTodoItemsAny(todos)
                if !parsed.isEmpty { return parsed }
            }
            if let items = dict["items"] {
                let parsed = parseTodoItemsAny(items)
                if !parsed.isEmpty { return parsed }
            }
            if let tasks = dict["tasks"] {
                let parsed = parseTodoItemsAny(tasks)
                if !parsed.isEmpty { return parsed }
            }
            if let list = dict["list"] {
                let parsed = parseTodoItemsAny(list)
                if !parsed.isEmpty { return parsed }
            }
            if let data = dict["data"] {
                let parsed = parseTodoItemsAny(data)
                if !parsed.isEmpty { return parsed }
            }
            if let item = parseTodoItem(dict: dict, index: 0) {
                return [item]
            }
        }
        return []
    }

    private func parseTodoItem(dict: [String: Any], index: Int) -> ToolTodoItem? {
        let content =
            stringValue(dict["content"]) ??
            stringValue(dict["title"]) ??
            stringValue(dict["text"]) ??
            stringValue(dict["task"]) ??
            stringValue(dict["name"]) ?? ""
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else { return nil }

        let rawStatus =
            stringValue(dict["status"]) ??
            stringValue(dict["state"]) ??
            stringValue(dict["phase"]) ?? "pending"
        let status = normalizeTodoStatus(rawStatus)
        let priority = stringValue(dict["priority"])?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ToolTodoItem(
            id: "todo-\(index)-\(normalizedContent)-\(status)",
            content: normalizedContent,
            status: status,
            priority: priority
        )
    }

    private func normalizeTodoStatus(_ raw: String) -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if token.contains("progress") || token == "running" { return "in_progress" }
        if token == "done" || token == "complete" || token == "completed" || token == "success" { return "completed" }
        if token == "cancelled" || token == "canceled" { return "canceled" }
        if token == "pending" || token == "todo" || token == "queued" { return "pending" }
        return token.isEmpty ? "pending" : token
    }

    private func todoStatusLabel(_ status: String) -> String {
        switch status {
        case "completed":
            return "已完成"
        case "in_progress":
            return "进行中"
        case "canceled":
            return "已取消"
        case "pending":
            return "待处理"
        default:
            return status
        }
    }

    private func todoStatusColor(_ status: String) -> Color {
        switch status {
        case "completed":
            return .green
        case "in_progress":
            return .orange
        case "canceled":
            return .secondary
        case "pending":
            return .blue
        default:
            return .secondary
        }
    }

    private func parseQuestionPromptItems(from root: Any?) -> [ToolQuestionPromptItem] {
        guard let root else { return [] }
        if let array = root as? [[String: Any]] {
            return array.enumerated().compactMap { parseQuestionPromptItem(dict: $0.element, index: $0.offset) }
        }
        if let array = root as? [Any] {
            return array.enumerated().compactMap { item in
                guard let dict = item.element as? [String: Any] else { return nil }
                return parseQuestionPromptItem(dict: dict, index: item.offset)
            }
        }
        if let dict = root as? [String: Any] {
            if let questions = dict["questions"] {
                let parsed = parseQuestionPromptItems(from: questions)
                if !parsed.isEmpty { return parsed }
            }
            if let item = parseQuestionPromptItem(dict: dict, index: 0) {
                return [item]
            }
        }
        return []
    }

    private func questionPromptItems(from invocation: AIToolInvocationState?) -> [ToolQuestionPromptItem] {
        if let pendingQuestion, !pendingQuestion.questions.isEmpty {
            return pendingQuestion.questions.map { item in
                ToolQuestionPromptItem(
                    question: item.question,
                    header: item.header,
                    options: item.options.map {
                        ToolQuestionPromptOption(label: $0.label, description: $0.description)
                    },
                    multiple: item.multiple,
                    custom: item.custom
                )
            }
        }
        guard let invocation else { return [] }
        return parseQuestionPromptItems(from: invocation.input["questions"])
    }

    private func questionPromptInteractive(
        toolID: String,
        invocation: AIToolInvocationState?
    ) -> Bool {
        guard toolID == "question" else { return false }
        guard pendingQuestion != nil else { return false }
        guard let invocation else { return false }
        return invocation.status == .pending || invocation.status == .running
    }

    private func shouldShowQuestionPrompt(
        toolID: String,
        invocation: AIToolInvocationState?,
        promptItems: [ToolQuestionPromptItem]
    ) -> Bool {
        guard toolID == "question" else { return false }
        guard !promptItems.isEmpty else { return false }
        if questionPromptInteractive(toolID: toolID, invocation: invocation) {
            return true
        }
        guard let invocation else { return false }
        return invocation.status == .pending || invocation.status == .running
    }

    private func parseQuestionPromptItem(dict: [String: Any], index: Int) -> ToolQuestionPromptItem? {
        let question =
            stringValue(dict["question"]) ??
            stringValue(dict["prompt"]) ??
            stringValue(dict["text"]) ?? ""
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuestion.isEmpty else { return nil }

        let header = (stringValue(dict["header"]) ?? stringValue(dict["name"]) ?? "问题\(index + 1)")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var options: [ToolQuestionPromptOption] = []
        if let optionArray = dict["options"] as? [[String: Any]] {
            options = optionArray.compactMap { option in
                let label = (stringValue(option["label"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return nil }
                let description = (stringValue(option["description"]) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ToolQuestionPromptOption(label: label, description: description)
            }
        } else if let choiceArray = dict["choices"] as? [String] {
            options = choiceArray.compactMap { raw in
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return nil }
                return ToolQuestionPromptOption(label: label, description: "")
            }
        }

        return ToolQuestionPromptItem(
            question: normalizedQuestion,
            header: header.isEmpty ? "问题\(index + 1)" : header,
            options: options,
            multiple: boolValue(dict["multiple"]) ?? false,
            custom: boolValue(dict["custom"]) ?? true
        )
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

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let v as Bool:
            return v
        case let v as Int:
            return v != 0
        case let v as NSNumber:
            return v.boolValue
        case let v as String:
            let token = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(token) { return true }
            if ["false", "0", "no", "n"].contains(token) { return false }
            return nil
        default:
            return nil
        }
    }

    private func stableRenderHash(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let dict = value as? [String: Any],
           let text = jsonText(dict) {
            return "\(text.count):\(text.hashValue)"
        }
        if let array = value as? [Any],
           let text = jsonText(array) {
            return "\(text.count):\(text.hashValue)"
        }
        let text = String(describing: value)
        return "\(text.count):\(text.hashValue)"
    }

    private static func cachedRenderModel(forKey key: String) -> CachedRenderModel? {
        renderCacheLock.lock()
        defer { renderCacheLock.unlock() }
        guard let model = renderCache[key] else { return nil }
        if let idx = renderCacheOrder.firstIndex(of: key) {
            renderCacheOrder.remove(at: idx)
        }
        renderCacheOrder.append(key)
        return model
    }

    private static func storeRenderModel(_ model: CachedRenderModel, forKey key: String) {
        renderCacheLock.lock()
        defer { renderCacheLock.unlock() }
        renderCache[key] = model
        if let idx = renderCacheOrder.firstIndex(of: key) {
            renderCacheOrder.remove(at: idx)
        }
        renderCacheOrder.append(key)
        if renderCacheOrder.count > renderCacheLimit, let evict = renderCacheOrder.first {
            renderCacheOrder.removeFirst()
            renderCache.removeValue(forKey: evict)
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

private struct ToolQuestionPromptOption: Identifiable {
    var id: String { label }
    let label: String
    let description: String
}

private struct ToolQuestionPromptItem: Identifiable {
    var id: String { "\(header)|\(question)" }
    let question: String
    let header: String
    let options: [ToolQuestionPromptOption]
    let multiple: Bool
    let custom: Bool
}

private struct ToolQuestionPromptView: View {
    let items: [ToolQuestionPromptItem]
    let interactive: Bool
    let onReply: (([[String]]) -> Void)?
    let onReject: (() -> Void)?

    @State private var tab: Int = 0
    @State private var answers: [Int: [String]] = [:]
    @State private var customInputs: [Int: String] = [:]
    @State private var editingCustom: Bool = false

    private var isSingleAutoSubmit: Bool {
        items.count == 1 && !(items.first?.multiple ?? false)
    }

    private var currentItem: ToolQuestionPromptItem? {
        guard tab >= 0, tab < items.count else { return nil }
        return items[tab]
    }

    private var isConfirmStep: Bool {
        !isSingleAutoSubmit && tab == items.count
    }

    private var currentAnswers: [String] {
        answers[tab] ?? []
    }

    private var customInput: String {
        customInputs[tab] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isSingleAutoSubmit {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            Button(item.header) {
                                guard interactive else { return }
                                tab = index
                                editingCustom = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(tab == index ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((tab == index ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                            .cornerRadius(6)
                        }

                        Button("确认") {
                            guard interactive else { return }
                            tab = items.count
                            editingCustom = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isConfirmStep ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((isConfirmStep ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                        .cornerRadius(6)
                    }
                }
            }

            if isConfirmStep {
                VStack(alignment: .leading, spacing: 6) {
                    Text("请确认你的选择")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.question)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                            Text((answers[index] ?? []).isEmpty ? "未回答" : (answers[index] ?? []).joined(separator: "、"))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(8)
                    }
                }
            } else if let item = currentItem {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.question + (item.multiple ? "（可多选）" : ""))
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(item.options) { option in
                        let picked = currentAnswers.contains(option.label)
                        Button {
                            handleOptionTap(option: option.label, multiple: item.multiple)
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                if picked {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(picked ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(!interactive)
                    }

                    if item.custom {
                        Button {
                            guard interactive else { return }
                            editingCustom = true
                        } label: {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("自定义答案")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary)
                                    if !editingCustom && !customInput.isEmpty {
                                        Text(customInput)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                Spacer(minLength: 0)
                                if currentAnswers.contains(customInput), !customInput.isEmpty {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Color.secondary.opacity(0.06))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(!interactive)
                    }

                    if editingCustom {
                        HStack(spacing: 6) {
                            TextField("输入自定义答案", text: Binding(
                                get: { customInputs[tab] ?? "" },
                                set: { customInputs[tab] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            Button(item.multiple ? "添加" : "提交") {
                                submitCustom(multiple: item.multiple)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                            Button("取消") {
                                editingCustom = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if interactive {
                HStack(spacing: 10) {
                    if let onReject {
                        Button("忽略") {
                            onReject()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }

                    if !isSingleAutoSubmit {
                        if isConfirmStep {
                            Button("提交") {
                                submitAll()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                        } else if currentItem?.multiple == true {
                            Button("下一步") {
                                tab = min(items.count, tab + 1)
                                editingCustom = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor((currentAnswers.isEmpty) ? .secondary : .accentColor)
                            .disabled(currentAnswers.isEmpty)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private func handleOptionTap(option: String, multiple: Bool) {
        guard interactive else { return }
        if multiple {
            var next = answers[tab] ?? []
            if let idx = next.firstIndex(of: option) {
                next.remove(at: idx)
            } else {
                next.append(option)
            }
            answers[tab] = next
            return
        }
        answers[tab] = [option]
        if isSingleAutoSubmit {
            onReply?([[option]])
            return
        }
        tab = min(items.count, tab + 1)
        editingCustom = false
    }

    private func submitCustom(multiple: Bool) {
        guard interactive else { return }
        let value = (customInputs[tab] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            editingCustom = false
            return
        }
        if multiple {
            var next = answers[tab] ?? []
            if !next.contains(value) {
                next.append(value)
            }
            answers[tab] = next
            editingCustom = false
            return
        }
        answers[tab] = [value]
        if isSingleAutoSubmit {
            onReply?([[value]])
            return
        }
        tab = min(items.count, tab + 1)
        editingCustom = false
    }

    private func submitAll() {
        guard interactive else { return }
        let payload: [[String]] = items.enumerated().map { answers[$0.offset] ?? [] }
        onReply?(payload)
    }
}

private struct ToolDiagnosticItem: Identifiable {
    let id: String
    let severity: String
    let message: String
    let location: String?
    let code: String?
}

private struct ToolTodoItem: Identifiable {
    let id: String
    let content: String
    let status: String
    let priority: String?
}
