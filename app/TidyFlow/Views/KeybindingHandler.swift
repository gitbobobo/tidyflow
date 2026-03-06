import SwiftUI

struct GlobalKeybindingHandler: ViewModifier {
    @EnvironmentObject var appState: AppState

    func body(content: Content) -> some View {
        content
            .background(
                Group {
                    // 用户可配置的快捷键
                    Button("Palette") { runCommand("global.palette") }
                        .keyboardShortcutIfPresent(shortcut(for: "global.palette"))

                    Button("Quick Open") { runCommand("global.quickOpen") }
                        .keyboardShortcutIfPresent(shortcut(for: "global.quickOpen"))

                    Button("Reconnect") { runCommand("global.reconnect") }
                        .keyboardShortcutIfPresent(shortcut(for: "global.reconnect"))

                    Button("New Terminal") { runCommand("workspace.newTerminal") }
                        .keyboardShortcutIfPresent(shortcut(for: "workspace.newTerminal"))

                    Button("Close Tab") { runCommand("workspace.closeTab") }
                        .keyboardShortcutIfPresent(shortcut(for: "workspace.closeTab"))

                    Button("Close Other Tabs") { runCommand("workspace.closeOtherTabs") }
                        .keyboardShortcutIfPresent(shortcut(for: "workspace.closeOtherTabs"))

                    Button("Next Tab") { runCommand("workspace.nextTab") }
                        .keyboardShortcutIfPresent(shortcut(for: "workspace.nextTab"))

                    Button("Prev Tab") { runCommand("workspace.prevTab") }
                        .keyboardShortcutIfPresent(shortcut(for: "workspace.prevTab"))

                    Button("Save") { runCommand("workspace.save") }
                        .keyboardShortcutIfPresent(shortcut(for: "workspace.save"))

                    Button("Find") { runCommand("workspace.find") }
                        .keyboardShortcutIfPresent(shortcut(for: "workspace.find"))

                    // 不可配置的固定快捷键
                    Button("Undo") { runCommand("workspace.undo") }
                        .keyboardShortcut("z", modifiers: .command)

                    Button("Redo") { runCommand("workspace.redo") }
                        .keyboardShortcut("z", modifiers: [.command, .shift])

                    Button("New File") { runCommand("workspace.newFile") }
                        .keyboardShortcut("n", modifiers: .command)

                    Button("Save As") { runCommand("workspace.saveAs") }
                        .keyboardShortcut("s", modifiers: [.command, .shift])

                    // Debug Panel (hidden, developer only)
                    Button("Debug Panel") { appState.debugPanelPresented.toggle() }
                        .keyboardShortcut("d", modifiers: [.command, .shift])

                    // Tab 索引切换 Ctrl+1-9
                    Button("Switch Tab 1") { appState.switchToTabByIndex(1) }
                        .keyboardShortcut("1", modifiers: .control)
                    Button("Switch Tab 2") { appState.switchToTabByIndex(2) }
                        .keyboardShortcut("2", modifiers: .control)
                    Button("Switch Tab 3") { appState.switchToTabByIndex(3) }
                        .keyboardShortcut("3", modifiers: .control)
                    Button("Switch Tab 4") { appState.switchToTabByIndex(4) }
                        .keyboardShortcut("4", modifiers: .control)
                    Button("Switch Tab 5") { appState.switchToTabByIndex(5) }
                        .keyboardShortcut("5", modifiers: .control)
                    Button("Switch Tab 6") { appState.switchToTabByIndex(6) }
                        .keyboardShortcut("6", modifiers: .control)
                    Button("Switch Tab 7") { appState.switchToTabByIndex(7) }
                        .keyboardShortcut("7", modifiers: .control)
                    Button("Switch Tab 8") { appState.switchToTabByIndex(8) }
                        .keyboardShortcut("8", modifiers: .control)
                    Button("Switch Tab 9") { appState.switchToTabByIndex(9) }
                        .keyboardShortcut("9", modifiers: .control)

                    // 工作空间快捷键 Cmd+1-9
                    Button("Switch Workspace 1") { appState.switchToWorkspaceByShortcut(shortcutKey: "1") }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("Switch Workspace 2") { appState.switchToWorkspaceByShortcut(shortcutKey: "2") }
                        .keyboardShortcut("2", modifiers: .command)
                    Button("Switch Workspace 3") { appState.switchToWorkspaceByShortcut(shortcutKey: "3") }
                        .keyboardShortcut("3", modifiers: .command)
                    Button("Switch Workspace 4") { appState.switchToWorkspaceByShortcut(shortcutKey: "4") }
                        .keyboardShortcut("4", modifiers: .command)
                    Button("Switch Workspace 5") { appState.switchToWorkspaceByShortcut(shortcutKey: "5") }
                        .keyboardShortcut("5", modifiers: .command)
                    Button("Switch Workspace 6") { appState.switchToWorkspaceByShortcut(shortcutKey: "6") }
                        .keyboardShortcut("6", modifiers: .command)
                    Button("Switch Workspace 7") { appState.switchToWorkspaceByShortcut(shortcutKey: "7") }
                        .keyboardShortcut("7", modifiers: .command)
                    Button("Switch Workspace 8") { appState.switchToWorkspaceByShortcut(shortcutKey: "8") }
                        .keyboardShortcut("8", modifiers: .command)
                    Button("Switch Workspace 9") { appState.switchToWorkspaceByShortcut(shortcutKey: "9") }
                        .keyboardShortcut("9", modifiers: .command)
                }
                .hidden()
            )
    }

    func runCommand(_ id: String) {
        if let cmd = appState.commands.first(where: { $0.id == id }) {
            // Check scope
            if cmd.scope == .workspace && appState.selectedWorkspaceKey == nil {
                return
            }
            cmd.action(appState)
        }
    }

    /// 将快捷键字符串（如 "cmd+shift+p"）解析为 SwiftUI KeyEquivalent 和 EventModifiers
    private func parseKeyCombination(_ combo: String) -> (KeyEquivalent, EventModifiers)? {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        var modifiers: EventModifiers = []
        var key: String? = nil

        for part in parts {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "ctrl", "control": modifiers.insert(.control)
            case "option", "alt": modifiers.insert(.option)
            case "tab": key = "\t"
            default: key = part
            }
        }

        guard let keyStr = key else { return nil }
        if keyStr == "\t" {
            return (.tab, modifiers)
        }
        guard let firstChar = keyStr.first else { return nil }
        return (KeyEquivalent(firstChar), modifiers)
    }

    /// 从用户配置中获取快捷键，找不到则使用默认配置
    private func shortcut(for commandId: String) -> (KeyEquivalent, EventModifiers)? {
        let bindings = appState.clientSettings.keybindings
        if let userBinding = bindings.first(where: { $0.commandId == commandId }) {
            return parseKeyCombination(userBinding.keyCombination)
        }
        if let defaultBinding = KeybindingConfig.defaultKeybindings().first(where: { $0.commandId == commandId }) {
            return parseKeyCombination(defaultBinding.keyCombination)
        }
        return nil
    }
}

extension View {
    func handleGlobalKeybindings() -> some View {
        self.modifier(GlobalKeybindingHandler())
    }

    /// 仅在快捷键存在时应用 keyboardShortcut
    @ViewBuilder
    func keyboardShortcutIfPresent(_ combo: (KeyEquivalent, EventModifiers)?) -> some View {
        if let (key, modifiers) = combo {
            self.keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }
}
