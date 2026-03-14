import Foundation

// MARK: - WSClient 分领域路由

extension WSClient {
    // BEGIN AUTO-GENERATED: protocol_receive_action_rules
    private var receiveProtocolExactRules: [(domain: String, action: String)] {
        [
        ("system", "ping"),
        ("terminal", "spawn_terminal"),
        ("terminal", "kill_terminal"),
        ("terminal", "input"),
        ("terminal", "resize"),
        ("file", "clipboard_image_upload"),
        ("git", "cancel_ai_task"),
        ("project", "save_template"),
        ("project", "delete_template"),
        ("project", "export_template"),
        ("project", "import_template"),
        ("project", "templates"),
        ("node", "node_refresh_network"),
        ]
    }

    private var receiveProtocolPrefixRules: [(domain: String, prefix: String)] {
        [
        ("terminal", "term_"),
        ("file", "file_"),
        ("file", "watch_"),
        ("git", "git_"),
        ("project", "list_"),
        ("project", "select_"),
        ("project", "import_"),
        ("project", "create_"),
        ("project", "remove_"),
        ("project", "project_"),
        ("project", "workspace_"),
        ("project", "save_project_commands"),
        ("project", "run_project_command"),
        ("project", "cancel_project_command"),
        ("project", "template_"),
        ("node", "node_"),
        ("ai", "ai_"),
        ("evidence", "evidence_"),
        ("evolution", "evo_"),
        ("git", "git_conflict_"),
        ("health", "health_"),
        ]
    }

    private var receiveProtocolContainsRules: [(domain: String, needle: String)] {
        [
        ("settings", "client_settings"),
        ]
    }
    // END AUTO-GENERATED: protocol_receive_action_rules

    private static let receiveSupplementalExactRules: Set<String> = [
        "system:hello",
        "system:pong",
        "terminal:output_batch",
        "terminal:exit",
        "terminal:remote_term_changed",
        "project:projects",
        "project:workspaces",
        "project:tasks_snapshot",
        "node:node_self_updated",
        "node:node_discovery_updated",
        "node:node_network_updated",
        "node:node_pairing_result",
        "node:node_peer_status",
        "health:health_snapshot",
        "health:health_repair_result",
        // v1.46: Coordinator 域（工作区级 AI 聚合状态增量快照）
        "coordinator:coordinator_snapshot",
    ]

    private static let fallbackActionCatalog: Set<String> = ["clipboard_image_set", "error"]

    public func routeByDomain(domain: String, action: String, json: [String: Any]) -> Bool {
        if !isActionDeclaredInReceiveCatalog(domain: domain, action: action) {
            CoreWSLog.ws.warning(
                "Action not declared in receive catalog: domain=\(domain, privacy: .public), action=\(action, privacy: .public)"
            )
        }

        switch domain {
        case "system":
            return handleSystemDomain(action, json: json)
        case "terminal":
            return handleTerminalDomain(action, json: json)
        case "git":
            return handleGitDomain(action, json: json)
        case "project":
            return handleProjectDomain(action, json: json)
        case "file":
            return handleFileDomain(action, json: json)
        case "settings":
            return handleSettingsDomain(action, json: json)
        case "node":
            return handleNodeDomain(action, json: json)
        case "ai":
            return handleAiDomain(action, json: json)
        case "evidence":
            return handleEvidenceDomain(action, json: json)
        case "evolution":
            return handleEvolutionDomain(action, json: json)
        case "health":
            return handleHealthDomain(action, json: json)
        case "coordinator":
            return handleCoordinatorDomain(action, json: json)
        default:
            return false
        }
    }

    public func routeFallbackByAction(_ action: String, domain: String, json: [String: Any]) -> Bool {
        switch action {
        case "clipboard_image_set":
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            onClipboardImageSet?(ok, message)
            return true
        case "error":
            let coreError = CoreError.from(json: json)
            emitCoreError(coreError)
            return true
        default:
            CoreWSLog.ws.warning(
                "Unhandled server envelope: domain=\(domain, privacy: .public), action=\(action, privacy: .public)"
            )
            if Self.fallbackActionCatalog.contains(action) {
                CoreWSLog.ws.error("Fallback action declared but not handled: \(action, privacy: .public)")
            }
            return false
        }
    }

    private func isActionDeclaredInReceiveCatalog(domain: String, action: String) -> Bool {
        if receiveProtocolExactRules.contains(where: { $0.domain == domain && $0.action == action }) {
            return true
        }
        if receiveProtocolPrefixRules.contains(where: { $0.domain == domain && action.hasPrefix($0.prefix) }) {
            return true
        }
        if receiveProtocolContainsRules.contains(where: { $0.domain == domain && action.contains($0.needle) }) {
            return true
        }
        if Self.receiveSupplementalExactRules.contains("\(domain):\(action)") {
            return true
        }
        return false
    }
}
