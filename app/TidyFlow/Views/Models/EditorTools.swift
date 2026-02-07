import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum RightTool: String, CaseIterable {
    case explorer
    case search
    case git
}

// MARK: - 外部编辑器（侧边栏与工具栏共用）
enum ExternalEditor: String, CaseIterable {
    case vscode = "VSCode"
    case cursor = "Cursor"
    case trae = "Trae"
    case idea = "IDEA"
    case androidStudio = "Android Studio"
    case xcode = "Xcode"
    case devecoStudio = "DevEco Studio"

    var bundleId: String {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .trae: return "com.trae.app"
        case .idea: return "com.jetbrains.intellij"
        case .androidStudio: return "com.google.android.studio"
        case .xcode: return "com.apple.dt.Xcode"
        case .devecoStudio: return "com.huawei.devecostudio.ds"
        }
    }

    var assetName: String {
        switch self {
        case .vscode: return "vscode-icon"
        case .cursor: return "cursor-icon"
        case .trae: return "trae-icon"
        case .idea: return "idea-icon"
        case .androidStudio: return "android-studio-icon"
        case .xcode: return "xcode-icon"
        case .devecoStudio: return "deveco-studio-icon"
        }
    }

    var fallbackIconName: String {
        switch self {
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .trae: return "sparkles"
        case .idea: return "lightbulb"
        case .androidStudio: return "apps.iphone"
        case .xcode: return "hammer"
        case .devecoStudio: return "star"
        }
    }

    #if canImport(AppKit)
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }
    #else
    var isInstalled: Bool { false }
    #endif
}
