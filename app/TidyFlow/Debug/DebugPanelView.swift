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
        let root = if Bundle.main.bundleURL.lastPathComponent == "TidyFlow-Debug.app" {
            ".tidyflow-dev"
        } else {
            ".tidyflow"
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("\(root)/logs", isDirectory: true)
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
        Bundle.main.bundleURL.lastPathComponent == "TidyFlow-Debug.app"
            ? "~/.tidyflow-dev/logs/"
            : "~/.tidyflow/logs/"
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

                        // Core Runtime 性能区块（全链路可观测 - WI-005）
                        perfCoreRuntimeSection

                        Divider()

                        // Workspace 关键路径区块（WI-005）
                        perfWorkspaceSection

                        Divider()

                        // Client Instance 区块（WI-005）
                        perfClientInstanceSection

                        Divider()

                        // 性能诊断结果区块（WI-005）
                        perfDiagnosisSection

                        Divider()

                        // 共享仪表盘投影（开发者视角）
                        PerformanceDashboardDebugSection(
                            store: appState.performanceDashboardStore
                        )

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
            .frame(width: 700, height: 700)
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

    // MARK: - Core Runtime 性能区块（WI-005）

    private var perfCoreRuntimeSection: some View {
        let perf = appState.performanceObservability
        return VStack(alignment: .leading, spacing: 8) {
            Text("Core Runtime")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("WS Pipeline p95:").foregroundColor(.secondary)
                    LatencyWindowLabel(window: perf.wsPipelineLatency)
                }
                GridRow {
                    Text("Core Resident:").foregroundColor(.secondary)
                    Text(formatBytes(perf.coreMemory.residentBytes))
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("Core Phys Footprint:").foregroundColor(.secondary)
                    Text(formatBytes(perf.coreMemory.physFootprintBytes))
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("Core Virtual:").foregroundColor(.secondary)
                    Text(formatBytes(perf.coreMemory.virtualBytes))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                GridRow {
                    Text("Snapshot At:").foregroundColor(.secondary)
                    Text(perf.snapshotAt == 0 ? "-" : "\(perf.snapshotAt)ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Workspace 关键路径区块（WI-005）

    private var perfWorkspaceSection: some View {
        let metrics = appState.performanceObservability.workspaceMetrics
        return VStack(alignment: .leading, spacing: 8) {
            Text("Workspace Metrics (\(metrics.count))")
                .font(.headline)

            if metrics.isEmpty {
                Text("暂无工作区数据")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ForEach(metrics) { ws in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(ws.project)/\(ws.workspace)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                            GridRow {
                                Text("  snapshot_build:").foregroundColor(.secondary)
                                LatencyWindowLabel(window: ws.systemSnapshotBuild)
                            }
                            GridRow {
                                Text("  file_index:").foregroundColor(.secondary)
                                LatencyWindowLabel(window: ws.workspaceFileIndexRefresh)
                            }
                            GridRow {
                                Text("  git_status:").foregroundColor(.secondary)
                                LatencyWindowLabel(window: ws.workspaceGitStatusRefresh)
                            }
                            GridRow {
                                Text("  evolution_read:").foregroundColor(.secondary)
                                LatencyWindowLabel(window: ws.evolutionSnapshotRead)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: - Client Instance 区块（WI-005）

    private var perfClientInstanceSection: some View {
        let clients = appState.performanceObservability.clientMetrics
        return VStack(alignment: .leading, spacing: 8) {
            Text("Client Instances (\(clients.count))")
                .font(.headline)

            if clients.isEmpty {
                Text("暂无客户端上报数据")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ForEach(clients, id: \.clientInstanceId) { client in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(client.platform)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15))
                                .cornerRadius(3)
                            Text(client.clientInstanceId.prefix(8) + "…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("\(client.project)/\(client.workspace)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                            GridRow {
                                Text("  phys_footprint:").foregroundColor(.secondary)
                                Text(formatBytes(client.memory.currentBytes))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            GridRow {
                                Text("  ws_switch p95:").foregroundColor(.secondary)
                                LatencyWindowLabel(window: client.workspaceSwitch)
                            }
                            GridRow {
                                Text("  file_tree p95:").foregroundColor(.secondary)
                                LatencyWindowLabel(window: client.fileTreeRequest)
                            }
                            GridRow {
                                Text("  ai_session_list p95:").foregroundColor(.secondary)
                                LatencyWindowLabel(window: client.aiSessionListRequest)
                            }
                            GridRow {
                                Text("  msg_tail_flush p95:").foregroundColor(.secondary)
                                LatencyWindowLabel(window: client.aiMessageTailFlush)
                            }
                            GridRow {
                                Text("  terminal_flush p95:").foregroundColor(.secondary)
                                LatencyWindowLabel(window: client.terminalOutputFlush)
                            }
                            GridRow {
                                Text("  git_projection p95:").foregroundColor(.secondary)
                                LatencyWindowLabel(window: client.gitPanelProjection)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: - 性能诊断结果区块（WI-005）

    private var perfDiagnosisSection: some View {
        let diagnoses = appState.performanceObservability.diagnoses
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Performance Diagnoses (\(diagnoses.count))")
                    .font(.headline)
                if diagnoses.contains(where: { $0.severity == .critical }) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                } else if diagnoses.contains(where: { $0.severity == .warning }) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }

            if diagnoses.isEmpty {
                Text("无性能诊断问题")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ForEach(diagnoses) { diag in
                    HStack(alignment: .top, spacing: 8) {
                        severityIcon(diag.severity)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(diag.reason.rawValue)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text("[\(diag.scope.rawValue)]")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Text(diag.summary)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            if !diag.recommendedAction.isEmpty {
                                Text("→ \(diag.recommendedAction)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 辅助方法（WI-005）

    private func formatBytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "-" }
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }

    private func severityIcon(_ severity: PerformanceDiagnosisSeverity) -> some View {
        let (icon, color): (String, Color) = {
            switch severity {
            case .critical: return ("exclamationmark.triangle.fill", .red)
            case .warning: return ("exclamationmark.triangle", .orange)
            case .info: return ("info.circle", .blue)
            }
        }()
        return Image(systemName: icon)
            .foregroundColor(color)
            .font(.system(size: 11))
            .frame(width: 14)
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

/// 延迟指标窗口简洁标签（WI-005 可复用辅助视图）
private struct LatencyWindowLabel: View {
    let window: LatencyMetricWindow

    var body: some View {
        if window.sampleCount == 0 {
            Text("-")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        } else {
            Text("p95=\(window.p95Ms)ms avg=\(window.avgMs)ms max=\(window.maxMs)ms n=\(window.sampleCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(latencyColor)
        }
    }

    private var latencyColor: Color {
        if window.p95Ms > 500 { return .red }
        if window.p95Ms > 200 { return .orange }
        return .primary
    }
}

private struct PerformanceDashboardDebugSection: View {
    @ObservedObject var store: PerformanceDashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("性能仪表盘投影")
                .font(.headline)
            ForEach(Array(store.projections.values), id: \.surface) { proj in
                HStack {
                    Text("\(proj.surface.displayName) [\(proj.project)/\(proj.workspace)]")
                        .font(.caption)
                    Spacer()
                    Text(proj.budgetStatus.label)
                        .font(.caption)
                        .foregroundStyle(Color(proj.budgetStatus.colorSemanticName))
                }
            }
            if store.projections.isEmpty {
                Text("暂无仪表盘数据").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
