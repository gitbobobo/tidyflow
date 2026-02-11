import SwiftUI

/// 全屏终端容器视图
struct MobileTerminalView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    var body: some View {
        VStack(spacing: 0) {
            // 仅使用 xterm.js 输入链路，避免覆盖层拦截焦点/触摸
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
            appState.createTerminalForWorkspace(project: project, workspace: workspace)
        }
        .onDisappear {
            appState.detachTerminal()
        }
    }
}
