import SwiftUI

struct ContentView: View {
    @StateObject var appState = AppState()
    let webBridge = WebBridge()
    
    var body: some View {
        // Using NavigationSplitView for 3-column layout (macOS 13+)
        // If targeting older macOS, we might need NavigationView or HSplitView wrapper.
        // For Phase A, we assume modern macOS target.
        NavigationSplitView {
            LeftSidebarView()
                .environmentObject(appState)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } content: {
            CenterContentView(webBridge: webBridge)
                .environmentObject(appState)
        } detail: {
            RightToolPanelView()
                .environmentObject(appState)
                .navigationSplitViewColumnWidth(min: 200, ideal: 300)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ProjectPickerView()
                    .environmentObject(appState)
            }
            
            ToolbarItem(placement: .automatic) {
                ConnectionStatusView()
                    .environmentObject(appState)
            }
        }
    }
}
