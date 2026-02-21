import Foundation

// MARK: - WSClient 分领域路由

extension WSClient {
    func routeByDomain(domain: String, action: String, json: [String: Any]) -> Bool {
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
        case "lsp":
            return handleLspDomain(action, json: json)
        case "ai":
            return handleAiDomain(action, json: json)
        case "evolution":
            return handleEvolutionDomain(action, json: json)
        default:
            return false
        }
    }

    func routeFallbackByAction(_ action: String, json: [String: Any]) -> Bool {
        if handleSystemDomain(action, json: json) { return true }
        if handleTerminalDomain(action, json: json) { return true }
        if handleGitDomain(action, json: json) { return true }
        if handleProjectDomain(action, json: json) { return true }
        if handleFileDomain(action, json: json) { return true }
        if handleSettingsDomain(action, json: json) { return true }
        if handleLspDomain(action, json: json) { return true }
        if handleAiDomain(action, json: json) { return true }
        if handleEvolutionDomain(action, json: json) { return true }

        switch action {
        case "clipboard_image_set":
            let ok = json["ok"] as? Bool ?? false
            let message = json["message"] as? String
            onClipboardImageSet?(ok, message)
            return true
        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown error"
            onError?(errorMsg)
            return true
        default:
            return false
        }
    }
}
