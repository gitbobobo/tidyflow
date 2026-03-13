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

protocol NodeMessageHandler: AnyObject {
    func handleNodeSelfUpdated(_ identity: NodeSelfInfoV2)
    func handleNodeDiscoveryUpdated(_ items: [NodeDiscoveryItemV2])
    func handleNodeNetworkUpdated(_ snapshot: NodeNetworkSnapshotV2)
    func handleNodePairingResult(_ result: NodePairingResultV2)
    func handleNodePeerStatus(peerNodeID: String, status: String, lastSeenAtUnix: UInt64?)
}

extension NodeMessageHandler {
    func handleNodeSelfUpdated(_ identity: NodeSelfInfoV2) {}
    func handleNodeDiscoveryUpdated(_ items: [NodeDiscoveryItemV2]) {}
    func handleNodeNetworkUpdated(_ snapshot: NodeNetworkSnapshotV2) {}
    func handleNodePairingResult(_ result: NodePairingResultV2) {}
    func handleNodePeerStatus(peerNodeID: String, status: String, lastSeenAtUnix: UInt64?) {}
}
