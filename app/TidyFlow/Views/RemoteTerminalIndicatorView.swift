import SwiftUI

/// 工具栏远程终端指示器 — 显示当前工作空间中被远程设备连接的终端
struct RemoteTerminalIndicatorView: View {
    @EnvironmentObject var appState: AppState
    @State private var showPopover = false

    private var terminals: [RemoteTerminalInfo] {
        appState.remoteTerminalsInCurrentWorkspace
    }

    /// 去重后的终端数量（同一终端可能有多个远程订阅者）
    private var uniqueTermCount: Int {
        Set(terminals.map(\.termId)).count
    }

    var body: some View {
        if !terminals.isEmpty {
            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 12))
                    Text("\(uniqueTermCount)")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
            .help("toolbar.remoteTerminals".localized)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                remoteTermPopover
            }
        }
    }

    private var remoteTermPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("toolbar.remoteTerminals.title".localized)
                    .font(.headline)
                Spacer()
                if terminals.count > 1 {
                    Button("toolbar.remoteTerminals.closeAll".localized) {
                        appState.closeAllRemoteTerminals()
                        showPopover = false
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }
            .padding(.bottom, 4)

            Divider()

            // 按终端分组展示
            let grouped = Dictionary(grouping: terminals, by: \.termId)
            ForEach(Array(grouped.keys.sorted()), id: \.self) { termId in
                if let items = grouped[termId] {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(items.first?.workspace ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ForEach(items) { item in
                                HStack(spacing: 4) {
                                    Image(systemName: "iphone")
                                        .font(.system(size: 10))
                                    Text(item.deviceName)
                                        .font(.caption)
                                }
                            }
                        }
                        Spacer()
                        Button {
                            appState.closeRemoteTerminal(termId: termId)
                        } label: {
                            Text("toolbar.remoteTerminals.close".localized)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220)
    }
}
