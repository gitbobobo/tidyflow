import SwiftUI

struct TabStripView: View {
    @EnvironmentObject var appState: AppState

    /// 收起模式：仅显示 Tab 图标（类似 VSCode 底部状态条）
    var collapsed: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // 使用全局工作空间键来访问 tabs（区分不同项目的同名工作空间）
            if let globalKey = appState.currentGlobalWorkspaceKey,
               let tabs = appState.workspaceTabs[globalKey] {

                if collapsed {
                    // 收起模式：紧凑图标，点击展开面板并激活对应 Tab
                    collapsedContent(tabs: tabs, globalKey: globalKey)
                } else {
                    // 展开模式：完整 Tab 栏
                    expandedContent(tabs: tabs, globalKey: globalKey)
                }

            } else {
                Spacer()
            }
        }
        .frame(height: collapsed ? 28 : 34)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Divider(), alignment: .bottom
        )
    }

    // MARK: - 收起模式内容

    @ViewBuilder
    private func collapsedContent(tabs: [TabModel], globalKey: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    let isActive = appState.activeTabIdByWorkspace[globalKey] == tab.id
                    Button {
                        appState.activateTab(workspaceKey: globalKey, tabId: tab.id)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.tabPanelExpanded = true
                        }
                    } label: {
                        let effectiveIconName = (tab.kind == .terminal && tab.commandIcon != nil) ? tab.commandIcon! : tab.kind.iconName
                        CommandIconView(iconName: effectiveIconName, size: 11)
                            .foregroundColor(isActive ? .primary : .secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isActive ? Color(NSColor.controlBackgroundColor) : Color.clear)
                            )
                    }
                    .buttonStyle(.borderless)
                    .help(tab.title)
                }
            }
            .padding(.leading, 6)
        }

        panelToggleButton
            .padding(.horizontal, 2)

        // 收起模式下的新建终端按钮
        Button {
            appState.addTab(workspaceKey: globalKey, kind: .terminal, title: "Terminal", payload: "")
            withAnimation(.easeInOut(duration: 0.2)) {
                appState.tabPanelExpanded = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help("tab.newTerminal.tooltip".localized)
        .padding(.horizontal, 6)
    }

    // MARK: - 展开模式内容

    @ViewBuilder
    private func expandedContent(tabs: [TabModel], globalKey: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
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
            .padding(.horizontal, 4)

        panelToggleButton
            .padding(.trailing, 6)
    }

    private var panelToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if appState.tabPanelExpanded {
                    appState.tabPanelExpanded = false
                    appState.tabPanelHeight = 0
                } else {
                    appState.tabPanelExpanded = true
                }
            }
        } label: {
            Image(systemName: appState.tabPanelExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help(appState.tabPanelExpanded ? "tab.panel.collapse.tooltip".localized : "tab.panel.expand.tooltip".localized)
    }
}

// WorkspaceSpecialPageButton 已移除：macOS 端 AI 聊天常驻显示，不再需要切换按钮

struct TabItemView: View {
    @EnvironmentObject var appState: AppState
    let tab: TabModel
    let isActive: Bool
    let workspaceKey: String
    let onClose: () -> Void
    let onActivate: () -> Void
    
    @State private var isHovered: Bool = false
    
    /// tab 背景色
    private var tabBackground: Color {
        if isActive {
            return Color(NSColor.controlBackgroundColor)
        } else if isHovered {
            return Color(NSColor.controlBackgroundColor).opacity(0.5)
        } else {
            return Color.clear
        }
    }

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
        .background(tabBackground)
        .cornerRadius(4)
        .overlay(alignment: .bottom) {
            // 选中态底部指示条
            if isActive {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
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
