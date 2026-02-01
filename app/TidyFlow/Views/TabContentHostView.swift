import SwiftUI

struct TabContentHostView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            if let workspaceKey = appState.selectedWorkspaceKey,
               let activeId = appState.activeTabIdByWorkspace[workspaceKey],
               let tabs = appState.workspaceTabs[workspaceKey],
               let activeTab = tabs.first(where: { $0.id == activeId }) {
                
                switch activeTab.kind {
                case .terminal:
                    TerminalPlaceholderView()
                case .editor:
                    EditorPlaceholderView(path: activeTab.payload)
                case .diff:
                    DiffPlaceholderView(path: activeTab.payload)
                }
                
            } else {
                // Empty state or Fallback
                VStack {
                    Spacer()
                    Text("No Active Tab")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }
}

struct TerminalPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack {
                Text("Terminal Placeholder")
                    .font(.monospaced(.body)())
                    .foregroundColor(.green)
                Text("(WebView will be embedded here in Phase B-3)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
}

struct EditorPlaceholderView: View {
    let path: String
    var body: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)
            VStack {
                Image(systemName: "doc.text")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Editor Placeholder")
                    .font(.headline)
                Text(path.isEmpty ? "Untitled" : path)
                    .font(.monospaced(.caption)())
            }
        }
    }
}

struct DiffPlaceholderView: View {
    let path: String
    var body: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)
            VStack {
                Image(systemName: "arrow.left.arrow.right.circle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Diff Placeholder")
                    .font(.headline)
                Text(path)
                    .font(.monospaced(.caption)())
                Text("(working / staged)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
