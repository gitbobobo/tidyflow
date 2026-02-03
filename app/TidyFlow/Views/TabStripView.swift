import SwiftUI

struct TabStripView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack(spacing: 0) {
            // 使用全局工作空间键来访问 tabs（区分不同项目的同名工作空间）
            if let globalKey = appState.currentGlobalWorkspaceKey,
               let tabs = appState.workspaceTabs[globalKey] {
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(tabs) { tab in
                            TabItemView(
                                tab: tab,
                                isActive: appState.activeTabIdByWorkspace[globalKey] == tab.id,
                                onClose: {
                                    appState.closeTab(workspaceKey: globalKey, tabId: tab.id)
                                },
                                onActivate: {
                                    appState.activateTab(workspaceKey: globalKey, tabId: tab.id)
                                }
                            )
                        }
                    }
                    .padding(.leading, 1)
                }
                
                // 新建终端按钮
                Button(action: {
                    appState.addTab(workspaceKey: globalKey, kind: .terminal, title: "Terminal", payload: "")
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("新建终端 (⌘T)")
                .padding(.horizontal, 8)
            } else {
                Spacer()
            }
        }
        .frame(height: 32)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Divider(), alignment: .bottom
        )
    }
}

struct TabItemView: View {
    let tab: TabModel
    let isActive: Bool
    let onClose: () -> Void
    let onActivate: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.kind.iconName)
                .font(.system(size: 11))
                .foregroundColor(isActive ? .primary : .secondary)
            
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(isActive ? .primary : .secondary)
            
            if isActive || isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .foregroundColor(.secondary)
            } else {
                Spacer()
                    .frame(width: 16)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(isActive ? Color(NSColor.controlBackgroundColor) : Color(NSColor.windowBackgroundColor))
        .cornerRadius(isActive ? 4 : 0)
        .onTapGesture {
            onActivate()
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
