import SwiftUI

/// Shows Core process status (Starting/Running/Restarting/Failed) with port info
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
        case .restarting: return .yellow
        case .failed: return .red
        }
    }

    private var statusIcon: String {
        switch coreManager.status {
        case .stopped: return "stop.circle"
        case .starting: return "hourglass"
        case .running: return "checkmark.circle"
        case .restarting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var helpText: String {
        switch coreManager.status {
        case .running(let port, let pid):
            return "Core running on port \(port) (PID: \(pid))\nCmd+R to restart"
        case .starting(let attempt, let port):
            return "Starting on port \(port) (attempt \(attempt)/\(AppConfig.maxPortRetries))"
        case .restarting(let attempt, let max, let lastError):
            var text = "Auto-restarting (attempt \(attempt)/\(max))"
            if let err = lastError {
                text += "\nLast error: \(err)"
            }
            return text
        case .failed(let msg):
            return "Failed: \(msg)\nCmd+R to retry\n\n\(CoreProcessManager.manualRunInstructions)"
        case .stopped:
            return "Core stopped\nCmd+R to start"
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
        .help(helpText)
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
                appState.restartCore()
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Restart Core (Cmd+R)")
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
