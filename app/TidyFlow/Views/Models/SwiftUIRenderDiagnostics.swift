import SwiftUI
import Foundation
import os
import os.signpost

private let swiftUIRenderLog = OSLog(subsystem: "cn.tidyflow", category: "swiftui.render")

extension SwiftUIPerformanceDebug {
    static let renderInvalidationTrackingEnabled = extraFlag("TF_DEBUG_RENDER_INVALIDATIONS")
    static let aiChatRootPrintChangesEnabled = extraFlag("TF_DEBUG_PRINT_CHANGES_AI_CHAT_ROOT")
    static let mobileAIChatRootPrintChangesEnabled = extraFlag("TF_DEBUG_PRINT_CHANGES_MOBILE_AI_CHAT_ROOT")
    static let projectsSidebarPrintChangesEnabled = extraFlag("TF_DEBUG_PRINT_CHANGES_PROJECTS_SIDEBAR")
    static let projectListPrintChangesEnabled = extraFlag("TF_DEBUG_PRINT_CHANGES_PROJECT_LIST")
    static let evolutionPipelinePrintChangesEnabled = extraFlag("TF_DEBUG_PRINT_CHANGES_EVOLUTION_PIPELINE")
    static let tabContentHostPrintChangesEnabled = extraFlag("TF_DEBUG_PRINT_CHANGES_TAB_CONTENT_HOST")
    static let workspaceDetailPrintChangesEnabled = extraFlag("TF_DEBUG_PRINT_CHANGES_WORKSPACE_DETAIL")

    static func runPrintChangesIfEnabled(_ enabled: Bool, action: () -> Void) {
#if DEBUG
        guard enabled else { return }
        action()
#endif
    }

    private static func extraFlag(_ key: String) -> Bool {
        switch ProcessInfo.processInfo.environment[key]?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}

enum SwiftUIRenderDiagnostics {
    private static let lock = NSLock()
    private static var renderCounts: [String: Int] = [:]
    private static var trackingOverride: Bool?

    private static var isTrackingEnabled: Bool {
        trackingOverride ?? SwiftUIPerformanceDebug.renderInvalidationTrackingEnabled
    }

    @discardableResult
    static func recordRender(name: String, metadata: [String: String] = [:]) -> Int {
#if DEBUG
        guard isTrackingEnabled else { return 0 }
        let key = renderKey(name: name, metadata: metadata)
        let count: Int
        lock.lock()
        let next = (renderCounts[key] ?? 0) + 1
        renderCounts[key] = next
        count = next
        lock.unlock()

        let metadataString = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        os_signpost(
            .event,
            log: swiftUIRenderLog,
            name: "SwiftUIRender",
            "%{public}@ count=%{public}ld %{public}@",
            name as NSString,
            count,
            metadataString as NSString
        )
        return count
#else
        return 0
#endif
    }

    static func renderCount(name: String, metadata: [String: String] = [:]) -> Int {
        let key = renderKey(name: name, metadata: metadata)
        lock.lock()
        let count = renderCounts[key] ?? 0
        lock.unlock()
        return count
    }

    static func reset() {
        lock.lock()
        renderCounts.removeAll()
        lock.unlock()
    }

    static func setTrackingEnabledForTesting(_ enabled: Bool?) {
        trackingOverride = enabled
    }

    private static func renderKey(name: String, metadata: [String: String]) -> String {
        let suffix = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "|")
        guard !suffix.isEmpty else { return name }
        return "\(name)|\(suffix)"
    }
}

private struct SwiftUIRenderProbeModifier: ViewModifier {
    let name: String
    let metadata: [String: String]

    func body(content: Content) -> some View {
        let _ = SwiftUIRenderDiagnostics.recordRender(name: name, metadata: metadata)
        return content
    }
}

extension View {
    func tfRenderProbe(_ name: String, metadata: [String: String] = [:]) -> some View {
        modifier(SwiftUIRenderProbeModifier(name: name, metadata: metadata))
    }
}
