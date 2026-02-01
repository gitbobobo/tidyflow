import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    let webBridge = WebBridge()

    var body: some View {
        ZStack {
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
                    CoreStatusView(coreManager: appState.coreProcessManager)
                        .environmentObject(appState)
                }

                ToolbarItem(placement: .automatic) {
                    ConnectionStatusView()
                        .environmentObject(appState)
                }
            }

            // Command Palette Overlay
            if appState.commandPalettePresented {
                CommandPaletteView()
                    .environmentObject(appState)
                    .zIndex(100)
            }

            // Debug Panel Overlay (Cmd+Shift+D)
            if appState.debugPanelPresented {
                DebugPanelView()
                    .environmentObject(appState)
                    .zIndex(99)
            }
        }
        .handleGlobalKeybindings()
        .environmentObject(appState)
    }
}
