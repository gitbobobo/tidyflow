import SwiftUI

struct TabStripView: View {
    @EnvironmentObject var appState: AppState

    /// 收起模式下仍显示顶层类别，只是整体高度更紧凑。
    var collapsed: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if let globalKey = appState.currentGlobalWorkspaceKey {
                let activeCategory = appState.activeBottomPanelCategory(workspaceKey: globalKey)
                categoryStrip(workspaceKey: globalKey)
                Spacer(minLength: 8)

                if activeCategory == .terminal {
                    NewTerminalButton(globalKey: globalKey)
                        .environmentObject(appState)
                        .padding(.horizontal, 4)
                }

                aiStatusIndicator(globalKey: globalKey)
                    .padding(.horizontal, 2)

                panelToggleButton
                    .padding(.trailing, 6)
            } else {
                Spacer()
            }
        }
        .frame(height: collapsed ? 28 : 34)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("tf.mac.bottomPanel.category-strip")
    }

    @ViewBuilder
    private func categoryStrip(workspaceKey: String) -> some View {
        let activeCategory = appState.activeBottomPanelCategory(workspaceKey: workspaceKey)
        HStack(spacing: 4) {
            ForEach(BottomPanelCategory.allCases, id: \.rawValue) { category in
                BottomPanelCategoryButton(
                    category: category,
                    isActive: activeCategory == category,
                    isCompact: collapsed,
                    itemCount: appState.tabs(in: category, workspaceKey: workspaceKey).count
                ) {
                    appState.activateBottomPanelCategory(workspaceKey: workspaceKey, category: category)
                }
            }
        }
        .padding(.leading, 6)
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(appState.tabPanelExpanded ? "tab.panel.collapse.tooltip".localized : "tab.panel.expand.tooltip".localized)
    }

    @ViewBuilder
    private func aiStatusIndicator(globalKey _: String) -> some View {
        if let status = aiStatus() {
            Image(systemName: status.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status.color)
                .help(status.hint)
                .frame(width: 16, height: 16)
        }
    }

    /// 从当前活跃 AI 会话推导工作区级状态令牌，空闲时返回 nil。
    private func aiStatus() -> TerminalAIStatus? {
        guard let workspaceKey = appState.selectedWorkspaceKey,
              let sessionId = appState.aiStore(for: appState.aiChatTool).currentSessionId else { return nil }
        let session = AISessionInfo(
            projectName: appState.selectedProjectName,
            workspaceName: workspaceKey,
            aiTool: appState.aiChatTool,
            id: sessionId,
            title: "",
            updatedAt: 0
        )
        guard let snapshot = appState.aiSessionStatus(for: session) else { return nil }
        let status = TerminalSessionSemantics.terminalAIStatus(
            from: snapshot.normalizedStatus,
            errorMessage: snapshot.errorMessage,
            toolName: nil,
            aiToolDisplayName: appState.aiChatTool.displayName
        )
        return status.isVisible ? status : nil
    }
}

private struct BottomPanelCategoryButton: View {
    let category: BottomPanelCategory
    let isActive: Bool
    let isCompact: Bool
    let itemCount: Int
    let action: () -> Void

    @State private var isHovered: Bool = false

    private var backgroundColor: Color {
        if isActive {
            return Color(NSColor.controlBackgroundColor)
        }
        if isHovered {
            return Color(NSColor.controlBackgroundColor).opacity(0.55)
        }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.iconName)
                    .font(.system(size: isCompact ? 10 : 11))
                Text(category.titleKey.localized)
                    .font(.system(size: isCompact ? 11 : 12, weight: isActive ? .semibold : .regular))
                if itemCount > 0 {
                    Text("\(itemCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(isActive ? 0.18 : 0.12))
                        )
                }
            }
            .lineLimit(1)
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(height: isCompact ? 24 : 28)
            .background(backgroundColor)
            .clipShape(.rect(cornerRadius: 5))
            .overlay(alignment: .bottom) {
                if isActive {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tf.mac.bottomPanel.category.\(category.rawValue)")
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 新建终端按钮（支持自定义命令下拉菜单）

struct NewTerminalButton: View {
    @EnvironmentObject var appState: AppState
    let globalKey: String

    var body: some View {
        if appState.clientSettings.customCommands.isEmpty {
            Button(action: {
                appState.addTab(workspaceKey: globalKey, kind: .terminal, title: "Terminal", payload: "")
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("tab.newTerminal.tooltip".localized)
        } else {
            Menu {
                Button(action: {
                    appState.addTab(workspaceKey: globalKey, kind: .terminal, title: "Terminal", payload: "")
                }) {
                    Label("tab.newTerminal".localized, systemImage: "terminal")
                }

                Divider()

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
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("tab.newTerminal.tooltip".localized)
        }
    }
}

// MARK: - 菜单图标视图

struct CommandMenuIcon: View {
    let iconName: String

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
