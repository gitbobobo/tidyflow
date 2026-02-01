import SwiftUI

struct CenterContentView: View {
    @EnvironmentObject var appState: AppState
    let webBridge: WebBridge
    
    var body: some View {
        ZStack {
            // Keep WebView alive in background for Phase A compatibility/Bridge
            WebViewContainer(bridge: webBridge)
                .opacity(0) // Hide visually, we are using native shell
            
            if appState.selectedWorkspaceKey != nil {
                VStack(spacing: 0) {
                    TabStripView()
                    Divider()
                    TabContentHostView()
                }
                .background(Color(NSColor.windowBackgroundColor))
            } else {
                // Empty state for no workspace
                VStack {
                    Spacer()
                    Text("No Workspace Selected")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .background(Color(NSColor.windowBackgroundColor))
            }
            
            // Overlay for selected workspace (Legacy debug info, keeping it or removing? 
            // The prompt says "Unselected workspace: no tabs, empty state". 
            // "Click workspace: auto create default tab".
            // I'll remove the old debug overlay as it interferes with the new UI)
        }
    }
}
