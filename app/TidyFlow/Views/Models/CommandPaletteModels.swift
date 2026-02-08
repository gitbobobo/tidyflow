import Foundation
import Combine

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

// MARK: - 命令面板独立状态（避免高频输入触发全局视图刷新）

class CommandPaletteState: ObservableObject {
    @Published var isPresented: Bool = false
    @Published var mode: PaletteMode = .command
    @Published var query: String = ""
    @Published var selectionIndex: Int = 0
}
