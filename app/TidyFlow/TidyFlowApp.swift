import SwiftUI

/// App delegate to handle lifecycle events
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var appState: AppState?
    /// 用于跟踪是否已确认退出（避免重复弹框）
    private var terminationConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置主窗口的 delegate 以拦截关闭事件
        if let window = NSApplication.shared.windows.first {
            window.delegate = self
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[AppDelegate] App terminating, stopping Core process")
        appState?.stopCore()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        print("[AppDelegate] applicationShouldTerminate called")
        
        // 如果已确认退出，直接退出
        if terminationConfirmed {
            appState?.stopCore()
            Thread.sleep(forTimeInterval: 0.5)
            return .terminateNow
        }
        
        // 检查是否有活跃的终端会话
        let activeTerminalCount = appState?.terminalSessionByTabId.count ?? 0
        
        if activeTerminalCount > 0 {
            // 有活跃终端，显示确认弹框
            if showTerminationConfirmation(terminalCount: activeTerminalCount) {
                // 用户确认退出
                terminationConfirmed = true
                appState?.stopCore()
                Thread.sleep(forTimeInterval: 0.5)
                return .terminateNow
            } else {
                // 用户取消
                return .terminateCancel
            }
        }
        
        // 没有活跃终端，直接退出
        appState?.stopCore()
        Thread.sleep(forTimeInterval: 0.5)
        return .terminateNow
    }

    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        print("[AppDelegate] windowShouldClose called")
        
        // 检查是否有活跃的终端会话
        let activeTerminalCount = appState?.terminalSessionByTabId.count ?? 0
        
        if activeTerminalCount > 0 {
            // 有活跃终端，显示确认弹框
            if showTerminationConfirmation(terminalCount: activeTerminalCount) {
                // 用户确认，标记并退出应用
                terminationConfirmed = true
                NSApp.terminate(nil)
                return false  // 不直接关闭窗口，让 terminate 处理
            } else {
                // 用户取消
                return false
            }
        }
        
        // 没有活跃终端，直接退出应用
        NSApp.terminate(nil)
        return false  // 不直接关闭窗口，让 terminate 处理
    }

    // MARK: - Helper
    
    /// 显示退出确认弹框，返回用户是否确认退出
    private func showTerminationConfirmation(terminalCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "app.quit.title".localized
        alert.informativeText = String(format: "app.quit.message".localized, terminalCount)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "app.quit.quit".localized)
        alert.addButton(withTitle: "common.cancel".localized)
        
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
}

@main
struct TidyFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var localizationManager = LocalizationManager.shared

    init() {
        // Register for termination notification as backup
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("[TidyFlowApp] willTerminateNotification received")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.gitCache)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .onAppear {
                    // Give delegate access to appState for cleanup
                    appDelegate.appState = appState
                    // 确保窗口 delegate 已设置（SwiftUI 可能延迟创建窗口）
                    DispatchQueue.main.async {
                        if let window = NSApplication.shared.windows.first {
                            window.delegate = appDelegate
                        }
                    }
                }
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 900, height: 600)
        // 添加 InspectorCommands 支持标准快捷键 ⌘⌃I 切换检查器
        .commands {
            InspectorCommands()
        }
        
        // 设置窗口（独立窗口，通过 ⌘, 或点击设置按钮打开）
        Settings {
            SettingsContentView()
                .environmentObject(appState)
                .environmentObject(appState.gitCache)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .frame(minWidth: 500, minHeight: 400)
                .preferredColorScheme(.dark)
        }
    }
}
