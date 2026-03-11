import SwiftUI
import Textual

enum AIChatMarkdownRole {
    case user
    case assistant
}

private enum StreamingMarkdownRenderPolicy {
    struct Configuration {
        let minInterval: CFAbsoluteTime
        let maxInterval: CFAbsoluteTime
        let minimumMeaningfulDelta: Int
    }

    static func configuration(for text: String) -> Configuration {
        let length = text.utf16.count
        switch length {
        case 0..<1_200:
            return Configuration(minInterval: 0.20, maxInterval: 0.45, minimumMeaningfulDelta: 24)
        case 1_200..<4_000:
            return Configuration(minInterval: 0.30, maxInterval: 0.75, minimumMeaningfulDelta: 64)
        default:
            return Configuration(minInterval: 0.50, maxInterval: 1.20, minimumMeaningfulDelta: 120)
        }
    }

    static func hasMeaningfulIncrement(renderedText: String, newText: String) -> Bool {
        guard renderedText != newText else { return false }
        guard newText.count >= renderedText.count else { return true }

        let config = configuration(for: newText)
        let delta = newText.utf16.count - renderedText.utf16.count
        if delta >= config.minimumMeaningfulDelta {
            return true
        }

        return newText.last == "\n" ||
            newText.hasSuffix("```") ||
            newText.last == "." ||
            newText.last == "。" ||
            newText.last == ":" ||
            newText.last == "："
    }
}

/// 聊天消息 Markdown 渲染器：每个连续文本文档块对应一个 StructuredText。
/// 流式输出期间按文本体积自适应降频，减少全量 Markdown 解析开销。
struct MarkdownTextView: View {
    let text: String
    var role: AIChatMarkdownRole = .assistant
    var baseFontSize: CGFloat = 13
    var isStreaming: Bool = false

    /// 已提交给 StructuredText 的文本快照
    @State private var renderedText: String = ""
    /// 收到但尚未渲染的最新文本（延迟任务会读取此值）
    @State private var latestPendingText: String = ""
    @State private var lastRenderTime: CFAbsoluteTime = 0
    @State private var deferredRenderTask: Task<Void, Never>?
    @State private var streamingRenderCount: Int = 0

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
                streamingRenderCount = 0
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
                        commitRender(text, reason: "stream_end")
                    }
                    logStreamingSummary(finalLength: text.utf16.count)
                } else {
                    streamingRenderCount = 0
                }
            }
            .onDisappear {
                deferredRenderTask?.cancel()
                deferredRenderTask = nil
                if isStreaming {
                    logStreamingSummary(finalLength: latestPendingText.utf16.count)
                }
            }
    }

    /// 流式期间按文本体积自适应节流 Markdown 渲染。
    /// 非流式场景下直接更新，无额外开销。
    private func throttledRender(_ newText: String) {
        guard isStreaming else {
            if renderedText != newText {
                renderedText = newText
            }
            return
        }

        guard newText != latestPendingText || newText != renderedText else { return }
        latestPendingText = newText

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastRenderTime
        let config = StreamingMarkdownRenderPolicy.configuration(for: newText)
        let hasMeaningfulIncrement = StreamingMarkdownRenderPolicy.hasMeaningfulIncrement(
            renderedText: renderedText,
            newText: newText
        )

        let shouldRenderNow =
            elapsed >= config.maxInterval ||
            (hasMeaningfulIncrement && elapsed >= config.minInterval)

        if shouldRenderNow {
            deferredRenderTask?.cancel()
            deferredRenderTask = nil
            commitRender(newText, reason: hasMeaningfulIncrement ? "meaningful_increment" : "max_interval")
            return
        }

        deferredRenderTask?.cancel()
        let remaining = max(
            0,
            (hasMeaningfulIncrement ? config.minInterval : config.maxInterval) - elapsed
        )
        deferredRenderTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            commitRender(latestPendingText, reason: hasMeaningfulIncrement ? "deferred_increment" : "deferred_max_interval")
            deferredRenderTask = nil
        }
    }

    private func commitRender(_ newText: String, reason: StaticString) {
        guard renderedText != newText else { return }
        lastRenderTime = CFAbsoluteTimeGetCurrent()
        renderedText = newText
        if isStreaming {
            streamingRenderCount += 1
            TFLog.perf.debug(
                "perf ai_markdown_stream_render count=\(streamingRenderCount, privacy: .public) chars=\(newText.utf16.count, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
    }

    private func logStreamingSummary(finalLength: Int) {
        guard streamingRenderCount > 0 else { return }
        TFLog.perf.info(
            "perf ai_markdown_stream_summary renders=\(streamingRenderCount, privacy: .public) final_chars=\(finalLength, privacy: .public)"
        )
        streamingRenderCount = 0
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
