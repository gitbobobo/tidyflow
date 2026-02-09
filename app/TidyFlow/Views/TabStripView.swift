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
                                workspaceKey: globalKey,
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
                
                // 新建终端按钮（根据是否有自定义命令显示不同UI）
                NewTerminalButton(globalKey: globalKey)
                    .environmentObject(appState)
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
    @EnvironmentObject var appState: AppState
    let tab: TabModel
    let isActive: Bool
    let workspaceKey: String
    let onClose: () -> Void
    let onActivate: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 6) {
            // 文件图标位置：dirty 时显示橙色圆点，否则显示类型图标（终端快捷命令 tab 使用 commandIcon）
            if tab.isDirty {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundColor(.orange)
                    .frame(width: 11)
            } else {
                let effectiveIconName = (tab.kind == .terminal && tab.commandIcon != nil) ? tab.commandIcon! : tab.kind.iconName
                CommandIconView(iconName: effectiveIconName, size: 11)
                    .foregroundColor(isActive ? .primary : .secondary)
            }

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
        .contextMenu {
            Button("tab.close".localized) {
                onClose()
            }
            .keyboardShortcut("w", modifiers: .command)

            let tabs = appState.workspaceTabs[workspaceKey] ?? []
            let otherTabs = tabs.filter { $0.id != tab.id }

            Button("tab.closeOthers".localized) {
                appState.closeOtherTabs(workspaceKey: workspaceKey, keepTabId: tab.id)
            }
            .keyboardShortcut("t", modifiers: [.option, .command])
            .disabled(otherTabs.isEmpty)

            let tabIndex = tabs.firstIndex(where: { $0.id == tab.id }) ?? tabs.endIndex
            let hasRightTabs = tabIndex < tabs.count - 1

            Button("tab.closeRight".localized) {
                appState.closeTabsToRight(workspaceKey: workspaceKey, ofTabId: tab.id)
            }
            .disabled(!hasRightTabs)

            Divider()

            Button("tab.closeSaved".localized) {
                appState.closeSavedTabs(workspaceKey: workspaceKey)
            }

            Button("tab.closeAll".localized) {
                appState.closeAllTabs(workspaceKey: workspaceKey)
            }
        }
    }
}

// MARK: - 新建终端按钮（支持自定义命令下拉菜单）

struct NewTerminalButton: View {
    @EnvironmentObject var appState: AppState
    let globalKey: String
    
    var body: some View {
        if appState.clientSettings.customCommands.isEmpty {
            // 没有自定义命令时，显示普通按钮
            Button(action: {
                appState.addTab(workspaceKey: globalKey, kind: .terminal, title: "Terminal", payload: "")
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("tab.newTerminal.tooltip".localized)
        } else {
            // 有自定义命令时，显示下拉菜单
            Menu {
                // 新建空白终端
                Button(action: {
                    appState.addTab(workspaceKey: globalKey, kind: .terminal, title: "Terminal", payload: "")
                }) {
                    Label("tab.newTerminal".localized, systemImage: "terminal")
                }
                
                Divider()
                
                // 自定义命令列表
                ForEach(appState.clientSettings.customCommands) { command in
                    Button(action: {
                        appState.addTerminalWithCustomCommand(workspaceKey: globalKey, command: command)
                    }) {
                        Label {
                            Text(command.name)
                        } icon: {
                            CommandMenuIcon(iconName: command.icon)
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("tab.newTerminal.tooltip".localized)
        }
    }
}

// MARK: - 菜单图标视图（品牌图标用 FixedSizeAssetImage，与项目侧栏/工具栏菜单一致，macOS 按 intrinsic size 显示需在绘制时缩放到目标尺寸）

struct CommandMenuIcon: View {
    let iconName: String
    
    /// 菜单项图标尺寸（与 ProjectsSidebarView、TopToolbarView 的 menuIconSize 一致）
    private let menuIconSize: CGFloat = 16
    
    var body: some View {
        Group {
            if iconName.hasPrefix("brand:") {
                let brandName = String(iconName.dropFirst(6))
                if let brand = BrandIcon(rawValue: brandName) {
                    FixedSizeAssetImage(name: brand.assetName, targetSize: menuIconSize)
                }
            } else if iconName.hasPrefix("custom:") {
                Image(systemName: "terminal")
            } else {
                Image(systemName: iconName)
            }
        }
    }
}
