import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var sessions: [SessionInfo]
    @Binding var currentSessionId: String?
    var onSelect: (SessionInfo) -> Void
    var onDelete: (SessionInfo) -> Void
    var onCreateNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话列表")
                    .font(.headline)
                Spacer()
                Button(action: onCreateNew) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding()

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
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 200, idealWidth: 250)
    }
}

struct SessionRow: View {
    let session: SessionInfo
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                Text(session.formattedDate)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
    }
}

#Preview {
    SessionListView(
        sessions: .constant([
            SessionInfo(id: "1", title: "Test Session 1", updatedAt: Int64(Date().timeIntervalSince1970 * 1000)),
            SessionInfo(id: "2", title: "Test Session 2", updatedAt: Int64(Date().timeIntervalSince1970 * 1000) - 3600000)
        ]),
        currentSessionId: .constant("1"),
        onSelect: { _ in },
        onDelete: { _ in },
        onCreateNew: {}
    )
    .frame(width: 250, height: 400)
}
