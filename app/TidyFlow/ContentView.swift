import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    let webBridge = WebBridge()

    var body: some View {
        ZStack {
            // Using NavigationSplitView for 3-column layout (macOS 13+)
            NavigationSplitView {
                // UX-1: Replace LeftSidebarView with ProjectsSidebarView
                ProjectsSidebarView()
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
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 12) {
                        AddProjectButtonView()
                            .environmentObject(appState)

                        CoreStatusView(coreManager: appState.coreProcessManager)
                            .environmentObject(appState)

                        ConnectionStatusView()
                            .environmentObject(appState)
                    }
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
        // UX-1: Add Project Sheet
        .sheet(isPresented: $appState.addProjectSheetPresented) {
            AddProjectSheet()
                .environmentObject(appState)
        }
    }
}
