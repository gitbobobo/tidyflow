import SwiftUI

/// 全屏终端容器视图
struct MobileTerminalView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    var body: some View {
        VStack(spacing: 0) {
            // xterm.js WebView
            MobileTerminalWebView(bridge: appState.bridge)
                .ignoresSafeArea(.keyboard)

            // 特殊键工具栏
            TerminalAccessoryView { sequence in
                appState.sendSpecialKey(sequence)
            }
        }
        .background(Color(red: 30/255, green: 30/255, blue: 30/255))
        .navigationTitle(workspace)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            appState.setupBridgeCallbacks()
            appState.createTerminalForWorkspace(project: project, workspace: workspace)
        }
        .onDisappear {
            appState.detachTerminal()
        }
    }
}
