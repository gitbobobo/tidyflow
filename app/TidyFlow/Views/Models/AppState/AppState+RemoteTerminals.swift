import Foundation

/// 远程终端信息（用于 macOS 工具栏展示）
struct RemoteTerminalInfo: Identifiable {
    let id: String // termId-connId
    let termId: String
    let project: String
    let workspace: String
    let deviceName: String
    let connId: String
}

extension AppState {
    /// 当前工作空间中被远程设备连接的终端（按 project + workspace 双重过滤）
    var remoteTerminalsInCurrentWorkspace: [RemoteTerminalInfo] {
        guard let workspace = selectedWorkspaceKey else { return [] }
        let project = selectedProjectName
        return remoteTerminals.filter { $0.project == project && $0.workspace == workspace }
    }

    /// 刷新远程终端状态（收到 RemoteTermChanged 时调用）
    func refreshRemoteTerminals() {
        TFLog.app.info("refreshRemoteTerminals: requesting term_list")
        wsClient.requestTermList()
    }

    /// 从 TermList 结果中提取远程终端信息
    func updateRemoteTerminals(from items: [TerminalSessionInfo]) {
        var result: [RemoteTerminalInfo] = []
        for item in items {
            for sub in item.remoteSubscribers {
                result.append(RemoteTerminalInfo(
                    id: "\(item.termId)-\(sub.connId)",
                    termId: item.termId,
                    project: item.project,
                    workspace: item.workspace,
                    deviceName: sub.deviceName,
                    connId: sub.connId
                ))
            }
        }
        TFLog.app.info("updateRemoteTerminals: \(items.count) terminals, \(result.count) remote entries, filter: project=\(self.selectedProjectName), workspace=\(self.selectedWorkspaceKey ?? "nil")")
        remoteTerminals = result
    }

    /// 关闭远程终端
    func closeRemoteTerminal(termId: String) {
        wsClient.requestTermClose(termId: termId)
    }

    /// 关闭当前工作空间所有远程终端
    func closeAllRemoteTerminals() {
        let terminals = remoteTerminalsInCurrentWorkspace
        let termIds = Set(terminals.map(\.termId))
        for termId in termIds {
            wsClient.requestTermClose(termId: termId)
        }
    }
}
