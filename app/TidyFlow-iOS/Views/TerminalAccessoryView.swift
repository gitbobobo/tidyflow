import SwiftUI

/// 键盘上方特殊键工具栏
struct TerminalAccessoryView: View {
    let onKey: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                keyButton("Esc", "\u{1b}")
                keyButton("Tab", "\t")
                Divider().frame(height: 24)
                keyButton("Ctrl-C", "\u{03}")
                keyButton("Ctrl-D", "\u{04}")
                keyButton("Ctrl-Z", "\u{1a}")
                keyButton("Ctrl-L", "\u{0c}")
                Divider().frame(height: 24)
                keyButton("↑", "\u{1b}[A")
                keyButton("↓", "\u{1b}[B")
                keyButton("→", "\u{1b}[C")
                keyButton("←", "\u{1b}[D")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    private func keyButton(_ label: String, _ sequence: String) -> some View {
        Button {
            onKey(sequence)
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(uiColor: .tertiarySystemBackground))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}
