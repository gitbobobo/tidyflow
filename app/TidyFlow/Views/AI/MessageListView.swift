import SwiftUI

struct MessageListView: View {
    let messages: [AIChatMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) {
                if let lastId = messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct MessageBubble: View {
    let message: AIChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser {
                Spacer(minLength: 32)
            } else {
                Image(systemName: "cpu")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Circle())
                    .padding(.top, 4)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                bubble
            }

            if !isUser {
                Spacer(minLength: 32)
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.parts.isEmpty {
                if message.isStreaming {
                    TypingIndicator()
                } else {
                    EmptyView()
                }
            } else {
                ForEach(message.parts) { part in
                    switch part.kind {
                    case .text:
                        if let text = part.text, !text.isEmpty {
                            if isUser {
                                Text(text)
                                    .textSelection(.enabled)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                            } else {
                                TypewriterText(text: text, isStreaming: message.isStreaming)
                                    .textSelection(.enabled)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                            }
                        }
                    case .reasoning:
                        if let text = part.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            TypewriterText(text: text, isStreaming: message.isStreaming)
                                .textSelection(.enabled)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .tool:
                        ToolCardView(
                            name: part.toolName ?? "unknown",
                            state: part.toolState
                        )
                    }
                }
            }

            if message.isStreaming && !isUser && !message.parts.isEmpty {
                TypingIndicator()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bubbleBackgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(bubbleBorderColor, lineWidth: isUser ? 0 : 1)
        )
        .cornerRadius(12)
        .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)
    }

    private var bubbleBackgroundColor: Color {
        if isUser {
            return Color.blue
        } else {
            return Color.secondary.opacity(0.10)
        }
    }

    private var bubbleBorderColor: Color {
        if isUser { return .clear }
        return Color.secondary.opacity(0.12)
    }
}

/// 打字机效果：把“目标文本”平滑地增量渲染到 UI 上。
private struct TypewriterText: View {
    let text: String
    let isStreaming: Bool

    @State private var displayed: String = ""
    @State private var target: String = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        Text(displayed)
            .onAppear {
                target = text
                if isStreaming {
                    startIfNeeded()
                } else {
                    displayed = text
                }
            }
            .onDisappear {
                task?.cancel()
                task = nil
            }
            .onChange(of: text) { _, newValue in
                target = newValue
                if !isStreaming {
                    displayed = newValue
                } else {
                    startIfNeeded()
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                if streaming {
                    startIfNeeded()
                } else {
                    task?.cancel()
                    task = nil
                    displayed = target
                }
            }
    }

    private func startIfNeeded() {
        guard task == nil else { return }
        task = Task { @MainActor in
            let tickNs: UInt64 = 30_000_000
            while !Task.isCancelled {
                if displayed == target {
                    if !isStreaming { break }
                    try? await Task.sleep(nanoseconds: tickNs)
                    continue
                }

                if !target.hasPrefix(displayed) {
                    displayed = target
                    try? await Task.sleep(nanoseconds: tickNs)
                    continue
                }

                let backlog = max(0, target.count - displayed.count)
                let cps: Int
                if backlog > 500 {
                    cps = 2000
                } else if backlog > 200 {
                    cps = 1200
                } else if backlog > 80 {
                    cps = 600
                } else {
                    cps = 240
                }
                let chunkSize = max(1, Int(Double(cps) * (Double(tickNs) / 1_000_000_000.0)))

                let startIdx = target.index(target.startIndex, offsetBy: displayed.count)
                let endIdx = target.index(startIdx, offsetBy: min(chunkSize, backlog))
                displayed.append(contentsOf: target[startIdx..<endIdx])

                try? await Task.sleep(nanoseconds: tickNs)
            }
        }
    }
}

private struct TypingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            dot(0)
            dot(1)
            dot(2)
        }
        .padding(.top, 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func dot(_ index: Int) -> some View {
        Circle()
            .fill(Color.secondary.opacity(0.55))
            .frame(width: 6, height: 6)
            .scaleEffect(phase == 0 ? 1 : (index == 1 ? 1.25 : 1.1))
    }
}
