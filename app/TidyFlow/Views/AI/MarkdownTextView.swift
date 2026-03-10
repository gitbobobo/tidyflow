import SwiftUI
import Textual

enum AIChatMarkdownRole {
    case user
    case assistant
}

/// 聊天消息 Markdown 渲染器：每个连续文本文档块对应一个 StructuredText。
/// 流式输出期间自动降频（200ms / 5fps），减少全量 Markdown 解析开销。
struct MarkdownTextView: View {
    let text: String
    var role: AIChatMarkdownRole = .assistant
    var baseFontSize: CGFloat = 13
    var isStreaming: Bool = false

    /// 流式期间 Markdown 全量解析最小间隔
    private static let streamingRenderInterval: CFAbsoluteTime = 0.2

    /// 已提交给 StructuredText 的文本快照
    @State private var renderedText: String = ""
    /// 收到但尚未渲染的最新文本（延迟任务会读取此值）
    @State private var latestPendingText: String = ""
    @State private var lastRenderTime: CFAbsoluteTime = 0
    @State private var deferredRenderTask: Task<Void, Never>?

    private var accentColor: Color {
        role == .user ? .primary : .accentColor
    }

    var body: some View {
        let displayText = renderedText.isEmpty ? text : renderedText
        StructuredText(markdown: displayText)
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
            .onAppear {
                renderedText = text
                lastRenderTime = CFAbsoluteTimeGetCurrent()
            }
            .onChange(of: text) { _, newText in
                throttledRender(newText)
            }
            .onChange(of: isStreaming) { _, streaming in
                if !streaming {
                    // 流式结束，立即渲染最终文本确保一致
                    deferredRenderTask?.cancel()
                    deferredRenderTask = nil
                    if renderedText != text {
                        renderedText = text
                    }
                }
            }
            .onDisappear {
                deferredRenderTask?.cancel()
                deferredRenderTask = nil
            }
    }

    /// 流式期间节流 Markdown 渲染：每 200ms 最多一次全量解析。
    /// 非流式场景下直接更新，无额外开销。
    private func throttledRender(_ newText: String) {
        guard isStreaming else {
            renderedText = newText
            return
        }

        latestPendingText = newText

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastRenderTime

        if elapsed >= Self.streamingRenderInterval {
            lastRenderTime = now
            renderedText = newText
            deferredRenderTask?.cancel()
            deferredRenderTask = nil
            return
        }

        // 已有延迟任务挂起，它完成时会读取 latestPendingText
        guard deferredRenderTask == nil else { return }
        let remaining = Self.streamingRenderInterval - elapsed
        deferredRenderTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            lastRenderTime = CFAbsoluteTimeGetCurrent()
            renderedText = latestPendingText
            deferredRenderTask = nil
        }
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
