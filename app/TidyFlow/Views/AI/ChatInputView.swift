import SwiftUI

struct ChatInputView: View {
    @Binding var text: String
    @Binding var selectedFiles: [String]
    var isStreaming: Bool
    var onSend: () -> Void
    var onStop: () -> Void
    var onFileSelect: () -> Void

    @State private var isComposing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if !selectedFiles.isEmpty {
                FileTagsView(files: $selectedFiles)
            }

            HStack(spacing: 8) {
                Button(action: onFileSelect) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Attach file (@)")

                TextField("输入消息...", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .onChange(of: text) { newValue in
                        checkForAtTrigger(newValue)
                    }

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
                            .foregroundColor(text.isEmpty && selectedFiles.isEmpty ? .gray : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty && selectedFiles.isEmpty)
                    .help("发送")
                }
            }
        }
        .padding(12)
    }

    private func checkForAtTrigger(_ value: String) {
        if value.last == "@" {
            isComposing = true
            onFileSelect()
        }
    }
}

struct FileTagsView: View {
    @Binding var files: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files, id: \.self) { file in
                    FileTag(name: file) {
                        files.removeAll { $0 == file }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 28)
    }
}

struct FileTag: View {
    let name: String
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))

            Text(name)
                .font(.system(size: 11))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.15))
        .foregroundColor(.accentColor)
        .cornerRadius(6)
    }
}

#Preview {
    VStack {
        ChatInputView(
            text: .constant("Hello"),
            selectedFiles: .constant(["test.swift"]),
            isStreaming: false,
            onSend: {},
            onStop: {},
            onFileSelect: {}
        )

        ChatInputView(
            text: .constant(""),
            selectedFiles: .constant([]),
            isStreaming: true,
            onSend: {},
            onStop: {},
            onFileSelect: {}
        )
    }
    .padding()
    .frame(width: 500)
}
