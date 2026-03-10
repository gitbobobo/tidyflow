import SwiftUI
import Textual

enum AIChatMarkdownRole {
    case user
    case assistant
}

/// 聊天消息 Markdown 渲染器：每个连续文本文档块对应一个 StructuredText。
struct MarkdownTextView: View {
    let text: String
    var role: AIChatMarkdownRole = .assistant
    var baseFontSize: CGFloat = 13

    private var accentColor: Color {
        role == .user ? .primary : .accentColor
    }

    var body: some View {
        StructuredText(markdown: text)
            .font(.system(size: baseFontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textual.structuredTextStyle(.gitHub)
            .textual.paragraphStyle(AIChatParagraphStyle())
            .textual.blockQuoteStyle(AIChatReasoningBlockQuoteStyle())
            .textual.overflowMode(.scroll)
            .textual.textSelection(.enabled)
            .textual.inlineStyle(
                InlineStyle.gitHub
                    .link(.foregroundColor(accentColor))
            )
            .textual.codeBlockStyle(AIChatCodeBlockStyle())
    }
}

private struct AIChatParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.28))
            .textual.blockSpacing(.init(top: 0, bottom: 14))
    }
}

private struct AIChatReasoningBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 3)

            configuration.label
                .foregroundStyle(.secondary)
                .opacity(0.96)
        }
        .padding(.vertical, 2)
    }
}

private struct AIChatCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(languageTitle(configuration.languageHint))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    configuration.codeBlock.copyToPasteboard()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08))

            configuration.label
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private func languageTitle(_ token: String?) -> String {
        let normalized = token?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return (normalized?.isEmpty == false) ? normalized! : "text"
    }
}
