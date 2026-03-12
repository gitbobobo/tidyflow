import Foundation
import TidyFlowShared

// MARK: - Evolution 面板性能监控回路（WI-002）

/// AppState 扩展：管理 Evolution 面板活动期的 system_snapshot 刷新与 client_performance_report 上报回路。
///
/// 设计原则：
/// - 每个 workspaceContextKey 最多只有一个活跃监控任务。
/// - 监控任务按动态档位间隔请求 system_snapshot（forceRefresh）并发送 health_report。
/// - 该回路与 SharedSecondTicker 完全分离，避免秒级 UI 刷新与网络采样耦合。
extension AppState {

    // MARK: - 公共接口

    /// 启动（或复用）Evolution 面板性能监控。
    ///
    /// - Parameters:
    ///   - project: 当前选中项目名
    ///   - workspace: 当前选中工作区名
    ///   - cycleID: 当前循环 ID（可选，用于 health_report context）
    ///   - contextKey: 工作区上下文 key（与 projection.workspaceContextKey 对齐，用于任务隔离）
    @MainActor
    func startEvolutionPerformanceMonitoring(
        project: String,
        workspace: String,
        cycleID: String? = nil,
        contextKey: String
    ) {
        guard !contextKey.isEmpty, !project.isEmpty, !workspace.isEmpty else { return }
        // 已有同 key 任务，不重复创建
        if evolutionPerformanceMonitorTasks[contextKey] != nil { return }

        TFLog.perf.info(
            "perf evolution_monitor start key=\(contextKey, privacy: .public) project=\(project, privacy: .public) workspace=\(workspace, privacy: .public) cycle=\(cycleID ?? "none", privacy: .public)"
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runEvolutionPerformanceMonitorLoop(
                project: project,
                workspace: workspace,
                cycleID: cycleID,
                contextKey: contextKey
            )
        }
        evolutionPerformanceMonitorTasks[contextKey] = task
    }

    /// 停止指定 workspaceContextKey 的 Evolution 面板性能监控。
    @MainActor
    func stopEvolutionPerformanceMonitoring(contextKey: String) {
        guard let task = evolutionPerformanceMonitorTasks.removeValue(forKey: contextKey) else { return }
        task.cancel()
        evolutionPerformanceSamplingDecisions.removeValue(forKey: contextKey)
        TFLog.perf.info(
            "perf evolution_monitor stop key=\(contextKey, privacy: .public)"
        )
    }

    /// 停止所有活跃的 Evolution 面板性能监控任务。
    @MainActor
    func stopAllEvolutionPerformanceMonitoring() {
        for (key, task) in evolutionPerformanceMonitorTasks {
            task.cancel()
            TFLog.perf.info("perf evolution_monitor stop_all key=\(key, privacy: .public)")
        }
        evolutionPerformanceMonitorTasks.removeAll()
        evolutionPerformanceSamplingDecisions.removeAll()
    }

    // MARK: - 内部监控循环

    @MainActor
    private func runEvolutionPerformanceMonitorLoop(
        project: String,
        workspace: String,
        cycleID: String?,
        contextKey: String
    ) async {
        var currentDecision = evolutionPerformanceSamplingDecisions[contextKey] ?? .paused

        while !Task.isCancelled {
            // 计算最新采样决策
            let metrics = EvolutionRealtimeSamplingSemantics.filterMetrics(
                snapshot: performanceObservability,
                project: project,
                workspace: workspace,
                clientInstanceId: perfReporter.clientInstanceId
            )
            let runningAgentCount = evolutionItem(project: project, workspace: workspace)?.agents
                .filter { $0.status.lowercased() == "running" }.count ?? 0
            let wsConnected = connectionState == .connected

            let newDecision = EvolutionRealtimeSamplingSemantics.computeDecision(
                metrics: metrics,
                runningAgentCount: runningAgentCount,
                sceneActive: isSceneActive,
                panelVisible: true, // 面板 visible 由调用方保证（onDisappear 时已 stop）
                wsConnected: wsConnected,
                currentDecision: currentDecision
            )

            // 档位变化时记录日志
            if newDecision.tier != currentDecision.tier {
                TFLog.perf.info(
                    "perf evolution_monitor tier_change key=\(contextKey, privacy: .public) old=\(currentDecision.tier.rawValue, privacy: .public) new=\(newDecision.tier.rawValue, privacy: .public) reason=\(newDecision.reason, privacy: .public)"
                )
            }
            currentDecision = newDecision
            evolutionPerformanceSamplingDecisions[contextKey] = newDecision

            // paused 档位：等待短暂后再检查（不发网络请求）
            guard let intervalMs = newDecision.tier.intervalMs, intervalMs > 0 else {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s 后重新检测
                continue
            }

            // 请求最新 system_snapshot
            TFLog.perf.info(
                "perf evolution_monitor snapshot_request key=\(contextKey, privacy: .public) tier=\(newDecision.tier.rawValue, privacy: .public)"
            )
            wsClient.requestSystemSnapshot(cacheMode: .forceRefresh)

            // 发送 health_report（附带 client_performance_report）
            let perfReport = perfReporter.buildReport(project: project, workspace: workspace)
            let context = HealthContext(
                project: project,
                workspace: workspace,
                cycleId: cycleID
            )
            wsClient.reportHealthStatus(
                clientSessionId: perfReporter.clientInstanceId,
                connectivity: wsConnected ? .good : .lost,
                incidents: [],
                context: context,
                clientPerformanceReport: perfReport
            )
            TFLog.perf.info(
                "perf evolution_monitor health_report_sent key=\(contextKey, privacy: .public) tier=\(newDecision.tier.rawValue, privacy: .public)"
            )

            // 等待采样间隔
            let waitNs = UInt64(intervalMs) * 1_000_000
            try? await Task.sleep(nanoseconds: waitNs)
        }
    }
}
