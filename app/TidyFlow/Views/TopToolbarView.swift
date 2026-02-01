import SwiftUI

/// Shows Core process status (Starting/Running/Failed)
struct CoreStatusView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var coreManager: CoreProcessManager

    init(coreManager: CoreProcessManager) {
        self.coreManager = coreManager
    }

    private var statusColor: Color {
        switch coreManager.status {
        case .stopped: return .gray
        case .starting: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }

    private var statusIcon: String {
        switch coreManager.status {
        case .stopped: return "stop.circle"
        case .starting: return "hourglass"
        case .running: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.caption)

            Text("Core: \(coreManager.status.displayText)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .help(coreManager.status.isRunning ? "Core is running" : CoreProcessManager.manualRunInstructions)
    }
}

struct ConnectionStatusView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack {
            Circle()
                .fill(appState.connectionState == .connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            
            Text(appState.connectionState == .connected ? "Connected" : "Disconnected")
                .font(.caption)
            
            Button(action: {
                // Mock reconnect
                if appState.connectionState == .connected {
                    appState.connectionState = .disconnected
                } else {
                    appState.connectionState = .connected
                }
                print("[Toolbar] Reconnect clicked. New state: \(appState.connectionState)")
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reconnect")
        }
    }
}

struct ProjectPickerView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Picker("Project", selection: $appState.selectedWorkspaceKey) {
            Text("Select Project...").tag(String?.none)
            Divider()
            ForEach(appState.workspaces.sorted(by: { $0.key < $1.key }), id: \.key) { key, name in
                Text(name).tag(String?.some(key))
            }
        }
        .frame(width: 200)
    }
}
