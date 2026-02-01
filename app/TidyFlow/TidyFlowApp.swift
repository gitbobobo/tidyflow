import SwiftUI

/// App delegate to handle lifecycle events
class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        print("[AppDelegate] App terminating, stopping Core process")
        appState?.stopCore()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        print("[AppDelegate] applicationShouldTerminate called")
        appState?.stopCore()
        // Give core a moment to terminate
        Thread.sleep(forTimeInterval: 0.5)
        return .terminateNow
    }
}

@main
struct TidyFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

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
                .onAppear {
                    // Give delegate access to appState for cleanup
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 900, height: 600)
    }
}
