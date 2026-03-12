import SwiftUI

struct TabStripView: View {
    @EnvironmentObject var appState: AppState

    /// 收起模式下仍显示顶层类别，只是整体高度更紧凑。
    var collapsed: Bool = false
    var onResizeDrag: ((CGFloat) -> Void)? = nil
    var onResizeDragEnd: (() -> Void)? = nil
    var onResizeDoubleTap: (() -> Void)? = nil

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
        .frame(height: collapsed ? BottomPanelLayoutSemantics.collapsedTabStripHeight : BottomPanelLayoutSemantics.expandedTabStripHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .top) {
            topResizeHandle
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
                appState.toggleBottomPanel()
            }
        } label: {
            BottomPanelAccessoryIconLabel(
                systemName: appState.tabPanelExpanded ? "chevron.down" : "chevron.up"
            )
        }
        .buttonStyle(BottomPanelAccessoryButtonStyle())
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

    /// 从 Coordinator 缓存推导工作区级 AI 状态令牌，空闲时返回 nil。
    ///
    /// v1.46：不再读 AI 会话快照，由 Core 聚合后的 coordinator 状态决定展示态。
    private func aiStatus() -> TerminalAIStatus? {
        guard let globalKey = appState.currentGlobalWorkspaceKey,
              let wsId = CoordinatorWorkspaceId.fromGlobalKey(globalKey) else { return nil }
        let status = TerminalSessionSemantics.terminalAIStatus(
            fromCache: appState.coordinatorStateCache,
            workspaceId: wsId
        )
        return status.isVisible ? status : nil
    }

    private var topResizeHandle: some View {
        VerticalSplitDivider(
            isResizable: true,
            onDrag: { delta in
                onResizeDrag?(delta)
            },
            onDragEnd: {
                onResizeDragEnd?()
            },
            onDoubleTap: {
                onResizeDoubleTap?()
            }
        )
        .overlay(alignment: .bottom) {
            Divider()
        }
        .offset(y: -BottomPanelLayoutSemantics.resizeHandleHitAreaHeight / 2)
        .allowsHitTesting(onResizeDrag != nil)
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
                BottomPanelAccessoryIconLabel(systemName: "plus")
            }
            .buttonStyle(BottomPanelAccessoryButtonStyle())
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
                BottomPanelAccessoryIconLabel(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("tab.newTerminal.tooltip".localized)
        }
    }
}

private struct BottomPanelAccessoryIconLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(.rect)
    }
}

private struct BottomPanelAccessoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BottomPanelAccessoryButtonBody(configuration: configuration)
    }
}

private struct BottomPanelAccessoryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    private var backgroundColor: Color {
        if configuration.isPressed {
            return Color(NSColor.controlBackgroundColor).opacity(0.9)
        }
        if isHovered {
            return Color(NSColor.controlBackgroundColor).opacity(0.65)
        }
        return .clear
    }

    var body: some View {
        configuration.label
            .background(backgroundColor)
            .clipShape(.rect(cornerRadius: 5))
            .onHover { hovering in
                isHovered = hovering
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
