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
            
            // Content Area (Empty for now)
            VStack {
                Spacer()
                if let tool = appState.activeRightTool {
                    Text("\(tool.rawValue.capitalized) Panel")
                        .font(.title)
                        .foregroundColor(.secondary)
                } else {
                    Text("No Tool Selected")
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 200)
    }
}

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
