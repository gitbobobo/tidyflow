import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    // 使用 @StateObject 确保 WebBridge 只创建一次，不随视图更新而重建
    @StateObject private var webBridge = WebBridge()

    /// 控制 Inspector 显示状态（与 rightSidebarCollapsed 反向绑定）
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { !appState.rightSidebarCollapsed },
            set: { appState.rightSidebarCollapsed = !$0 }
        )
    }

    var body: some View {
        ZStack {
            // 主布局：左侧边栏 + 中心内容
            NavigationSplitView {
                ProjectsSidebarView()
                    .environmentObject(appState)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            } detail: {
                // 移除 .id() 修饰符，避免切换 workspace 时重建 WKWebView 导致终端会话丢失
                CenterContentView(webBridge: webBridge)
                    .environmentObject(appState)
            }
            // 使用苹果官方 Inspector API 实现右侧面板
            .inspector(isPresented: inspectorPresented) {
                InspectorContentView()
                    .environmentObject(appState)
            }
            .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
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
                // 右侧面板切换按钮（保留手动控制）
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            appState.rightSidebarCollapsed.toggle()
                        }
                    }) {
                        Image(systemName: "sidebar.right")
                    }
                    .help(appState.rightSidebarCollapsed ? "显示检查器 (⌘⌃I)" : "隐藏检查器 (⌘⌃I)")
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
