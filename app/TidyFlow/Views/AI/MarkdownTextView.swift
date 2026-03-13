import SwiftUI
import Textual

/// Markdown 最终态字符串缓存；避免同一 part 在壳投影刷新后重复走字符串规范化路径。
/// key=(partId, renderRevision, baseFontSize_x10, roleInt)，缓存上限 128 条。
private final class MarkdownFinalStateCache {
    static let shared = MarkdownFinalStateCache()
    private let cache = NSCache<NSString, NSString>()

    private init() {
        cache.countLimit = 128
    }

    func cacheKey(partId: String, renderRevision: UInt64, baseFontSize: CGFloat, role: AIChatMarkdownRole) -> NSString {
        "\(partId):\(renderRevision):\(Int(baseFontSize * 10)):\(role == .user ? 0 : 1)" as NSString
    }

    func get(key: NSString) -> String? {
        cache.object(forKey: key).map { $0 as String }
    }

    func set(key: NSString, value: String) {
        cache.setObject(value as NSString, forKey: key)
    }
}

enum AIChatMarkdownRole {
    case user
    case assistant
}

// StreamingMarkdownRenderPolicy 已迁移至 StreamingMarkdownRenderStrategy.swift，
// MarkdownTextView 改用 StreamingMarkdownRenderScheduler。

/// 聊天消息 Markdown 渲染器：每个可见文本 part 对应一个 StructuredText。
/// 流式输出期间按文本体积自适应降频，减少全量 Markdown 解析开销。
struct MarkdownTextView: View {
    let text: String
    var role: AIChatMarkdownRole = .assistant
    var baseFontSize: CGFloat = 13
    var isStreaming: Bool = false
    /// part 标识，用于最终态缓存 key
    var partId: String = ""
    /// 渲染版本号，配合 partId 构成缓存 key
    var renderRevision: UInt64 = 0

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
                // 非流式场景查询最终态缓存，减少重复规范化
                if !isStreaming && !partId.isEmpty {
                    let cacheKey = MarkdownFinalStateCache.shared.cacheKey(
                        partId: partId,
                        renderRevision: renderRevision,
                        baseFontSize: baseFontSize,
                        role: role
                    )
                    if let cached = MarkdownFinalStateCache.shared.get(key: cacheKey) {
                        renderedText = cached
                    }
                }
            }
            .onChange(of: text) { _, newText in
                throttledRender(newText)
            }
            .onChange(of: isStreaming) { _, streaming in
                if !streaming {
                    // 流式结束，使用调度器决策确保最终态渲染
                    deferredRenderTask?.cancel()
                    deferredRenderTask = nil
                    let scheduler = StreamingMarkdownRenderScheduler()
                    let decision = scheduler.decideOnStreamEnd(renderedText: renderedText, finalText: text)
                    if case .renderNow = decision {
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
        guard newText != latestPendingText || newText != renderedText else { return }
        latestPendingText = newText

        let scheduler = StreamingMarkdownRenderScheduler()
        let now = CFAbsoluteTimeGetCurrent()
        let decision = scheduler.decide(
            renderedText: renderedText,
            incomingText: newText,
            isStreaming: isStreaming,
            lastRenderTime: lastRenderTime,
            now: now
        )

        switch decision {
        case .noop:
            return
        case .renderNow(let reason):
            deferredRenderTask?.cancel()
            deferredRenderTask = nil
            let logReason: StaticString
            switch reason {
            case .meaningfulIncrement: logReason = "meaningful_increment"
            case .maxIntervalElapsed: logReason = "max_interval"
            case .streamEnded: logReason = "stream_end"
            case .nonStreaming: logReason = "non_streaming"
            }
            commitRender(newText, reason: logReason)
        case .deferRender(let interval):
            deferredRenderTask?.cancel()
            deferredRenderTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                let latestDecision = scheduler.decide(
                    renderedText: renderedText,
                    incomingText: latestPendingText,
                    isStreaming: isStreaming,
                    lastRenderTime: lastRenderTime,
                    now: CFAbsoluteTimeGetCurrent()
                )
                if case .renderNow = latestDecision {
                    commitRender(latestPendingText, reason: "deferred_flush")
                } else if case .noop = latestDecision {
                    // 无需渲染
                } else {
                    commitRender(latestPendingText, reason: "deferred_fallback")
                }
                deferredRenderTask = nil
            }
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
        // 流式结束后将最终文本写入缓存
        if !isStreaming && !partId.isEmpty {
            let cacheKey = MarkdownFinalStateCache.shared.cacheKey(
                partId: partId,
                renderRevision: renderRevision,
                baseFontSize: baseFontSize,
                role: role
            )
            MarkdownFinalStateCache.shared.set(key: cacheKey, value: newText)
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
