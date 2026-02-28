import SwiftUI
import UserNotifications

/// App delegate to handle lifecycle events
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var appState: AppState?
    /// 用于跟踪是否已确认退出（避免重复弹框）
    private var terminationConfirmed = false
    /// 启动期窗口可见性兜底重试计数（处理 UI Test 下窗口创建时序）
    private var ensureMainWindowRetryCount = 0
    private let maxEnsureMainWindowRetryCount = 40

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置主窗口 delegate（窗口显示由 SwiftUI 默认行为管理）。
        if let window = NSApplication.shared.windows.first {
            prepareMainWindow(window)
        }
        // 启动即确保主窗口可见，避免 UI Test 下窗口未及时创建导致不可见。
        DispatchQueue.main.async { [weak self] in
            self?.ensureMainWindowVisible(reason: "did_finish_launching")
        }

        // 请求系统通知权限（横幅 + 声音）
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                TFLog.app.error("请求通知权限失败: \(error.localizedDescription)")
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 用户回到应用时，清除通知中心中的已投递通知（临时通知）
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// 配置主窗口 delegate
    func prepareMainWindow(_ window: NSWindow) {
        window.delegate = self
    }

    /// 启动期确保主窗口可见并前置（幂等）
    func ensureMainWindowVisible(reason: String) {
        NSRunningApplication.current.activate(options: [])
        NSApp.activate(ignoringOtherApps: true)

        guard let window = preferredMainWindow() else {
            guard ensureMainWindowRetryCount < maxEnsureMainWindowRetryCount else {
                TFLog.app.warning("Main window not available after retries (\(reason, privacy: .public))")
                return
            }
            ensureMainWindowRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.ensureMainWindowVisible(reason: reason)
            }
            return
        }

        ensureMainWindowRetryCount = 0
        prepareMainWindow(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func preferredMainWindow() -> NSWindow? {
        let windows = NSApplication.shared.windows
        return windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) ?? windows.first
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 应用在前台时不显示系统通知，交由应用内 Toast 处理
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    func applicationWillTerminate(_ notification: Notification) {
        TFLog.app.info("App terminating, stopping Core process")
        appState?.stopCore()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 如果已确认退出，直接退出
        if terminationConfirmed {
            appState?.stopCore()
            // 异步等待 Core 进程退出，不阻塞主线程
            DispatchQueue.global(qos: .userInitiated).async {
                Thread.sleep(forTimeInterval: 0.5)
                DispatchQueue.main.async {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
        
        // 检查是否有活跃的终端会话
        let activeTerminalCount = appState?.terminalSessionByTabId.count ?? 0
        
        if activeTerminalCount > 0 {
            // 有活跃终端，显示确认弹框
            if showTerminationConfirmation(terminalCount: activeTerminalCount) {
                // 用户确认退出
                terminationConfirmed = true
                appState?.stopCore()
                DispatchQueue.global(qos: .userInitiated).async {
                    Thread.sleep(forTimeInterval: 0.5)
                    DispatchQueue.main.async {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
                return .terminateLater
            } else {
                // 用户取消
                return .terminateCancel
            }
        }
        
        // 没有活跃终端，直接退出
        appState?.stopCore()
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
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
    @State private var startupWindowConfigured: Bool = false

    init() {
        // Register for termination notification as backup
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // willTerminateNotification received
        }
    }

    var body: some Scene {
        WindowGroup {
            startupRootView
                .environmentObject(appState)
                .environmentObject(appState.aiChatStore)
                .environmentObject(appState.gitCache)
                .environmentObject(appState.fileCache)
                .environmentObject(appState.paletteState)
                .environmentObject(appState.taskManager)
                .environmentObject(appState.editorStore)
                .environmentObject(appState.terminalStore)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .onAppear {
                    // Give delegate access to appState for cleanup
                    appDelegate.appState = appState
                    // SwiftUI 可能延迟创建窗口，这里兜底设置 delegate。
                    DispatchQueue.main.async {
                        guard !startupWindowConfigured else { return }
                        startupWindowConfigured = true
                        if let window = NSApplication.shared.windows.first {
                            appDelegate.prepareMainWindow(window)
                        }
                        appDelegate.ensureMainWindowVisible(reason: "root_on_appear")
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
            HelpCommands()
        }
        
        // FAQ 窗口
        Window("help.faq.windowTitle".localized, id: "faq") {
            FAQView()
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 520, height: 400)
        .windowResizability(.contentSize)

        // 设置窗口（独立窗口，通过 ⌘, 或点击设置按钮打开）
        Settings {
            SettingsContentView()
                .environmentObject(appState)
                .environmentObject(appState.aiChatStore)
                .environmentObject(appState.gitCache)
                .environmentObject(appState.fileCache)
                .environmentObject(appState.paletteState)
                .environmentObject(appState.taskManager)
                .environmentObject(appState.editorStore)
                .environmentObject(appState.terminalStore)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .frame(minWidth: 500, minHeight: 400)
                .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var startupRootView: some View {
        switch appState.startupPhase {
        case .loading:
            StartupLoadingView()
        case .ready:
            ContentView()
        case .failed(let message):
            StartupFailedView(message: message) {
                appState.retryStartup()
            }
        }
    }
}

private struct StartupLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("common.loading".localized)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("tf.mac.startup.loading")
    }
}

private struct StartupFailedView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)

            Text("startup.failed.title".localized)
                .font(.title3)
                .fontWeight(.semibold)

            Text(String(format: "startup.failed.message".localized, message))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Button("startup.failed.retry".localized, action: onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tf.mac.startup.retry")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("tf.mac.startup.failed")
    }
}
