import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ChatInputView: View {
    @Binding var text: String
    @Binding var imageAttachments: [ImageAttachment]
    var isStreaming: Bool
    var onSend: () -> Void
    var onStop: () -> Void

    // 模型 / Agent 状态
    var providers: [AIProviderInfo]
    @Binding var selectedModel: AIModelSelection?
    var agents: [AIAgentInfo]
    @Binding var selectedAgent: String?

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // 图片缩略图预览行
            if !imageAttachments.isEmpty {
                imagePreviewRow
            }

            // 输入区域
            inputEditor

            // 工具栏
            toolbar
        }
        .padding(12)
    }

    // MARK: - 图片预览行

    private var imagePreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(imageAttachments) { attachment in
                    imagePreviewItem(attachment)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func imagePreviewItem(_ attachment: ImageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            #if os(macOS)
            Image(nsImage: attachment.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 60)
                .cornerRadius(8)
                .clipped()
            #endif

            Button(action: {
                imageAttachments.removeAll { $0.id == attachment.id }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)).frame(width: 18, height: 18))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    // MARK: - 输入编辑器

    private var inputEditor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("输入消息...")
                    .foregroundColor(.secondary.opacity(0.6))
                    .font(.system(size: 13))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 36, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .focused($isFocused)
                .onKeyPress(keys: [.return], phases: .down) { keyPress in
                    // Shift+Enter：插入换行（不拦截）
                    if keyPress.modifiers.contains(.shift) {
                        return .ignored
                    }
                    // 普通 Enter：发送
                    if canSend && !isStreaming {
                        onSend()
                        return .handled
                    }
                    return .handled // 空内容也拦截，避免插入空行
                }
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            // 左侧：Agent 切换 + 模型选择
            agentButton
            modelButton

            Spacer()

            // 右侧：图片上传 + 发送/停止
            imageUploadButton
            sendOrStopButton
        }
        .padding(.top, 8)
    }

    // MARK: - Agent 切换按钮

    private var agentButton: some View {
        Group {
            if !agents.isEmpty {
                Menu {
                    ForEach(agents) { agent in
                        Button(action: {
                            selectedAgent = agent.name
                            // 自动切换到 agent 默认模型
                            if let pid = agent.defaultProviderID,
                               let mid = agent.defaultModelID,
                               !pid.isEmpty, !mid.isEmpty {
                                selectedModel = AIModelSelection(providerID: pid, modelID: mid)
                            }
                        }) {
                            HStack {
                                Text(agent.name)
                                if let desc = agent.description, !desc.isEmpty {
                                    Text("— \(desc)")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                        Text(selectedAgent ?? agents.first?.name ?? "Agent")
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // MARK: - 模型选择按钮

    private var modelButton: some View {
        Group {
            if !providers.isEmpty {
                Menu {
                    ForEach(providers) { provider in
                        Section(provider.name) {
                            ForEach(provider.models) { model in
                                Button(action: {
                                    selectedModel = AIModelSelection(providerID: provider.id, modelID: model.id)
                                }) {
                                    Text(model.name)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11))
                        Text(selectedModelDisplayName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var selectedModelDisplayName: String {
        guard let sel = selectedModel else { return "模型" }
        for p in providers {
            if let m = p.models.first(where: { $0.id == sel.modelID && p.id == sel.providerID }) {
                return m.name
            }
        }
        return sel.modelID
    }

    // MARK: - 图片上传按钮

    private var imageUploadButton: some View {
        Button(action: pickImage) {
            Image(systemName: "photo")
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .help("上传图片")
    }

    private func pickImage() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.lowercased()
                let mime: String
                switch ext {
                case "png": mime = "image/png"
                case "jpg", "jpeg": mime = "image/jpeg"
                case "gif": mime = "image/gif"
                case "webp": mime = "image/webp"
                default: mime = "image/png"
                }
                let attachment = ImageAttachment(
                    filename: url.lastPathComponent,
                    data: data,
                    mime: mime
                )
                DispatchQueue.main.async {
                    imageAttachments.append(attachment)
                }
            }
        }
        #endif
    }

    // MARK: - 发送/停止按钮

    private var sendOrStopButton: some View {
        Group {
            if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("停止生成")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(canSend ? .accentColor : .gray)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("发送")
            }
        }
    }
}

#Preview {
    VStack {
        ChatInputView(
            text: .constant("Hello"),
            imageAttachments: .constant([]),
            isStreaming: false,
            onSend: {},
            onStop: {},
            providers: [],
            selectedModel: .constant(nil),
            agents: [],
            selectedAgent: .constant(nil)
        )

        ChatInputView(
            text: .constant(""),
            imageAttachments: .constant([]),
            isStreaming: true,
            onSend: {},
            onStop: {},
            providers: [],
            selectedModel: .constant(nil),
            agents: [],
            selectedAgent: .constant(nil)
        )
    }
    .padding()
    .frame(width: 500)
}
