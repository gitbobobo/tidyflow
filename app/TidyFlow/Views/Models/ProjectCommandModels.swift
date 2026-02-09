import Foundation

// MARK: - 项目级命令模型

/// 项目级命令配置（作为后台任务执行，不新建终端 tab）
struct ProjectCommand: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var icon: String        // SF Symbol 名称或 "brand:xxx"
    var command: String     // Shell 命令
    var blocking: Bool      // 是否阻塞（阻塞时同一工作空间不允许执行其他项目命令）
    var interactive: Bool   // 交互式命令：在新终端 Tab 中执行（前台任务），而非后台任务

    init(id: String = UUID().uuidString, name: String = "", icon: String = "terminal", command: String = "", blocking: Bool = false, interactive: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.command = command
        self.blocking = blocking
        self.interactive = interactive
    }
}
