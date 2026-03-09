import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ToolCardView: View {
    let name: String
    let callID: String?
    let toolView: AIToolView?
    let questionRequest: AIQuestionRequestInfo?
    let onQuestionReply: (([[String]]) -> Void)?
    let onQuestionReject: (() -> Void)?
    let onQuestionReplyAsMessage: ((String) -> Void)?
    let onOpenLinkedSession: ((String) -> Void)?

    @State private var expandedSections: Set<String> = []
    @State private var isCardExpanded: Bool = false

    private var resolvedToolID: String {
        let candidate = (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "tool" : name)
        return candidate.lowercased()
    }

    private var displayTitle: String {
        toolView?.displayTitle ?? name
    }

    private var headerCommandSummary: String? {
        let command = toolView?.headerCommandSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command, !command.isEmpty else { return nil }
        return command
    }

    private var prefersCommandAsTitle: Bool {
        guard headerCommandSummary != nil else { return false }
        return resolvedToolID == "bash" || resolvedToolID == "terminal"
    }

    private var primaryHeaderText: String {
        if let command = headerCommandSummary, prefersCommandAsTitle {
            return command
        }
        return displayTitle
    }

    private var hasExpandableContent: Bool {
        let hasSummary = !(toolView?.summary?.isEmpty ?? true)
        let hasSections = !(toolView?.sections.isEmpty ?? true)
        let hasQuestion = questionRequest != nil
        return hasSummary || hasSections || hasQuestion
    }

    private var answeredSelections: [[String]]? {
        toolView?.question?.answers
    }

    private var questionItems: [ToolQuestionPromptItem] {
        let sourceItems: [AIQuestionInfo]
        if let request = questionRequest, !request.questions.isEmpty {
            sourceItems = request.questions
        } else {
            sourceItems = toolView?.question?.promptItems ?? []
        }
        return sourceItems.map { item in
            ToolQuestionPromptItem(
                question: item.question,
                header: item.header,
                options: item.options.map { option in
                    ToolQuestionPromptOption(
                        optionID: option.optionID,
                        label: option.label,
                        description: option.description
                    )
                },
                multiple: item.multiple,
                custom: item.custom
            )
        }
    }

    private var questionInteractive: Bool {
        toolView?.question?.interactive ?? false
    }

    private var linkedSession: AIToolLinkedSession? {
        toolView?.linkedSession
    }

    var body: some View {
        if let linkedSession {
            linkedSessionCard(linkedSession)
        } else {
            defaultCard
        }
    }

    private var defaultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isCardExpanded {
                if let summary = toolView?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !questionItems.isEmpty {
                    ToolQuestionPromptView(
                        items: questionItems,
                        interactive: questionInteractive,
                        answeredSelections: answeredSelections,
                        onReply: onQuestionReply,
                        onReject: onQuestionReject,
                        onReplyAsMessage: questionInteractive ? nil : onQuestionReplyAsMessage
                    )
                    .id(questionRequest?.id ?? toolView?.question?.requestID ?? "question-\(callID ?? "")")
                }

                ForEach(toolView?.sections ?? []) { section in
                    sectionView(section)
                }

                if let locations = toolView?.locations, !locations.isEmpty {
                    locationsView(locations)
                }
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
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            guard hasExpandableContent else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isCardExpanded.toggle()
            }
        }
        .onChange(of: questionInteractive) { _, newValue in
            if newValue {
                isCardExpanded = true
            }
        }
    }

    @ViewBuilder
    private func linkedSessionCard(_ linkedSession: AIToolLinkedSession) -> some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: toolIconName(resolvedToolID))
                    .foregroundColor(.primary)

                Text(linkedSession.agentName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                if let duration = formattedDuration {
                    Text(duration)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                statusIcon
            }

            Text(linkedSession.description)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)

        if let onOpenLinkedSession {
            content
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture {
                    onOpenLinkedSession(linkedSession.sessionID)
                }
        } else {
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: toolIconName(resolvedToolID))
                    .foregroundColor(.primary)

                Text(primaryHeaderText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(prefersCommandAsTitle ? .middle : .tail)

                Spacer()

                if let duration = formattedDuration {
                    Text(duration)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                if let diffStats = diffStats {
                    Text("+\(diffStats.added)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.green)
                    Text("-\(diffStats.removed)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red)
                } else {
                    statusIcon
                }

                if hasExpandableContent {
                    Image(systemName: isCardExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            if let command = headerCommandSummary, !prefersCommandAsTitle {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: AIToolViewSection) -> some View {
        switch section.style {
        case .diff:
            if let parsed = AIDiffParser.parse(section.content) {
                UnifiedDiffView(diff: parsed)
                    .padding(.top, 2)
            } else {
                genericSectionView(section)
            }
        case .markdown:
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(section)
                MarkdownTextView(
                    text: section.content,
                    baseFontSize: 12,
                    textColor: .secondary
                )
            }
            .padding(.top, 2)
        default:
            genericSectionView(section)
        }
    }

    private func genericSectionView(_ section: AIToolViewSection) -> some View {
        let lines = section.content.components(separatedBy: "\n")
        let needsCollapse = lines.count > 12 || section.collapsedByDefault
        let expanded = expandedSections.contains(section.id) || !section.collapsedByDefault
        let displayText = (!needsCollapse || expanded)
            ? section.content
            : lines.prefix(12).joined(separator: "\n")

        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader(section, expanded: expanded, needsCollapse: needsCollapse)

            if section.style == .code || section.style == .terminal || section.style == .diff {
                Text(displayText)
                    .textSelection(.enabled)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(4)
            } else {
                Text(displayText)
                    .textSelection(.enabled)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if needsCollapse && !expanded {
                Text("…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func sectionHeader(
        _ section: AIToolViewSection,
        expanded: Bool? = nil,
        needsCollapse: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Text(section.title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)

            if let language = section.language, !language.isEmpty,
               section.style == .code || section.style == .diff || section.style == .terminal {
                Text(language)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor.opacity(0.8))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(3)
            }

            Spacer()

            if needsCollapse, let expanded {
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

            if section.copyable {
                Button("复制") {
                    copyToClipboard(section.content)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            }
        }
    }

    private func locationsView(_ locations: [AIToolViewLocation]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("locations")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)

            Text(
                locations.enumerated().compactMap { index, item in
                    var chunks: [String] = []
                    if let path = item.path, !path.isEmpty { chunks.append(path) }
                    else if let uri = item.uri, !uri.isEmpty { chunks.append(uri) }
                    if let label = item.label, !label.isEmpty { chunks.append(label) }
                    var range = ""
                    if let line = item.line {
                        range = "\(line)"
                        if let column = item.column {
                            range += ":\(column)"
                        }
                        if let endLine = item.endLine {
                            range += "-\(endLine)"
                            if let endColumn = item.endColumn {
                                range += ":\(endColumn)"
                            }
                        }
                    }
                    if !range.isEmpty { chunks.append(range) }
                    guard !chunks.isEmpty else { return nil }
                    return "\(index + 1). \(chunks.joined(separator: " @ "))"
                }.joined(separator: "\n")
            )
            .textSelection(.enabled)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }

    private var diffStats: (added: Int, removed: Int)? {
        guard let diffSection = toolView?.sections.first(where: { $0.style == .diff }),
              let parsed = AIDiffParser.parse(diffSection.content) else { return nil }
        return (parsed.addedCount, parsed.removedCount)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if toolView?.status == .running {
            ProgressView()
                #if os(macOS)
                .controlSize(.small)
                .scaleEffect(0.55)
                #else
                .scaleEffect(0.7)
                #endif
                .progressViewStyle(CircularProgressViewStyle(tint: statusColor))
        } else {
            Image(systemName: statusIconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(statusColor)
        }
    }

    private var statusIconName: String {
        switch toolView?.status ?? .unknown {
        case .pending:
            return "clock"
        case .running:
            return "play.circle"
        case .completed:
            return "checkmark.circle"
        case .error:
            return "xmark.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch toolView?.status ?? .unknown {
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
        guard let durationMs = toolView?.durationMs else { return nil }
        if durationMs < 1000 {
            return String(format: "%.0fms", durationMs)
        }
        return String(format: "%.2fs", durationMs / 1000)
    }

    private func toolIconName(_ toolID: String) -> String {
        switch toolID {
        case "subagent_result":
            return "person.2.badge.gearshape"
        case "read":
            return "eye"
        case "edit", "write", "apply_patch", "multiedit":
            return "square.and.pencil"
        case "bash", "terminal":
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
        case "contextcompaction", "context_compaction":
            return "rectangle.compress.vertical"
        default:
            return "wrench.and.screwdriver"
        }
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
