import SwiftUI

struct GlobalKeybindingHandler: ViewModifier {
    @EnvironmentObject var appState: AppState
    
    func body(content: Content) -> some View {
        content
            .background(
                Group {
                    // Global Scoped
                    Button("Palette") { runCommand("global.palette") }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                    
                    Button("Quick Open") { runCommand("global.quickOpen") }
                        .keyboardShortcut("p", modifiers: .command)
                        
                    Button("Reconnect") { runCommand("global.reconnect") }
                        .keyboardShortcut("r", modifiers: .command)
                        
                    // Workspace Scoped
                    Button("New Terminal") { runCommand("workspace.newTerminal") }
                        .keyboardShortcut("t", modifiers: .command)
                        
                    Button("Close Tab") { runCommand("workspace.closeTab") }
                        .keyboardShortcut("w", modifiers: .command)

                    Button("Close Other Tabs") { runCommand("workspace.closeOtherTabs") }
                        .keyboardShortcut("t", modifiers: [.option, .command])
                        
                    Button("Next Tab") { runCommand("workspace.nextTab") }
                        .keyboardShortcut(.tab, modifiers: .control)
                        
                    Button("Prev Tab") { runCommand("workspace.prevTab") }
                        .keyboardShortcut(.tab, modifiers: [.control, .shift])
                        
                    Button("Save") { runCommand("workspace.save") }
                        .keyboardShortcut("s", modifiers: .command)

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
}

extension View {
    func handleGlobalKeybindings() -> some View {
        self.modifier(GlobalKeybindingHandler())
    }
}
