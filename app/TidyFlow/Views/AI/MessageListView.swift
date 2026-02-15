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
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !message.content.isEmpty {
                    Text(LocalizedStringKey(message.content))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundColor(isUser ? .white : .primary)
                        .background(bubbleBackgroundColor)
                        .cornerRadius(12)
                }
                
                if message.isStreaming {
                    TypingIndicator()
                        .padding(.leading, isUser ? 0 : 4)
                }
            }
            
            if !isUser {
                Spacer(minLength: 32)
            }
        }
    }
    
    private var bubbleBackgroundColor: Color {
        if isUser {
            return Color.blue
        } else {
            #if os(macOS)
            return Color(NSColor.controlBackgroundColor)
            #else
            return Color(UIColor.secondarySystemBackground)
            #endif
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
            ChatMessage(role: .assistant, content: "Sure, here is some code:\n```swift\nprint(\"Hello\")\n```", isStreaming: true)
        ]
        
        return MessageListView(messages: messages)
            .frame(width: 400, height: 600)
    }
}
