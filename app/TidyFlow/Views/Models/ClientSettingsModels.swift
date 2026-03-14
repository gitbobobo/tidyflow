import Foundation
import SwiftUI
import TidyFlowShared

// MARK: - Evolution Stage Semantics（平台展示语义扩展）

/// 平台特有的展示方法：.localized 文案和 Color 映射。
/// 纯逻辑部分（归一化、排序、icon）已下沉到 TidyFlowShared。
extension EvolutionStageSemantics {
    static func displayName(for stage: String) -> String {
        let trimmed = stage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "evolution.stage.unnamed".localized }
        let normalized = trimmed.lowercased()
        if normalized.hasPrefix("implement.general.") {
            let index = normalized.split(separator: ".").last.flatMap { Int($0) } ?? 0
            return "Implement General #\(index)"
        }
        if normalized.hasPrefix("implement.visual.") {
            let index = normalized.split(separator: ".").last.flatMap { Int($0) } ?? 0
            return "Implement Visual #\(index)"
        }
        if normalized.hasPrefix("verify.") {
            let index = normalized.split(separator: ".").last.flatMap { Int($0) } ?? 0
            return "Verify #\(index)"
        }
        if normalized.hasPrefix("reimplement.") {
            let index = normalized.split(separator: ".").last.flatMap { Int($0) } ?? 0
            return "Reimplement #\(index)"
        }
        switch normalized {
        case "direction":
            return "evolution.stage.direction".localized
        case "plan":
            return "evolution.stage.plan".localized
        case "implement_general", "implement":
            return "evolution.stage.implementGeneral".localized
        case "implement_visual":
            return "evolution.stage.implementVisual".localized
        case "implement_advanced":
            return "evolution.stage.implementAdvanced".localized
        case "verify":
            return "evolution.stage.verify".localized
        case "auto_commit":
            return "evolution.stage.autoCommit".localized
        case "sync":
            return "evolution.stage.sync".localized
        case "integration":
            return "evolution.stage.integration".localized
        default:
            return trimmed
        }
    }

    static func stageColor(_ stage: String) -> Color {
        switch runtimeStageKey(stage) {
        case "direction":
            return .cyan
        case "plan":
            return .blue
        case "implement.general":
            return .orange
        case "implement.visual":
            return .pink
        case "reimplement":
            return .purple
        case "verify":
            return .green
        case "auto_commit":
            return .gray
        case "sync":
            return .teal
        case "integration":
            return .mint
        default:
            return .secondary
        }
    }
}

// MARK: - WorkspaceTodoStatus 本地化扩展

extension WorkspaceTodoStatus {
    var localizedTitle: String {
        switch self {
        case .pending: return "todo.status.pending".localized
        case .inProgress: return "todo.status.inProgress".localized
        case .completed: return "todo.status.completed".localized
        }
    }
}

/// 品牌图标枚举（用于自定义命令图标选择）
enum BrandIcon: String, CaseIterable {
    case cursor = "cursor"
    case vscode = "vscode"
    case trae = "trae"
    case claude = "claude"
    case codex = "codex"
    case gemini = "gemini"
    case opencode = "opencode"
    case copilot = "copilot"
    
    var assetName: String {
        switch self {
        case .cursor: return "cursor-icon"
        case .vscode: return "vscode-icon"
        case .trae: return "trae-icon"
        case .claude: return "claude-icon"
        case .codex: return "codex-icon"
        case .gemini: return "gemini-icon"
        case .opencode: return "opencode-icon"
        case .copilot: return "copilot-icon"
        }
    }
    
    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .trae: return "Trae"
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        case .copilot: return "Copilot CLI"
        }
    }

    /// 是否有 AI Agent 功能（VS Code 和 Trae 没有）
    var hasAIAgent: Bool {
        switch self {
        case .vscode, .trae: return false
        default: return true
        }
    }

    /// 建议的正常模式命令
    var suggestedCommand: String? {
        switch self {
        case .cursor: return "cursor-agent"
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .opencode: return "opencode"
        case .copilot: return "copilot"
        case .vscode, .trae: return nil
        }
    }

    /// 建议的 Yolo 模式命令（自动执行，跳过确认）
    var yoloCommand: String? {
        switch self {
        case .claude: return "claude --dangerously-skip-permissions"
        case .codex: return "codex --full-auto"
        case .gemini: return "gemini --approval-mode yolo --no-sandbox"
        case .cursor: return "cursor-agent --sandbox disabled -f"
        case .copilot: return "copilot --allow-all"
        default: return nil
        }
    }
}
