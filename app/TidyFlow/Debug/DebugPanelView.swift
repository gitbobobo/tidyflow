#if os(macOS)
import SwiftUI

/// Hidden Debug Panel for developers
/// Access via Cmd+Shift+D
struct DebugPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var logTailText: String = ""
    @State private var isLoadingLog: Bool = false
    @State private var lastRefreshTime: Date?

    /// 日志目录：~/.tidyflow/logs/
    private static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tidyflow/logs", isDirectory: true)
    }

    /// 当天日志文件
    private static var todayLogFileURL: URL {
        let dateStr = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let devLogURL = logDirectory.appendingPathComponent("\(dateStr)-dev.log")
        if FileManager.default.fileExists(atPath: devLogURL.path) {
            return devLogURL
        }
        return logDirectory.appendingPathComponent("\(dateStr).log")
    }

    /// 显示用路径
    private static var logPathDisplay: String {
        "~/.tidyflow/logs/"
    }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.debugPanelPresented = false
                }

            // Panel
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Debug Panel")
                        .font(.headline)
                    Spacer()
                    Button(action: { appState.debugPanelPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Core Status Section
                        DebugCoreStatusSection(coreProcessManager: appState.coreProcessManager)

                        Divider()

                        // WebSocket Status Section
                        wsStatusSection

                        Divider()

                        // Performance Metrics Section (v1.42 可观测性收敛)
                        perfMetricsSection

                        Divider()

                        // Log Context Section (v1.42 日志关联)
                        logContextSection

                        Divider()

                        // Log Viewer Section
                        logViewerSection
                    }
                    .padding()
                }
            }
            .frame(width: 700, height: 550)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(12)
            .shadow(radius: 20)
        }
        .onAppear {
            loadLogTail()
        }
    }

    // MARK: - WebSocket Status Section

    private var wsStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WebSocket")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("State:").foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.wsClient.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(appState.wsClient.isConnected ? "Connected" : "Disconnected")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                GridRow {
                    Text("URL:").foregroundColor(.secondary)
                    Text(appState.wsClient.currentURLString ?? "-")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Performance Metrics Section (v1.42)

    private var perfMetricsSection: some View {
        let perf = appState.observabilitySnapshot.perfMetrics
        return VStack(alignment: .leading, spacing: 8) {
            Text("Performance Metrics")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("WS Decode:").foregroundColor(.secondary)
                    Text("last=\(perf.wsDecode.lastMs)ms max=\(perf.wsDecode.maxMs)ms n=\(perf.wsDecode.count)")
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("WS Dispatch:").foregroundColor(.secondary)
                    Text("last=\(perf.wsDispatch.lastMs)ms max=\(perf.wsDispatch.maxMs)ms n=\(perf.wsDispatch.count)")
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("WS Encode:").foregroundColor(.secondary)
                    Text("last=\(perf.wsEncode.lastMs)ms max=\(perf.wsEncode.maxMs)ms n=\(perf.wsEncode.count)")
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("Broadcast Lag:").foregroundColor(.secondary)
                    Text("\(perf.wsTaskBroadcastLagTotal) (queue: \(perf.wsTaskBroadcastQueueDepth))")
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("Terminal:").foregroundColor(.secondary)
                    Text("reclaimed=\(perf.terminalReclaimedTotal) trimmed=\(perf.terminalScrollbackTrimTotal)")
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("AI Fanout:").foregroundColor(.secondary)
                    Text("current=\(perf.aiSubscriberFanout) max=\(perf.aiSubscriberFanoutMax)")
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("Evolution:").foregroundColor(.secondary)
                    Text("emitted=\(perf.evolutionCycleUpdateEmittedTotal) debounced=\(perf.evolutionCycleUpdateDebouncedTotal)")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    // MARK: - Log Context Section (v1.42)

    private var logContextSection: some View {
        let ctx = appState.observabilitySnapshot.logContext
        return VStack(alignment: .leading, spacing: 8) {
            Text("Log Context")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Log File:").foregroundColor(.secondary)
                    Text(ctx.logFile.isEmpty ? "-" : ctx.logFile)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                GridRow {
                    Text("Retention:").foregroundColor(.secondary)
                    Text("\(ctx.retentionDays) days")
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("Perf Log:").foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ctx.perfLoggingEnabled ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(ctx.perfLoggingEnabled ? "Enabled" : "Disabled")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }

    // MARK: - Log Viewer Section

    private var logViewerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log Viewer")
                    .font(.headline)
                Text("(\(Self.logPathDisplay))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if let time = lastRefreshTime {
                    Text("Updated: \(time, formatter: timeFormatter)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Log content
            ScrollView {
                Text(logTailText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 250)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .overlay(
                Group {
                    if isLoadingLog {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            )

            // Action buttons
            HStack(spacing: 12) {
                Button(action: loadLogTail) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingLog)

                Spacer()

                Text("\(logTailText.components(separatedBy: .newlines).count) lines")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func loadLogTail() {
        isLoadingLog = true

        DispatchQueue.global(qos: .userInitiated).async {
            let text = LogTailReader.readTail(
                url: Self.todayLogFileURL,
                maxBytes: 128 * 1024,
                maxLines: 300
            )

            DispatchQueue.main.async {
                self.logTailText = text
                self.isLoadingLog = false
                self.lastRefreshTime = Date()
            }
        }
    }
    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f
    }
}

private struct DebugCoreStatusSection: View {
    @ObservedObject var coreProcessManager: CoreProcessManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Core Process")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Status:").foregroundColor(.secondary)
                    statusBadge
                }
                GridRow {
                    Text("Port:").foregroundColor(.secondary)
                    Text(portText).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("PID:").foregroundColor(.secondary)
                    Text(pidText).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Auto-Restart:").foregroundColor(.secondary)
                    Text("\(coreProcessManager.restartAttempts)/\(AppConfig.autoRestartLimit)")
                        .font(.system(.body, design: .monospaced))
                }
                if let reason = coreProcessManager.lastExitInfo {
                    GridRow {
                        Text("Last Exit:").foregroundColor(.secondary)
                        Text(reason)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    private var statusBadge: some View {
        let (text, color) = statusInfo
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var statusInfo: (String, Color) {
        switch coreProcessManager.status {
        case .stopped:
            return ("Stopped", .gray)
        case .starting(let attempt, let port):
            let portText = port.map(String.init) ?? "?"
            return ("Starting (try \(attempt), port \(portText))", .yellow)
        case .running(let port, let pid):
            return ("Running (:\(port), pid \(pid))", .green)
        case .restarting(let attempt, let max, _):
            return ("Restarting (\(attempt)/\(max))", .orange)
        case .failed(let msg):
            return ("Failed: \(msg)", .red)
        }
    }

    private var portText: String {
        guard let port = coreProcessManager.currentPort else { return "-" }
        return String(port)
    }

    private var pidText: String {
        if case .running(_, let pid) = coreProcessManager.status {
            return String(pid)
        }
        return "-"
    }
}
#endif
