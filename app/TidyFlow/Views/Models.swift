import Foundation
import Combine
import SwiftUI

enum RightTool: String, CaseIterable {
    case explorer
    case search
    case git
}

enum ConnectionState {
    case connected
    case disconnected
}

enum TabKind: String, Codable {
    case terminal
    case editor
    case diff
    
    var iconName: String {
        switch self {
        case .terminal: return "terminal"
        case .editor: return "doc.text"
        case .diff: return "arrow.left.arrow.right"
        }
    }
}

struct TabModel: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let kind: TabKind
    let workspaceKey: String
    let payload: String
}

typealias TabSet = [TabModel]

// MARK: - Command Palette Models

enum PaletteMode {
    case command
    case file
}

enum CommandScope {
    case global
    case workspace
}

struct Command: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let scope: CommandScope
    let keyHint: String?
    let action: (AppState) -> Void
}

class AppState: ObservableObject {
    @Published var selectedWorkspaceKey: String?
    @Published var activeRightTool: RightTool? = .explorer
    @Published var connectionState: ConnectionState = .disconnected
    
    @Published var workspaceTabs: [String: TabSet] = [:]
    @Published var activeTabIdByWorkspace: [String: UUID] = [:]
    
    // Command Palette State
    @Published var commandPalettePresented: Bool = false
    @Published var commandPaletteMode: PaletteMode = .command
    @Published var commandQuery: String = ""
    @Published var paletteSelectionIndex: Int = 0
    
    // Mock data for workspaces
    let workspaces = [
        "default": "Default Workspace",
        "project-alpha": "Project Alpha",
        "project-beta": "Project Beta"
    ]
    
    // Mock files for Quick Open
    let mockFiles: [String: [String]] = [
        "default": ["README.md", "src/main.rs", "Cargo.toml", ".gitignore", "docs/DESIGN.md"],
        "project-alpha": ["Alpha.swift", "AppDelegate.swift", "Info.plist"],
        "project-beta": ["index.html", "style.css", "script.js", "package.json"]
    ]
    
    var commands: [Command] = []
    
    init() {
        // Set default workspace
        self.selectedWorkspaceKey = "default"
        ensureDefaultTab(for: "default")
        setupCommands()
    }
    
    private func setupCommands() {
        self.commands = [
            Command(id: "global.palette", title: "Show Command Palette", subtitle: nil, scope: .global, keyHint: "Cmd+Shift+P") { app in
                app.commandPaletteMode = .command
                app.commandPalettePresented = true
                app.commandQuery = ""
                app.paletteSelectionIndex = 0
            },
            Command(id: "global.quickOpen", title: "Quick Open", subtitle: "Go to file", scope: .global, keyHint: "Cmd+P") { app in
                app.commandPaletteMode = .file
                app.commandPalettePresented = true
                app.commandQuery = ""
                app.paletteSelectionIndex = 0
            },
            Command(id: "global.toggleExplorer", title: "Show Explorer", subtitle: nil, scope: .global, keyHint: "Cmd+1") { app in
                app.activeRightTool = .explorer
            },
            Command(id: "global.toggleSearch", title: "Show Search", subtitle: nil, scope: .global, keyHint: "Cmd+2") { app in
                app.activeRightTool = .search
            },
            Command(id: "global.toggleGit", title: "Show Git", subtitle: nil, scope: .global, keyHint: "Cmd+3") { app in
                app.activeRightTool = .git
            },
            Command(id: "global.reconnect", title: "Reconnect", subtitle: nil, scope: .global, keyHint: "Cmd+R") { app in
                app.connectionState = (app.connectionState == .connected) ? .disconnected : .connected
            },
            Command(id: "workspace.newTerminal", title: "New Terminal", subtitle: nil, scope: .workspace, keyHint: "Cmd+T") { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.addTerminalTab(workspaceKey: ws)
            },
            Command(id: "workspace.closeTab", title: "Close Active Tab", subtitle: nil, scope: .workspace, keyHint: "Cmd+W") { app in
                guard let ws = app.selectedWorkspaceKey,
                      let tabId = app.activeTabIdByWorkspace[ws] else { return }
                app.closeTab(workspaceKey: ws, tabId: tabId)
            },
            Command(id: "workspace.nextTab", title: "Next Tab", subtitle: nil, scope: .workspace, keyHint: "Ctrl+Tab") { app in
                app.nextTab()
            },
            Command(id: "workspace.prevTab", title: "Previous Tab", subtitle: nil, scope: .workspace, keyHint: "Ctrl+Shift+Tab") { app in
                app.prevTab()
            },
            Command(id: "workspace.save", title: "Save File", subtitle: nil, scope: .workspace, keyHint: "Cmd+S") { app in
                 // Placeholder save
                 print("(placeholder) saved")
            }
        ]
    }
    
    // MARK: - Tab Helpers
    
    func ensureDefaultTab(for workspaceKey: String) {
        if workspaceTabs[workspaceKey]?.isEmpty ?? true {
            let newTab = TabModel(
                id: UUID(),
                title: "Terminal",
                kind: .terminal,
                workspaceKey: workspaceKey,
                payload: ""
            )
            workspaceTabs[workspaceKey] = [newTab]
            activeTabIdByWorkspace[workspaceKey] = newTab.id
        }
    }
    
    func activateTab(workspaceKey: String, tabId: UUID) {
        activeTabIdByWorkspace[workspaceKey] = tabId
    }
    
    func closeTab(workspaceKey: String, tabId: UUID) {
        guard var tabs = workspaceTabs[workspaceKey] else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        
        let isActive = activeTabIdByWorkspace[workspaceKey] == tabId
        tabs.remove(at: index)
        workspaceTabs[workspaceKey] = tabs
        
        if isActive {
            if tabs.isEmpty {
                activeTabIdByWorkspace[workspaceKey] = nil
            } else {
                // Select previous tab if possible, else next
                let newIndex = max(0, min(index, tabs.count - 1))
                activeTabIdByWorkspace[workspaceKey] = tabs[newIndex].id
            }
        }
    }
    
    func addTab(workspaceKey: String, kind: TabKind, title: String, payload: String) {
        let newTab = TabModel(
            id: UUID(),
            title: title,
            kind: kind,
            workspaceKey: workspaceKey,
            payload: payload
        )
        
        if workspaceTabs[workspaceKey] == nil {
            workspaceTabs[workspaceKey] = []
        }
        
        workspaceTabs[workspaceKey]?.append(newTab)
        activeTabIdByWorkspace[workspaceKey] = newTab.id
    }
    
    func addTerminalTab(workspaceKey: String) {
        addTab(workspaceKey: workspaceKey, kind: .terminal, title: "Terminal", payload: "")
    }
    
    func addEditorTab(workspaceKey: String, path: String) {
        addTab(workspaceKey: workspaceKey, kind: .editor, title: path, payload: path)
    }
    
    func addDiffTab(workspaceKey: String, path: String) {
        addTab(workspaceKey: workspaceKey, kind: .diff, title: "Diff: \(path)", payload: path)
    }
    
    func nextTab() {
        guard let ws = selectedWorkspaceKey,
              let tabs = workspaceTabs[ws], !tabs.isEmpty,
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId }) else { return }
        
        let nextIndex = (index + 1) % tabs.count
        activeTabIdByWorkspace[ws] = tabs[nextIndex].id
    }
    
    func prevTab() {
        guard let ws = selectedWorkspaceKey,
              let tabs = workspaceTabs[ws], !tabs.isEmpty,
              let activeId = activeTabIdByWorkspace[ws],
              let index = tabs.firstIndex(where: { $0.id == activeId }) else { return }
        
        let prevIndex = (index - 1 + tabs.count) % tabs.count
        activeTabIdByWorkspace[ws] = tabs[prevIndex].id
    }
}
