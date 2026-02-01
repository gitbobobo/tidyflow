import SwiftUI

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
