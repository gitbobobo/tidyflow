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
                    
                    Button("Explorer") { runCommand("global.toggleExplorer") }
                        .keyboardShortcut("1", modifiers: .command)
                    
                    Button("Search") { runCommand("global.toggleSearch") }
                        .keyboardShortcut("2", modifiers: .command)
                        
                    Button("Git") { runCommand("global.toggleGit") }
                        .keyboardShortcut("3", modifiers: .command)
                        
                    Button("Reconnect") { runCommand("global.reconnect") }
                        .keyboardShortcut("r", modifiers: .command)
                        
                    // Workspace Scoped
                    Button("New Terminal") { runCommand("workspace.newTerminal") }
                        .keyboardShortcut("t", modifiers: .command)
                        
                    Button("Close Tab") { runCommand("workspace.closeTab") }
                        .keyboardShortcut("w", modifiers: .command)
                        
                    Button("Next Tab") { runCommand("workspace.nextTab") }
                        .keyboardShortcut(.tab, modifiers: .control)
                        
                    Button("Prev Tab") { runCommand("workspace.prevTab") }
                        .keyboardShortcut(.tab, modifiers: [.control, .shift])
                        
                    Button("Save") { runCommand("workspace.save") }
                        .keyboardShortcut("s", modifiers: .command)

                    // Debug Panel (hidden, developer only)
                    Button("Debug Panel") { appState.debugPanelPresented.toggle() }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
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
