import Foundation
import MessagePacker
import TidyFlowShared

// MARK: - Settings 消息处理协议（依赖 ClientSettings，保留在 TidyFlow）

protocol SettingsMessageHandler: AnyObject {
    func handleClientSettingsResult(_ settings: ClientSettings)
    func handleClientSettingsSaved(_ ok: Bool, _ message: String?)
}

extension SettingsMessageHandler {
    func handleClientSettingsResult(_ settings: ClientSettings) {}
    func handleClientSettingsSaved(_ ok: Bool, _ message: String?) {}
}
