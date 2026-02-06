import SwiftUI

/// 工作空间快捷操作视图
/// 选择工作空间后显示，提供打开终端、执行自定义命令等快捷操作
struct QuickActionsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 32) {
                Spacer()

                // 工作空间信息头部
                workspaceHeader

                VStack(spacing: 16) {
                    // 主要操作：打开终端
                    openTerminalButton

                    // 自定义命令列表
                    if !appState.clientSettings.customCommands.isEmpty {
                        customCommandsSection
                    }
                }
                .padding(.bottom, 32)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 右下角快捷键提示
            keyboardShortcutsHint
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 快捷键提示

    private var keyboardShortcutsHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            shortcutRow(keys: "⌘ 1-9", description: "quickActions.switchWorkspace".localized)
            shortcutRow(keys: "⌃ 1-9", description: "quickActions.switchTab".localized)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
    }

    private func shortcutRow(keys: String, description: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.caption)
                .monospaced()
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text(description)
                .font(.caption)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
    }

    // MARK: - 工作空间信息头部

    private var workspaceHeader: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)

            VStack(spacing: 4) {
                Text(appState.selectedProjectName)
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                if let workspace = appState.selectedWorkspaceKey {
                    Text(workspace)
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - 打开终端按钮

    private var openTerminalButton: some View {
        Button(action: openTerminal) {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.title3)
                    .frame(width: 24, height: 24)

                Text("quickActions.openTerminal".localized)
                    .font(.headline)

                Spacer()

                Text("⌘T")
                    .font(.subheadline)
                    .monospaced()
                    .foregroundColor(.secondary)
            }
            .frame(width: 320)
        }
        .buttonStyle(QuickActionButtonStyle(isPrimary: true))
    }

    // MARK: - 自定义命令列表

    private var customCommandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("quickActions.quickCommands".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 8)

            VStack(spacing: 8) {
                ForEach(appState.clientSettings.customCommands) { command in
                    customCommandRow(command)
                }
            }
        }
        .frame(width: 320)
    }

    private func customCommandRow(_ command: CustomCommand) -> some View {
        Button(action: { executeCommand(command) }) {
            HStack(spacing: 12) {
                CommandIconView(iconName: command.icon, size: 20)
                    .foregroundColor(.secondary)

                Text(command.name)
                    .font(.body)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(QuickActionButtonStyle(isPrimary: false))
    }

    // MARK: - Actions

    private func openTerminal() {
        guard let workspaceKey = appState.currentGlobalWorkspaceKey else { return }
        appState.addTerminalTab(workspaceKey: workspaceKey)
    }

    private func executeCommand(_ command: CustomCommand) {
        guard let workspaceKey = appState.currentGlobalWorkspaceKey else { return }
        appState.addTerminalWithCustomCommand(workspaceKey: workspaceKey, command: command)
    }
}

// MARK: - Button Style

struct QuickActionButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        QuickActionButton(configuration: configuration, isPrimary: isPrimary)
    }

    private struct QuickActionButton: View {
        let configuration: Configuration
        let isPrimary: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hover in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovering = hover
                    }
                }
        }

        private var backgroundColor: Color {
            if isPrimary {
                if configuration.isPressed {
                    return Color.accentColor.opacity(0.25)
                }
                return isHovering ? Color.accentColor.opacity(0.15) : Color.accentColor.opacity(0.1)
            } else {
                if configuration.isPressed {
                    return Color(NSColor.selectedControlColor)
                }
                return isHovering ? Color(NSColor.controlBackgroundColor).opacity(0.8) : Color(NSColor.controlBackgroundColor).opacity(0.5)
            }
        }

        private var borderColor: Color {
            if isPrimary {
                return Color.accentColor.opacity(0.2)
            } else {
                return isHovering ? Color.primary.opacity(0.1) : Color.clear
            }
        }
    }
}
