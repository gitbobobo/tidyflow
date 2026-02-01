import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    let webBridge = WebBridge()

    var body: some View {
        ZStack {
            // Main layout with conditional right panel
            HStack(spacing: 0) {
                // Left sidebar + Center content using NavigationSplitView
                NavigationSplitView {
                    ProjectsSidebarView()
                        .environmentObject(appState)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
                } detail: {
                    CenterContentView(webBridge: webBridge)
                        .environmentObject(appState)
                }

                // Right panel (conditionally shown)
                if !appState.rightSidebarCollapsed {
                    RightToolPanelView()
                        .environmentObject(appState)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: appState.rightSidebarCollapsed)
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
                // Right panel toggle button
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        appState.rightSidebarCollapsed.toggle()
                    }) {
                        Image(systemName: "sidebar.right")
                    }
                    .help(appState.rightSidebarCollapsed ? "Show Right Panel" : "Hide Right Panel")
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
