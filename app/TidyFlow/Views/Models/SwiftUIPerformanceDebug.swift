import Foundation

enum SwiftUIPerformanceDebug {
    static let aiMessageListPrintChangesEnabled = flag("TF_DEBUG_PRINT_CHANGES_AI_MESSAGE_LIST")
    static let evidenceTextListPrintChangesEnabled = flag("TF_DEBUG_PRINT_CHANGES_EVIDENCE_TEXT")
    static let mobileEvidenceContainerPrintChangesEnabled = flag("TF_DEBUG_PRINT_CHANGES_MOBILE_EVIDENCE")
    static let hotspotBaselineEnabled = flag("TF_DEBUG_SWIFTUI_HOTSPOT_BASELINE")

    private static func flag(_ key: String) -> Bool {
        switch ProcessInfo.processInfo.environment[key]?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
