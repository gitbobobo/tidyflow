import SwiftUI

/// 全屏终端容器视图
struct MobileTerminalView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String
    /// 附着已有终端的 ID（nil 表示新建终端）
    var termId: String? = nil
    /// 创建后自动执行的命令
    var command: String? = nil

    var body: some View {
        SwiftTermTerminalView(
            appState: appState,
            onKey: { sequence in
                appState.sendSpecialKey(sequence)
            },
            onCtrlArmedChanged: { armed in
                appState.setCtrlArmed(armed)
            }
        )
        .background(Color(red: 30/255, green: 30/255, blue: 30/255))
        .navigationTitle(workspace)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            if let termId {
                appState.attachTerminal(project: project, workspace: workspace, termId: termId)
            } else if let command {
                appState.createTerminalWithCommand(project: project, workspace: workspace, command: command)
            } else {
                appState.createTerminalForWorkspace(project: project, workspace: workspace)
            }
        }
        .onDisappear {
            appState.detachTerminal()
        }
    }
}
