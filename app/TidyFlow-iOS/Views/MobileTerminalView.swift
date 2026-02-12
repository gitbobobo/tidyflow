import SwiftUI

/// 全屏终端容器视图
struct MobileTerminalView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String
    /// 附着已有终端的 ID（nil 表示新建终端）
    var termId: String? = nil

    var body: some View {
        // 仅使用 xterm.js 输入链路，避免覆盖层拦截焦点/触摸
        MobileTerminalWebView(bridge: appState.bridge) { sequence in
            appState.sendSpecialKey(sequence)
        }
        .background(Color(red: 30/255, green: 30/255, blue: 30/255))
        .navigationTitle(workspace)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            if let termId {
                appState.attachTerminal(project: project, workspace: workspace, termId: termId)
            } else {
                appState.createTerminalForWorkspace(project: project, workspace: workspace)
            }
        }
        .onDisappear {
            appState.detachTerminal()
        }
    }
}
