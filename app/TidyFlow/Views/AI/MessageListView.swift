import SwiftUI

struct MessageListView: View {
    let messages: [ChatMessage]
    
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
    let message: ChatMessage

    @State private var isMetaExpanded: Bool = false

    private var isUser: Bool {
        message.role == .user
    }
    
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
        .onAppear {
            // 流式期间默认展开，做到“思考过程实时展示”
            if message.isStreaming && shouldShowMetaDisclosure {
                isMetaExpanded = true
            }
        }
        .onChange(of: message.isStreaming) { isStreaming in
            // 回复结束后收起，避免占据太多空间
            if isStreaming {
                if shouldShowMetaDisclosure { isMetaExpanded = true }
            } else {
                isMetaExpanded = false
            }
        }
        .onChange(of: message.thinking) { _ in
            if message.isStreaming && shouldShowMetaDisclosure {
                isMetaExpanded = true
            }
        }
        .onChange(of: message.toolTrace) { _ in
            if message.isStreaming && shouldShowMetaDisclosure {
                isMetaExpanded = true
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.content.isEmpty {
                if isUser {
                    Text(message.content)
                        .textSelection(.enabled)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                } else {
                    // 流式期间做“打字机”渲染，避免一次性大段文字跳变的生硬感
                    TypewriterText(text: message.content, isStreaming: message.isStreaming)
                        .textSelection(.enabled)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                }
            } else if message.isStreaming {
                // 没有文本但仍在生成时，也要有“消息气泡”
                TypingIndicator()
            }

            if !isUser, shouldShowMetaDisclosure {
                DisclosureGroup("思考过程", isExpanded: $isMetaExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let thinking = message.thinking, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            TypewriterText(text: thinking, isStreaming: message.isStreaming)
                                .textSelection(.enabled)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let toolTrace = message.toolTrace, !toolTrace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            TypewriterText(text: toolTrace, isStreaming: message.isStreaming)
                                .textSelection(.enabled)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 2)
                }
                .disclosureGroupStyle(.automatic)
            }

            if message.isStreaming && !message.content.isEmpty {
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
        .frame(maxWidth: 520, alignment: isUser ? .trailing : .leading)
    }
    
    private var bubbleBackgroundColor: Color {
        if isUser {
            return Color.blue
        } else {
            // 回复消息使用更明显的气泡底色，避免与背景融在一起
            return Color.secondary.opacity(0.10)
        }
    }

    private var bubbleBorderColor: Color {
        if isUser {
            return Color.clear
        }
        return Color.secondary.opacity(0.12)
    }

    private var shouldShowMetaDisclosure: Bool {
        if isUser { return false }
        let thinkingEmpty = (message.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let toolEmpty = (message.toolTrace ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !(thinkingEmpty && toolEmpty)
    }
}

/// 打字机效果：把“目标文本”平滑地增量渲染到 UI 上。
///
/// 说明：
/// - 后端/网络可能一次推送较长的增量片段，直接替换整段 Text 会产生明显跳变。
/// - 这里把差异部分拆成小 chunk 按节拍追加，视觉上更接近自然的流式输出。
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
                    // 流式开始：从当前已显示内容继续追加（避免列表重用导致清空）
                    if displayed.isEmpty, !text.isEmpty {
                        displayed = "" // 让后续逐步 append
                    }
                    startIfNeeded()
                } else {
                    displayed = text
                }
            }
            .onDisappear {
                task?.cancel()
                task = nil
            }
            .onChange(of: text) { newValue in
                target = newValue
                if !isStreaming {
                    displayed = newValue
                } else {
                    startIfNeeded()
                }
            }
            .onChange(of: isStreaming) { streaming in
                if streaming {
                    startIfNeeded()
                } else {
                    // 结束时直接收敛到最终文本并停止任务
                    task?.cancel()
                    task = nil
                    displayed = target
                }
            }
    }

    private func startIfNeeded() {
        guard task == nil else { return }
        task = Task { @MainActor in
            // 30ms 一帧，按 backlog 动态调整速度
            let tickNs: UInt64 = 30_000_000
            while !Task.isCancelled {
                if displayed == target {
                    if !isStreaming { break }
                    try? await Task.sleep(nanoseconds: tickNs)
                    continue
                }

                // 若 target 发生回退/重写（非前缀），直接同步，避免卡死
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
    @State private var offset: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(0.5)
                    .scaleEffect(index == Int(offset) ? 1.2 : 1.0)
            }
        }
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 0.5).repeatForever()) {
                offset = 2
            }
        }
    }
}

struct MessageListView_Previews: PreviewProvider {
    static var previews: some View {
        let messages = [
            ChatMessage(role: .user, content: "Hello AI"),
            ChatMessage(role: .assistant, content: "Hello! How can I help you today?"),
            ChatMessage(role: .user, content: "Write some code"),
            ChatMessage(
                role: .assistant,
                content: "Sure, here is some code:\n```swift\nprint(\"Hello\")\n```",
                thinking: "模型推理中...\n下一步调用工具读取文件。",
                toolTrace: "🔧 read_file\n{\n  \"path\": \"src/main.swift\"\n}",
                isStreaming: true
            )
        ]
        
        return MessageListView(messages: messages)
            .frame(width: 400, height: 600)
    }
}
