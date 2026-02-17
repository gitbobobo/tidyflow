#if os(macOS)
import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var sessions: [AISessionInfo]
    @Binding var currentSessionId: String?
    var onSelect: (AISessionInfo) -> Void
    var onDelete: (AISessionInfo) -> Void
    var onCreateNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话列表")
                    .font(.headline)
                Spacer()
                Button(action: onCreateNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            List(sessions) { session in
                SessionRow(
                    session: session,
                    isSelected: session.id == currentSessionId
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect(session)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        onDelete(session)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(idealWidth: 260)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}

struct SessionRow: View {
    let session: AISessionInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)

                Text(session.formattedDate)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }
}

#Preview {
    SessionListView(
        sessions: .constant([
            AISessionInfo(projectName: "p", workspaceName: "w", id: "1", title: "Test Session 1", updatedAt: Int64(Date().timeIntervalSince1970 * 1000)),
            AISessionInfo(projectName: "p", workspaceName: "w", id: "2", title: "Test Session 2", updatedAt: Int64(Date().timeIntervalSince1970 * 1000) - 3600000)
        ]),
        currentSessionId: .constant("1"),
        onSelect: { _ in },
        onDelete: { _ in },
        onCreateNew: {}
    )
    .frame(width: 260, height: 400)
}
#endif
