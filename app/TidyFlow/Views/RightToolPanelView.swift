import SwiftUI

struct RightToolPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header / Tab bar
            HStack(spacing: 16) {
                ToolButton(tool: .explorer, icon: "folder", current: $appState.activeRightTool)
                ToolButton(tool: .search, icon: "magnifyingglass", current: $appState.activeRightTool)
                ToolButton(tool: .git, icon: "arrow.triangle.branch", current: $appState.activeRightTool)
                Spacer()
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content Area
            Group {
                switch appState.activeRightTool {
                case .explorer:
                    ExplorerPlaceholderView()
                case .search:
                    SearchPlaceholderView()
                case .git:
                    NativeGitPanelView()
                        .environmentObject(appState)
                case .none:
                    NoToolSelectedView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 200)
    }
}

// MARK: - Placeholder Views

struct ExplorerPlaceholderView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Explorer Panel")
                .font(.title)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

struct SearchPlaceholderView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Search Panel")
                .font(.title)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

struct NoToolSelectedView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("No Tool Selected")
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: - Tool Button

struct ToolButton: View {
    let tool: RightTool
    let icon: String
    @Binding var current: RightTool?

    var body: some View {
        Button(action: {
            if current == tool {
                // current = nil // Optional: Allow collapsing
            } else {
                current = tool
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(current == tool ? .accentColor : .secondary)
        }
        .buttonStyle(PlainButtonStyle())
        .help(tool.rawValue.capitalized)
    }
}
