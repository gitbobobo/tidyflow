#if os(macOS)
import SwiftUI

/// 系统健康与性能诊断快速概览弹窗（WI-005）
///
/// 展示来自 Core `performance_observability` 的四个语义区块：
/// Core 运行时内存与 WS 延迟、工作区关键路径摘要、客户端实例摘要、诊断结果。
/// 视图层只消费 AppState.performanceObservability，不自行计算阈值或诊断结论。
struct SystemHealthPopoverView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow

                Divider()

                // 区块一：Core 运行时
                SHPSectionHeader(title: "Core Runtime", systemImage: "cpu")
                coreRuntimeBlock

                Divider()

                // 区块二：工作区关键路径
                SHPSectionHeader(title: "Workspace Metrics", systemImage: "rectangle.3.group")
                workspaceBlock

                Divider()

                // 区块三：客户端实例
                SHPSectionHeader(title: "Client Instances", systemImage: "desktopcomputer")
                clientInstanceBlock

                Divider()

                // 区块四：诊断结果
                SHPSectionHeader(title: "Diagnoses", systemImage: "stethoscope")
                diagnosisBlock
            }
            .padding(16)
        }
        .frame(width: 420, height: 540)
    }

    // MARK: - 标题行

    private var headerRow: some View {
        HStack {
            Image(systemName: overallStatusIcon)
                .foregroundColor(overallStatusColor)
            Text("Performance Overview")
                .font(.headline)
            Spacer()
            let perf = appState.performanceObservability
            if perf.snapshotAt > 0 {
                Text("@\(perf.snapshotAt)ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var overallStatusIcon: String {
        let diags = appState.performanceObservability.diagnoses
        if diags.contains(where: { $0.severity == .critical }) { return "exclamationmark.triangle.fill" }
        if diags.contains(where: { $0.severity == .warning }) { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private var overallStatusColor: Color {
        let diags = appState.performanceObservability.diagnoses
        if diags.contains(where: { $0.severity == .critical }) { return .red }
        if diags.contains(where: { $0.severity == .warning }) { return .orange }
        return .green
    }

    // MARK: - 区块一：Core 运行时

    private var coreRuntimeBlock: some View {
        let perf = appState.performanceObservability
        return VStack(alignment: .leading, spacing: 6) {
            SHPMetricRow(label: "WS Pipeline p95",
                         value: latencyText(perf.wsPipelineLatency),
                         valueColor: latencyColor(perf.wsPipelineLatency.p95Ms))
            SHPMetricRow(label: "Phys Footprint",
                         value: formatBytes(perf.coreMemory.physFootprintBytes),
                         valueColor: memoryColor(perf.coreMemory.physFootprintBytes,
                                                 warnThreshold: 512 * 1024 * 1024,
                                                 critThreshold: 768 * 1024 * 1024))
            SHPMetricRow(label: "Resident",
                         value: formatBytes(perf.coreMemory.residentBytes))
        }
    }

    // MARK: - 区块二：工作区关键路径

    private var workspaceBlock: some View {
        let metrics = appState.performanceObservability.workspaceMetrics
        return Group {
            if metrics.isEmpty {
                Text("暂无数据").font(.caption).foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(metrics) { ws in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(ws.project)/\(ws.workspace)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                            VStack(alignment: .leading, spacing: 3) {
                                SHPMetricRow(label: "  file_index p95",
                                             value: latencyText(ws.workspaceFileIndexRefresh),
                                             valueColor: latencyColor(ws.workspaceFileIndexRefresh.p95Ms))
                                SHPMetricRow(label: "  git_status p95",
                                             value: latencyText(ws.workspaceGitStatusRefresh),
                                             valueColor: latencyColor(ws.workspaceGitStatusRefresh.p95Ms))
                                SHPMetricRow(label: "  evolution_read p95",
                                             value: latencyText(ws.evolutionSnapshotRead),
                                             valueColor: latencyColor(ws.evolutionSnapshotRead.p95Ms))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 区块三：客户端实例

    private var clientInstanceBlock: some View {
        let clients = appState.performanceObservability.clientMetrics
        return Group {
            if clients.isEmpty {
                Text("暂无上报").font(.caption).foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(clients, id: \.clientInstanceId) { client in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(client.platform)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.15))
                                    .cornerRadius(3)
                                Text(String(client.clientInstanceId.prefix(8)) + "…")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                SHPMetricRow(label: "  phys_footprint",
                                             value: formatBytes(client.memory.currentBytes),
                                             valueColor: memoryColor(client.memory.currentBytes,
                                                                     warnThreshold: client.platform == "ios" ? 250 * 1024 * 1024 : 400 * 1024 * 1024,
                                                                     critThreshold: client.platform == "ios" ? 400 * 1024 * 1024 : 700 * 1024 * 1024))
                                SHPMetricRow(label: "  ws_switch p95",
                                             value: latencyText(client.workspaceSwitch),
                                             valueColor: latencyColor(client.workspaceSwitch.p95Ms))
                                SHPMetricRow(label: "  file_tree p95",
                                             value: latencyText(client.fileTreeRequest),
                                             valueColor: latencyColor(client.fileTreeRequest.p95Ms))
                                SHPMetricRow(label: "  ai_sessions p95",
                                             value: latencyText(client.aiSessionListRequest),
                                             valueColor: latencyColor(client.aiSessionListRequest.p95Ms))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 区块四：诊断结果

    private var diagnosisBlock: some View {
        let diagnoses = appState.performanceObservability.diagnoses
        return Group {
            if diagnoses.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("无性能诊断问题").font(.caption).foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(diagnoses) { diag in
                        HStack(alignment: .top, spacing: 8) {
                            diagSeverityIcon(diag.severity)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(diag.reason.rawValue)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    Text("[\(diag.scope.rawValue)]")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Text(diag.summary)
                                    .font(.caption)
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
    }

    // MARK: - 辅助

    private func latencyText(_ w: LatencyMetricWindow) -> String {
        w.sampleCount == 0 ? "-" : "\(w.p95Ms)ms"
    }

    private func latencyColor(_ p95: UInt64) -> Color {
        if p95 > 500 { return .red }
        if p95 > 200 { return .orange }
        return .primary
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "-" }
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.1f MB", mb)
    }

    private func memoryColor(_ bytes: UInt64, warnThreshold: UInt64, critThreshold: UInt64) -> Color {
        if bytes >= critThreshold { return .red }
        if bytes >= warnThreshold { return .orange }
        return .primary
    }

    private func diagSeverityIcon(_ severity: PerformanceDiagnosisSeverity) -> some View {
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
}

// MARK: - 辅助子视图

/// 区块标题行
private struct SHPSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.primary)
    }
}

/// 单行指标展示
private struct SHPMetricRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(minWidth: 160, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(valueColor)
        }
    }
}

#Preview {
    SystemHealthPopoverView()
        .environmentObject(AppState())
}
#endif
