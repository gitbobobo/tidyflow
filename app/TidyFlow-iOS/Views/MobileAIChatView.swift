import SwiftUI

struct MobileAIChatView: View {
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isStreaming = false
    @State private var showSessionList = false
    @State private var sessions: [SessionInfo] = []
    @State private var currentSessionId: String?

    private var systemBackgroundColor: Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #else
        return Color(NSColor.controlBackgroundColor)
        #endif
    }

    private var systemGroupedBackgroundColor: Color {
        #if os(iOS)
        return Color(UIColor.systemGroupedBackground)
        #else
        return Color(NSColor.textBackgroundColor)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            messageList
            inputArea
        }
        .navigationTitle("AI Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showSessionList.toggle()
                }) {
                    Image(systemName: "list.bullet")
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    showSessionList.toggle()
                }) {
                    Image(systemName: "list.bullet")
                }
            }
            #endif
        }
        .sheet(isPresented: $showSessionList) {
            NavigationStack {
                List(sessions) { session in
                    Button(action: {
                        loadSession(session)
                        showSessionList = false
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(session.displayTitle)
                                    .font(.headline)
                                Text(session.formattedDate)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if session.id == currentSessionId {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
                .navigationTitle("Sessions")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") {
                            showSessionList = false
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: createNewSession) {
                            Image(systemName: "plus")
                        }
                    }
                    #else
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showSessionList = false
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button(action: createNewSession) {
                            Image(systemName: "plus")
                        }
                    }
                    #endif
                }
            }
        }
        .onAppear {
            loadSessions()
        }
    }

    private var toolbar: some View {
        HStack {
            if isStreaming {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Generating...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(systemBackgroundColor)
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(messages) { message in
                    MobileMessageBubble(message: message)
                }
            }
            .padding()
        }
        .background(systemGroupedBackgroundColor)
    }

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                TextField("Message...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                if isStreaming {
                    Button(action: stopStreaming) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                    }
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(inputText.isEmpty ? .gray : .accentColor)
                    }
                    .disabled(inputText.isEmpty)
                }
            }
            .padding()
        }
        .background(systemBackgroundColor)
    }

    private func loadSessions() {}

    private func loadSession(_ session: SessionInfo) {
        currentSessionId = session.id
    }

    private func createNewSession() {
        inputText = ""
        messages = []
        currentSessionId = nil
    }

    private func sendMessage() {
        guard !inputText.isEmpty else { return }

        let userMessage = ChatMessage(role: .user, content: inputText)
        messages.append(userMessage)

        isStreaming = true
        inputText = ""
    }

    private func stopStreaming() {
        isStreaming = false
    }
}

struct MobileMessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 50)
            }

            VStack(alignment: .leading, spacing: 4) {
                if message.isStreaming {
                    HStack(spacing: 4) {
                        Circle()
                            .frame(width: 6, height: 6)
                            .opacity(0.5)
                        Circle()
                            .frame(width: 6, height: 6)
                            .opacity(0.7)
                        Circle()
                            .frame(width: 6, height: 6)
                            .opacity(1)
                    }
                    .foregroundColor(.accentColor)
                } else {
                    Text(message.content)
                        .font(.body)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.role == .user
                    ? Color.blue.opacity(0.15)
                    : Color.gray.opacity(0.15)
            )
            .foregroundColor(.primary)
            .cornerRadius(16)

            if message.role == .assistant {
                Spacer(minLength: 50)
            }
        }
    }
}
