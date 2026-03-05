import SwiftUI

#if os(macOS)

// MARK: - 进化流水线视图（右侧面板）

/// 自主进化的流水线视图，显示在右侧 Inspector 面板中
/// 聚焦当前轮次执行流程，以流水线动画展示代理执行状态
struct EvolutionPipelineView: View {
    @EnvironmentObject var appState: AppState

    // MARK: - 本地状态

    @State private var loopRoundLimit: Int = 1
    @State private var lastLoopRoundWorkspaceContext: String = ""
    @State private var isBlockerSheetPresented: Bool = false
    @State private var isHandoffSheetPresented: Bool = false
    @State private var isReportSheetPresented: Bool = false
    @State private var selectedReportCycleID: String?
    @State private var selectedCycleDetail: PipelineCycleDetailPayload?
    @State private var blockerDrafts: [String: EvolutionPipelineBlockerDraft] = [:]

    /// 已完成会话的时间线记录（本轮）
    @State private var completedTimeline: [PipelineTimelineEntry] = []
    /// 历史循环汇总（每轮结束后的合并记录）
    @State private var cycleHistories: [PipelineCycleHistory] = []
    /// 上次记录的轮次
    @State private var lastRecordedRound: Int = 0
    /// 当前循环的开始时间
    @State private var cycleStartDate: Date = Date()

    private let untitledCycleTitle = "Untitled"

    private struct EvolutionPipelineBlockerDraft {
        var selected: Bool
        var selectedOptionID: String
        var answerText: String
    }

    // MARK: - 便捷属性

    private var project: String { appState.selectedProjectName }
    private var workspace: String? { appState.selectedWorkspaceKey }
    private var workspaceReady: Bool { workspace != nil && !(workspace ?? "").isEmpty }
    private var workspaceContextKey: String {
        let normalizedWorkspace = appState.normalizeEvolutionWorkspaceName(workspace ?? "")
        return "\(project)/\(normalizedWorkspace)"
    }

    private var currentItem: EvolutionWorkspaceItemV2? {
        guard let workspace else { return nil }
        return appState.evolutionItem(project: project, workspace: workspace)
    }

    private var controlCapability: EvolutionControlCapability {
        appState.evolutionControlCapability(project: project, workspace: workspace)
    }

    /// 主控制按钮：运行中显示“停止”，其他状态显示“开始”。
    private var primaryControlShowsStop: Bool {
        controlCapability.canStop || controlCapability.isStopPending
    }

    private var canTriggerPrimaryControlAction: Bool {
        controlCapability.canStart || controlCapability.canStop
    }

    private var primaryControlButtonSymbol: String {
        if primaryControlShowsStop {
            return controlCapability.isStopPending ? "clock" : "stop.fill"
        }
        return controlCapability.isStartPending ? "clock" : "play.fill"
    }

    private var primaryControlButtonTint: Color {
        primaryControlShowsStop ? .red : .green
    }

    private var primaryControlHelpText: String {
        if primaryControlShowsStop {
            return actionHelpText("evolution.page.action.stop".localized, reason: controlCapability.stopReason)
        }
        return actionHelpText("evolution.page.action.startManual".localized, reason: controlCapability.startReason)
    }

    private let evolutionStageOrder: [String] = [
        "direction", "plan",
        "implement_general", "implement_visual", "implement_advanced",
        "verify", "judge", "report", "auto_commit",
    ]

    /// 可循环的代理阶段
    private let loopableStages: Set<String> = [
        "implement_general", "implement_visual", "implement_advanced",
        "verify", "judge",
    ]

    private let loopRoundOptions = [1, 2, 3, 5, 10, 16, 20]

    // MARK: - 代理颜色映射

    private func stageColor(_ stage: String) -> Color {
        switch normalizedStageKey(stage) {
        case "direction": return .cyan
        case "plan": return .blue
        case "implement_general": return .orange
        case "implement_visual": return .pink
        case "implement_advanced": return .purple
        case "verify": return .green
        case "judge": return .yellow
        case "report": return .mint
        case "auto_commit": return .gray
        default: return .secondary
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            pipelineHeader
            Divider()

            if !workspaceReady {
                noWorkspaceView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 上方内容区：始终展示当前循环运行态
                        cycleDetailArea

                        Divider()

                        // 下方循环列表：点击行弹出详情
                        cycleListArea
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .onAppear {
            refreshData()
            syncStartOptions()
        }
        .onChange(of: appState.selectedWorkspaceKey) { _, _ in
            refreshData()
            syncStartOptions()
            resetLocalTimeline()
        }
        .onChange(of: appState.selectedProjectName) { _, _ in
            refreshData()
            syncStartOptions()
            resetLocalTimeline()
        }
        .onChange(of: appState.connectionState) { _, state in
            guard state == .connected else { return }
            refreshData()
        }
        .onReceive(appState.$evolutionWorkspaceItems) { _ in
            syncStartOptions()
            updateTimeline()
        }
        .onReceive(appState.$evolutionBlockingRequired) { value in
            syncBlockerSheetState(value)
        }
        .onReceive(appState.$evolutionCycleHistories) { _ in
            syncCycleHistoriesFromAPI()
        }
        .sheet(item: $selectedCycleDetail) { payload in
            cycleDetailSheet(payload)
        }
        .sheet(isPresented: $isBlockerSheetPresented) {
            blockerSheet
        }
        .sheet(isPresented: $isHandoffSheetPresented) {
            handoffSheet
        }
        .sheet(isPresented: $isReportSheetPresented) {
            reportSheet
        }
    }

    // MARK: - 标题栏

    private var pipelineHeader: some View {
        HStack(spacing: 8) {
            Text("evolution.page.title".localized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            if let item = currentItem {
                // 当前轮次指示
                Text("\(item.globalLoopRound)/\(max(1, item.loopRoundLimit))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
            }
            Button {
                refreshData()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("evolution.page.refreshStatusHelp".localized)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 无工作空间

    private var noWorkspaceView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.4))
            Text("evolution.page.workspace.selectWorkspaceFirst".localized)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 控制区域

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // 循环轮次下拉
                Picker("", selection: $loopRoundLimit) {
                    ForEach(loopRoundOptions, id: \.self) { count in
                        Text("\(count) " + "evolution.page.pipeline.rounds".localized)
                            .tag(count)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 100)
                .controlSize(.small)
                .disabled(!controlCapability.canStart)

                Spacer(minLength: 4)

                // 操作按钮
                HStack(spacing: 4) {
                    Button {
                        triggerPrimaryControlAction()
                    } label: {
                        Image(systemName: primaryControlButtonSymbol)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(primaryControlButtonTint)
                    .help(primaryControlHelpText)
                    .disabled(!canTriggerPrimaryControlAction)

                    Button {
                        guard let workspace else { return }
                        guard controlCapability.canResume else { return }
                        appState.resumeEvolution(project: project, workspace: workspace)
                    } label: {
                        if controlCapability.isResumePending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(actionHelpText("evolution.page.action.resume".localized, reason: controlCapability.resumeReason))
                    .disabled(!controlCapability.canResume)

                    Divider().frame(height: 14)

                    Button {
                        loadHandoffAndPresent()
                    } label: {
                        Image(systemName: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("evolution.page.action.previewHandoff".localized)
                    .disabled(currentItem == nil)
                }
            }
        }
    }

    // MARK: - 运行中代理（放大卡片）

    private var runningAgentSection: some View {
        let runningAgents = (currentItem?.agents ?? []).filter {
            normalizedStageStatus($0.status) == "running"
        }

        return Group {
            if !runningAgents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        sectionLabel("evolution.page.pipeline.running".localized, icon: "bolt.fill", color: .orange)
                        Spacer()
                        // 总耗时（累加各代理耗时）
                        if let total = totalDurationText {
                            HStack(spacing: 3) {
                                Image(systemName: "timer")
                                    .font(.system(size: 9))
                                Text(total)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(.secondary)
                        }
                    }

                    ForEach(runningAgents, id: \.stage) { agent in
                        runningAgentCard(agent)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .bottom).combined(with: .opacity)
                            ))
                    }
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: runningAgents.map(\.stage))
            }
        }
    }

    private func runningAgentCard(_ agent: EvolutionAgentInfoV2) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // AI 工具图标
                aiToolIcon(for: agent.stage)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(stageDisplayName(agent.stage))
                        .font(.system(size: 13, weight: .semibold))
                    Text(agent.agent)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // 脉冲动画指示器
                Circle()
                    .fill(Color.orange)
                    .frame(width: 10, height: 10)
                    .modifier(PipelinePulseModifier())
            }

            // 状态信息行
            HStack(spacing: 12) {
                // 工具调用次数
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("\(agent.toolCallCount)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }

                // 运行时间（使用核心返回的 started_at）
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(formatElapsedTimeFrom(agent.startedAt))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                }

                Spacer()

                // 查看聊天
                if canOpenStageChat(stage: agent.stage, status: agent.status) {
                    Button {
                        openStageChat(stage: agent.stage)
                    } label: {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("evolution.page.pipeline.viewChat".localized)
                }
            }
            .foregroundColor(.secondary)

            // 进度条动画
            PipelineProgressBar()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1.5)
        )
    }

    // MARK: - 待命队列（横向胶囊）

    private var standbySection: some View {
        let standbyAgents = computeStandbyAgents()
        // 进入报告阶段后隐藏待命队列
        let isInReportPhase = (currentItem?.agents ?? []).contains {
            normalizedStageKey($0.stage) == "report" && normalizedStageStatus($0.status) == "running"
        }

        return Group {
            if !standbyAgents.isEmpty && !isInReportPhase {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("evolution.page.pipeline.standby".localized, icon: "clock", color: .secondary)

                    // 横向排列，允许换行
                    StandbyFlowLayout(spacing: 6) {
                        ForEach(standbyAgents, id: \.stage) { agent in
                            standbyCapsule(agent)
                                .transition(.opacity.combined(with: .scale))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: standbyAgents.map(\.stage))
            }
        }
    }

    /// 胶囊形代理标签
    private func standbyCapsule(_ agent: PipelineStandbyAgent) -> some View {
        let color = stageColor(agent.stage)
        return HStack(spacing: 4) {
            Image(systemName: stageIconName(agent.stage))
                .font(.system(size: 10))

            Text(stageDisplayName(agent.stage))
                .font(.system(size: 10))
                .lineLimit(1)

            if agent.isLoopable {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8))
                    .foregroundColor(color.opacity(0.7))
            }
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - 上方内容区（当前循环）

    private var cycleDetailArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            controlSection
            terminalReasonBanner
            runningAgentSection
            standbySection
        }
    }

    // MARK: - 循环状态指示条

    /// 循环状态指示条：显示当前循环的整体状态和异常原因
    @ViewBuilder
    private var cycleStatusBanner: some View {
        if let item = currentItem {
            let statusInfo = cycleStatusInfo(item.status)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: statusInfo.icon)
                        .font(.system(size: 10))
                        .foregroundColor(statusInfo.color)
                    Text("evolution.page.pipeline.cycleStatus".localized)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(statusInfo.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(statusInfo.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(statusInfo.color.opacity(0.12)))
                }

                // 终止原因
                if let reason = trimmedNonEmptyText(item.terminalReasonCode) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("evolution.page.pipeline.terminalReason".localized + ": ")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(localizedTerminalReason(reason))
                            .font(.system(size: 9))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                    }
                }
                if let terminalError = trimmedNonEmptyText(item.terminalErrorMessage) {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.red.opacity(0.9))
                        Text("evolution.page.pipeline.terminalError".localized + ": ")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(terminalError)
                            .font(.system(size: 9))
                            .foregroundColor(.primary)
                            .lineLimit(4)
                    }
                }

                // 限流错误信息
                if let rateLimitMsg = trimmedNonEmptyText(item.rateLimitErrorMessage) {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 9))
                            .foregroundColor(.yellow)
                        Text("evolution.page.pipeline.rateLimitError".localized + ": ")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(rateLimitMsg)
                            .font(.system(size: 9))
                            .foregroundColor(.primary)
                            .lineLimit(3)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(statusInfo.color.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(statusInfo.color.opacity(0.2), lineWidth: 1)
            )
        }
    }

    /// 根据循环状态返回颜色、图标和标签
    private func cycleStatusInfo(_ status: String) -> (color: Color, icon: String, label: String) {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "running":
            return (.green, "play.circle.fill", "evolution.status.running".localized)
        case "queued":
            return (.blue, "clock.fill", "evolution.status.queued".localized)
        case "completed", "done", "success":
            return (.green, "checkmark.circle.fill", "evolution.status.completed".localized)
        case "interrupted", "stopped":
            return (.orange, "pause.circle.fill", "evolution.status.interrupted".localized)
        case "failed_exhausted":
            return (.red, "xmark.circle.fill", "evolution.status.failedExhausted".localized)
        case "failed_system":
            return (.red, "exclamationmark.triangle.fill", "evolution.status.failedSystem".localized)
        case "idle":
            return (.secondary, "moon.fill", "evolution.status.idle".localized)
        default:
            return (.secondary, "questionmark.circle", status)
        }
    }

    /// 将终止原因码转为本地化描述
    private func localizedTerminalReason(_ code: String) -> String {
        let key = "evolution.terminalReason.\(code)"
        let localized = key.localized
        // 若没有对应翻译则返回原始码
        return localized == key ? code : localized
    }

    // MARK: - 下方循环列表（点击弹出详情）

    private var cycleListArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 本轮循环（有运行数据时才显示）
            if hasCurrentCycleRow {
                cycleListRow(
                    round: currentCycleRound,
                    color: .green,
                    title: currentCycleDisplayTitle,
                    badge: currentCycleBadge,
                    startTimeText: currentCycleStartTimeText,
                    stageEntries: completedTimeline.map { entry in
                        PipelineCycleStageEntry(
                            id: entry.id,
                            stage: entry.stage,
                            agent: entry.agent,
                            aiToolName: entry.aiToolName,
                            durationSeconds: entry.durationSeconds
                        )
                    },
                    onReportTap: currentCycleHasReportDocument
                        ? {
                            if let cycleID = currentItem?.cycleID {
                                openReportSheet(for: cycleID)
                            }
                        }
                        : nil
                ) {
                    openCurrentCycleDetailSheet()
                }
            }

            // 历史循环
            ForEach(cycleHistories) { cycle in
                cycleListRow(
                    round: cycle.round,
                    color: .indigo,
                    title: cycle.displayTitle,
                    startTimeText: cycleStartTimeText(cycle.startDate),
                    stageEntries: cycle.stageEntries.isEmpty ? cycle.stages.map { stage in
                        PipelineCycleStageEntry(id: UUID().uuidString, stage: stage, agent: "", durationSeconds: 0)
                    } : cycle.stageEntries,
                    onReportTap: cycleHasReportDocument(cycle) ? { openReportSheet(for: cycle.id) } : nil
                ) {
                    openHistoryCycleDetailSheet(cycle)
                }
            }

            if !hasCurrentCycleRow && cycleHistories.isEmpty {
                Text("暂无循环记录")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private var hasCurrentCycleRow: Bool {
        !completedTimeline.isEmpty || hasRunningAgents
    }

    private var currentCycleDisplayTitle: String {
        cycleDisplayTitle(currentItem?.title)
    }

    private var currentCycleRound: Int {
        max(1, currentItem?.globalLoopRound ?? lastRecordedRound)
    }

    private var hasRunningAgents: Bool {
        (currentItem?.agents ?? []).contains { normalizedStageStatus($0.status) == "running" }
    }

    private var currentCycleHasReportDocument: Bool {
        guard let item = currentItem else { return false }
        if item.executions.contains(where: {
            normalizedStageKey($0.stage) == "report" && isExecutionCompletedStatus($0.status)
        }) {
            return true
        }
        return item.agents.contains(where: {
            normalizedStageKey($0.stage) == "report" && isCompletedStatus(normalizedStageStatus($0.status))
        })
    }

    private var currentCycleStartTimeText: String {
        if let item = currentItem {
            let earliest = item.executions
                .compactMap { executionStartDate($0.startedAt) }
                .min()
            if let earliest {
                return cycleStartTimeText(earliest)
            }
        }
        return cycleStartTimeText(cycleStartDate)
    }

    private func cycleHasReportDocument(_ cycle: PipelineCycleHistory) -> Bool {
        if cycle.stageEntries.contains(where: { normalizedStageKey($0.stage) == "report" }) {
            return true
        }
        return cycle.stages.contains(where: { normalizedStageKey($0) == "report" })
    }

    private func cycleStartTimeText(_ date: Date) -> String {
        Self.cycleStartDateFormatter.string(from: date)
    }

    private var currentCycleBadge: String? {
        if hasRunningAgents { return "evolution.page.pipeline.running".localized }
        if let item = currentItem {
            let normalized = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "interrupted":
                return "evolution.status.interrupted".localized
            case "failed_exhausted":
                return "evolution.status.failedExhausted".localized
            case "failed_system":
                return "evolution.status.failedSystem".localized
            case "completed", "done", "success":
                return "evolution.status.completed".localized
            default:
                break
            }
        }
        return nil
    }

    private func cycleDisplayTitle(_ value: String?) -> String {
        guard let trimmed = trimmedNonEmptyText(value) else {
            return untitledCycleTitle
        }
        return trimmed
    }

    /// 循环列表行
    private func cycleListRow(
        round: Int,
        color: Color,
        title: String,
        badge: String? = nil,
        startTimeText: String,
        stageEntries: [PipelineCycleStageEntry]? = nil,
        onReportTap: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        // 计算总耗时
        let totalDuration: TimeInterval = stageEntries?.reduce(0) { $0 + $1.durationSeconds } ?? 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                roundBadge(round: round, color: color)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if let onReportTap {
                    Button(action: onReportTap) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("evolution.page.action.previewReport".localized)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(color)
            }

            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Image(systemName: "clock")
                        .font(.system(size: 8))
                    Text(startTimeText)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
                .foregroundColor(.secondary)

                if totalDuration > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "timer")
                            .font(.system(size: 8))
                        Text(Self.formatDuration(totalDuration))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }

                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.8)))
                }
            }

            // 分段彩色线条
            if let entries = stageEntries, !entries.isEmpty {
                proportionalStageBar(entries: entries, height: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(perform: action)
    }

    private func roundBadge(round: Int, color: Color) -> some View {
        Text("\(max(1, round))")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(color.opacity(0.14))
            )
            .overlay(
                Circle()
                    .stroke(color.opacity(0.45), lineWidth: 1)
            )
    }

    private struct StageBarSegment: Identifiable {
        let entry: PipelineCycleStageEntry
        let ratio: CGFloat
        var id: String { entry.id }
    }

    private func proportionalStageBar(entries: [PipelineCycleStageEntry], height: CGFloat) -> some View {
        let segments = stageBarSegments(entries)
        let segmentSpacing: CGFloat = 2

        return GeometryReader { geo in
            let totalSpacing = segmentSpacing * CGFloat(max(segments.count - 1, 0))
            let drawableWidth = max(geo.size.width - totalSpacing, 0)
            HStack(spacing: segmentSpacing) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(stageColor(segment.entry.stage))
                        .frame(width: max(0, drawableWidth * segment.ratio), height: height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.3), value: stageBarAnimationToken(segments))
        }
        .frame(height: height)
        .clipShape(Capsule())
    }

    private func stageBarAnimationToken(_ segments: [StageBarSegment]) -> String {
        segments
            .map { segment in
                "\(segment.id)=\(String(format: "%.6f", Double(segment.ratio)))"
            }
            .joined(separator: "|")
    }

    private func stageBarSegments(_ entries: [PipelineCycleStageEntry]) -> [StageBarSegment] {
        guard !entries.isEmpty else { return [] }

        let rawDurations = entries.map { max(0, $0.durationSeconds) }
        let positiveDurations = rawDurations.filter { $0 > 0 }
        let weights: [TimeInterval]

        if !positiveDurations.isEmpty {
            let averagePositive = positiveDurations.reduce(0, +) / Double(positiveDurations.count)
            let fallbackWeight = max(averagePositive * 0.12, 0.3)
            weights = rawDurations.map { duration in
                duration > 0 ? duration : fallbackWeight
            }
        } else {
            weights = Array(repeating: 1, count: entries.count)
        }

        let totalWeight = max(weights.reduce(0, +), 0.0001)
        return zip(entries, weights).map { entry, weight in
            StageBarSegment(entry: entry, ratio: CGFloat(weight / totalWeight))
        }
    }

    private func openCurrentCycleDetailSheet() {
        guard let item = currentItem else { return }
        selectedCycleDetail = makeCurrentCycleDetailPayload(item)
    }

    private func openHistoryCycleDetailSheet(_ cycle: PipelineCycleHistory) {
        selectedCycleDetail = makeHistoryCycleDetailPayload(cycle)
    }

    private func openReportSheet(for cycleID: String) {
        guard let workspace else { return }
        selectedReportCycleID = cycleID
        appState.requestEvolutionReport(project: project, workspace: workspace, cycleID: cycleID)
        isReportSheetPresented = true
    }

    private func refreshSelectedReport() {
        guard let workspace, let cycleID = selectedReportCycleID else { return }
        appState.requestEvolutionReport(project: project, workspace: workspace, cycleID: cycleID)
    }

    private func makeCurrentCycleDetailPayload(_ item: EvolutionWorkspaceItemV2) -> PipelineCycleDetailPayload {
        let entries = timelineEntriesFromCurrentItem(item)
        let totalSeconds = entries.compactMap(\.durationSeconds).reduce(0, +)
        let earliestStart = entries.compactMap(\.startedAtDate).min()
        return PipelineCycleDetailPayload(
            id: "current:\(item.cycleID)",
            cycleID: item.cycleID,
            title: cycleDisplayTitle(item.title),
            round: max(1, item.globalLoopRound),
            status: item.status,
            startTimeText: cycleStartTimeText(earliestStart ?? cycleStartDate),
            totalDurationText: totalSeconds > 0 ? Self.formatDuration(totalSeconds) : nil,
            terminalReasonCode: item.terminalReasonCode,
            terminalErrorMessage: item.terminalErrorMessage,
            timelineEntries: entries
        )
    }

    private func makeHistoryCycleDetailPayload(_ cycle: PipelineCycleHistory) -> PipelineCycleDetailPayload {
        let entries = timelineEntriesFromHistoryCycle(cycle)
        let totalSeconds = entries.compactMap(\.durationSeconds).reduce(0, +)
        return PipelineCycleDetailPayload(
            id: "history:\(cycle.id)",
            cycleID: cycle.id,
            title: cycle.displayTitle,
            round: max(1, cycle.round),
            status: nil,
            startTimeText: cycleStartTimeText(cycle.startDate),
            totalDurationText: totalSeconds > 0 ? Self.formatDuration(totalSeconds) : nil,
            terminalReasonCode: cycle.terminalReasonCode,
            terminalErrorMessage: cycle.terminalErrorMessage,
            timelineEntries: entries
        )
    }

    private func timelineEntriesFromCurrentItem(_ item: EvolutionWorkspaceItemV2) -> [PipelineCycleTimelineEntry] {
        let executionEntries = item.executions
            .sorted { lhs, rhs in
                switch (lhs.startedAt.isEmpty, rhs.startedAt.isEmpty) {
                case (false, false):
                    if lhs.startedAt != rhs.startedAt {
                        return lhs.startedAt < rhs.startedAt
                    }
                case (false, true):
                    return true
                case (true, false):
                    return false
                case (true, true):
                    break
                }
                return lhs.sessionID < rhs.sessionID
            }
            .map { execution in
                PipelineCycleTimelineEntry(
                    id: execution.sessionID + "|" + execution.startedAt,
                    stage: execution.stage,
                    agent: execution.agent,
                    aiToolName: execution.aiTool,
                    status: execution.status,
                    startedAt: trimmedNonEmptyText(execution.startedAt),
                    durationSeconds: execution.durationMs.map { TimeInterval($0) / 1000.0 }
                )
            }
        if !executionEntries.isEmpty {
            return executionEntries
        }

        return item.agents.map { agent in
            PipelineCycleTimelineEntry(
                id: "agent:\(normalizedStageKey(agent.stage))",
                stage: agent.stage,
                agent: agent.agent,
                aiToolName: findProfile(for: normalizedStageKey(agent.stage))?.aiTool.displayName ?? "",
                status: agent.status,
                startedAt: trimmedNonEmptyText(agent.startedAt),
                durationSeconds: agent.durationMs.map { TimeInterval($0) / 1000.0 }
            )
        }
    }

    private func timelineEntriesFromHistoryCycle(_ cycle: PipelineCycleHistory) -> [PipelineCycleTimelineEntry] {
        if !cycle.stageEntries.isEmpty {
            return cycle.stageEntries.map { entry in
                PipelineCycleTimelineEntry(
                    id: entry.id,
                    stage: entry.stage,
                    agent: entry.agent,
                    aiToolName: entry.aiToolName,
                    status: entry.status ?? "",
                    startedAt: entry.startedAt,
                    durationSeconds: entry.durationSeconds > 0 ? entry.durationSeconds : nil
                )
            }
        }
        return cycle.stages.enumerated().map { index, stage in
            PipelineCycleTimelineEntry(
                id: "\(cycle.id)_\(index)_\(stage)",
                stage: stage,
                agent: "",
                aiToolName: "",
                status: "",
                startedAt: nil,
                durationSeconds: nil
            )
        }
    }

    @ViewBuilder
    private func cycleDetailSheet(_ payload: PipelineCycleDetailPayload) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        roundBadge(round: payload.round, color: .indigo)
                        Text(payload.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        if let status = trimmedNonEmptyText(payload.status) {
                            let info = cycleStatusInfo(status)
                            Text(info.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(info.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(info.color.opacity(0.12)))
                        }
                    }

                    HStack(spacing: 10) {
                        detailMetaBadge(
                            icon: "clock",
                            label: "evolution.page.pipeline.startTimeLabel".localized,
                            value: payload.startTimeText
                        )
                        if let totalDurationText = payload.totalDurationText {
                            detailMetaBadge(
                                icon: "timer",
                                label: "evolution.page.pipeline.durationLabel".localized,
                                value: totalDurationText
                            )
                        }
                    }

                    if let reason = trimmedNonEmptyText(payload.terminalReasonCode) {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text(localizedTerminalReason(reason))
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let error = trimmedNonEmptyText(payload.terminalErrorMessage) {
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Text("evolution.page.pipeline.timelineTitle".localized)
                        .font(.headline)

                    if payload.timelineEntries.isEmpty {
                        Text("evolution.page.pipeline.noTimeline".localized)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(payload.timelineEntries) { entry in
                                cycleTimelineRow(entry)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(String(format: "evolution.page.pipeline.roundLabel".localized, payload.round))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) {
                        selectedCycleDetail = nil
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    private func cycleTimelineRow(_ entry: PipelineCycleTimelineEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stageIconName(entry.stage))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(stageColor(entry.stage))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(stageDisplayName(entry.stage))
                        .font(.system(size: 12, weight: .semibold))
                    if let agent = trimmedNonEmptyText(entry.agent) {
                        Text(agent)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 10) {
                    detailTimelineText(icon: "clock", value: timelineStartTimeText(entry.startedAt))
                    detailTimelineText(icon: "timer", value: timelineDurationText(entry))
                    let aiTool = trimmedNonEmptyText(entry.aiToolName) ?? "-"
                    detailTimelineText(icon: "sparkles", value: "\("evolution.page.pipeline.aiTool".localized): \(aiTool)")
                }
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(stageColor(entry.stage).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(stageColor(entry.stage).opacity(0.2), lineWidth: 1)
        )
    }

    private func detailMetaBadge(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(label)
                .font(.system(size: 10))
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func detailTimelineText(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
    }

    private func timelineStartTimeText(_ startedAt: String?) -> String {
        guard let date = executionStartDate(startedAt) else {
            return "\("evolution.page.pipeline.startTimeLabel".localized): -"
        }
        return "\("evolution.page.pipeline.startTimeLabel".localized): \(Self.cycleDetailTimeFormatter.string(from: date))"
    }

    private func timelineDurationText(_ entry: PipelineCycleTimelineEntry) -> String {
        if let durationSeconds = entry.durationSeconds, durationSeconds > 0 {
            return "\("evolution.page.pipeline.durationLabel".localized): \(Self.formatDuration(durationSeconds))"
        }
        let normalized = normalizedStageStatus(entry.status)
        if normalized == "running" || normalized == "进行中" {
            return "\("evolution.page.pipeline.durationLabel".localized): \(formatElapsedTimeFrom(entry.startedAt))"
        }
        return "\("evolution.page.pipeline.durationLabel".localized): \("evolution.page.pipeline.durationUnknown".localized)"
    }

    private func executionStartDate(_ value: String?) -> Date? {
        guard let value = trimmedNonEmptyText(value) else { return nil }
        return Self.rfc3339Formatter.date(from: value)
            ?? Self.rfc3339FallbackFormatter.date(from: value)
    }

    private var reportSheet: some View {
        NavigationStack {
            Group {
                if appState.evolutionReportLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("evolution.page.report.loading".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = appState.evolutionReportError {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content = appState.evolutionReportContent {
                    ScrollView {
                        MarkdownTextView(text: content, baseFontSize: 13, textColor: .primary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("evolution.page.report.empty".localized)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("evolution.page.report.title".localized)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        refreshSelectedReport()
                    } label: {
                        Label("evolution.page.report.refresh".localized, systemImage: "arrow.clockwise")
                    }
                    .disabled(selectedReportCycleID == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) {
                        isReportSheetPresented = false
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: - 终止/异常原因提示（仅在终止或异常时显示）

    @ViewBuilder
    private var terminalReasonBanner: some View {
        if let item = currentItem {
            let normalized = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isTerminal = ["interrupted", "failed_exhausted", "failed_system", "completed", "done", "success"].contains(normalized)
            if isTerminal {
                let statusInfo = cycleStatusInfo(item.status)
                VStack(alignment: .leading, spacing: 4) {
                    // 终止原因
                    if let reason = trimmedNonEmptyText(item.terminalReasonCode) {
                        HStack(spacing: 4) {
                            Image(systemName: statusInfo.icon)
                                .font(.system(size: 9))
                                .foregroundColor(statusInfo.color)
                            Text(localizedTerminalReason(reason))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                        }
                    }
                    if let terminalError = trimmedNonEmptyText(item.terminalErrorMessage) {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "text.bubble.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.red.opacity(0.9))
                            Text(terminalError)
                                .font(.system(size: 9))
                                .foregroundColor(.primary)
                                .lineLimit(4)
                        }
                    }

                    // 限流错误信息
                    if let rateLimitMsg = trimmedNonEmptyText(item.rateLimitErrorMessage) {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.system(size: 9))
                                .foregroundColor(.yellow)
                            Text(rateLimitMsg)
                                .font(.system(size: 9))
                                .foregroundColor(.primary)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(statusInfo.color.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(statusInfo.color.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - 本轮循环紧凑已完成条

    private var currentCycleCompactBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("evolution.page.pipeline.completedAgents".localized, icon: "checkmark.circle.fill", color: .green)
            HStack(spacing: 2) {
                ForEach(completedTimeline) { entry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(stageColor(entry.stage))
                        .frame(height: 6)
                        .onTapGesture {
                            if normalizedStageKey(entry.stage) != "auto_commit" {
                                openStageChat(stage: entry.stage)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(Capsule())
        }
    }

    // MARK: - 历史循环紧凑视图

    private func historyCycleCompactView(_ cycle: PipelineCycleHistory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundColor(.indigo)
                Text(cycle.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(String(format: "evolution.page.pipeline.roundLabel".localized, cycle.round))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
            }

            // 彩色分段线条
            HStack(spacing: 2) {
                let entries = cycle.stageEntries.isEmpty
                    ? cycle.stages.map { PipelineCycleStageEntry(id: UUID().uuidString, stage: $0, agent: "", durationSeconds: 0) }
                    : cycle.stageEntries
                ForEach(entries) { entry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(stageColor(entry.stage))
                        .frame(height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(Capsule())

            // 终止原因（如有）
            if let reason = trimmedNonEmptyText(cycle.terminalReasonCode) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(localizedTerminalReason(reason))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            if let terminalError = trimmedNonEmptyText(cycle.terminalErrorMessage) {
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(terminalError)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - 本轮循环已完成时间线（上方详情）

    private var currentCycleTimelineDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("evolution.page.pipeline.completedAgents".localized, icon: "checkmark.circle.fill", color: .green)

            ForEach(Array(completedTimeline.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 8) {
                    VStack(spacing: 0) {
                        if index > 0 {
                            Rectangle()
                                .fill(stageColor(entry.stage).opacity(0.3))
                                .frame(width: 2, height: 8)
                        }
                        Circle()
                            .fill(stageColor(entry.stage))
                            .frame(width: 8, height: 8)
                        if index < completedTimeline.count - 1 {
                            Rectangle()
                                .fill(stageColor(entry.stage).opacity(0.3))
                                .frame(width: 2, height: 8)
                        }
                    }

                    Image(systemName: stageIconName(entry.stage))
                        .font(.system(size: 10))
                        .foregroundColor(stageColor(entry.stage))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(stageDisplayName(entry.stage))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(entry.agent)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            if entry.toolCallCount > 0 {
                                Text("·")
                                    .foregroundColor(.secondary)
                                Text("\(entry.toolCallCount)" + "evolution.page.pipeline.toolCalls".localized)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Text(entry.completedAt)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))

                    if normalizedStageKey(entry.stage) != "auto_commit" {
                        Button {
                            openStageChat(stage: entry.stage)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: completedTimeline.count)
    }

    // MARK: - 历史循环详情（上方详情）

    private func historyCycleDetailView(_ cycle: PipelineCycleHistory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundColor(.indigo)
                Text(cycle.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(String(format: "evolution.page.pipeline.roundLabel".localized, cycle.round))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
            }

            // 彩色分段线条
            HStack(spacing: 2) {
                let entries = cycle.stageEntries.isEmpty
                    ? cycle.stages.map { PipelineCycleStageEntry(id: UUID().uuidString, stage: $0, agent: "", durationSeconds: 0) }
                    : cycle.stageEntries
                ForEach(entries) { entry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(stageColor(entry.stage))
                        .frame(height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(Capsule())

            // 阶段时间线
            ForEach(Array((cycle.stageEntries.isEmpty
                ? cycle.stages.enumerated().map { (i, s) in
                    PipelineCycleStageEntry(id: "\(i)", stage: s, agent: "", durationSeconds: 0)
                }
                : cycle.stageEntries).enumerated()), id: \.element.id
            ) { index, entry in
                HStack(spacing: 8) {
                    VStack(spacing: 0) {
                        if index > 0 {
                            Rectangle()
                                .fill(stageColor(entry.stage).opacity(0.3))
                                .frame(width: 2, height: 8)
                        }
                        Circle()
                            .fill(stageColor(entry.stage))
                            .frame(width: 8, height: 8)
                        if index < (cycle.stageEntries.isEmpty ? cycle.stages.count : cycle.stageEntries.count) - 1 {
                            Rectangle()
                                .fill(stageColor(entry.stage).opacity(0.3))
                                .frame(width: 2, height: 8)
                        }
                    }

                    Image(systemName: stageIconName(entry.stage))
                        .font(.system(size: 10))
                        .foregroundColor(stageColor(entry.stage))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(stageDisplayName(entry.stage))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        if !entry.agent.isEmpty {
                            Text(entry.agent)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    if entry.durationSeconds > 0 {
                        Text(entry.formattedDuration)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
            }
        }
    }

    /// 相对时间格式化
    private func relativeTimeString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "evolution.page.pipeline.justNow".localized
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return String(format: "evolution.page.pipeline.minutesAgo".localized, minutes)
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return String(format: "evolution.page.pipeline.hoursAgo".localized, hours)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }

    // MARK: - 辅助组件

    private func sectionLabel(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 4)
    }

    /// 获取代理对应的 AI 工具图标
    private func aiToolIcon(for stage: String) -> some View {
        let key = normalizedStageKey(stage)
        let profile = findProfile(for: key)
        let toolIconAsset = profile?.aiTool.iconAssetName

        return Group {
            if let asset = toolIconAsset {
                Image(asset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: stageIconName(stage))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(stageColor(stage))
            }
        }
    }

    private func findProfile(for stageKey: String) -> EvolutionStageProfileInfoV2? {
        if let workspace, !workspace.isEmpty {
            let profiles = appState.evolutionProfiles(project: project, workspace: workspace)
            return profiles.first { normalizedStageKey($0.stage) == stageKey }
        }
        let defaults = appState.evolutionDefaultProfiles
        if let match = defaults.first(where: { normalizedStageKey($0.stage) == stageKey }) {
            let model: EvolutionModelSelectionV2? = {
                guard !match.providerID.isEmpty, !match.modelID.isEmpty else { return nil }
                return EvolutionModelSelectionV2(providerID: match.providerID, modelID: match.modelID)
            }()
            return EvolutionStageProfileInfoV2(
                stage: match.stage,
                aiTool: match.aiTool,
                mode: match.mode.isEmpty ? nil : match.mode,
                model: model,
                configOptions: match.configOptions
            )
        }
        return nil
    }

    // MARK: - 进度条

    struct PipelineProgressBar: View {
        @State private var offset: CGFloat = -1

        var body: some View {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange.opacity(0.15))
                    .frame(height: 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [.orange.opacity(0), .orange, .orange.opacity(0)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * 0.3, height: 3)
                            .offset(x: offset * geo.size.width * 0.7)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .frame(height: 3)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    offset = 1
                }
            }
        }
    }

    // MARK: - 脉冲动画

    struct PipelinePulseModifier: ViewModifier {
        @State private var isAnimating = false

        func body(content: Content) -> some View {
            content
                .scaleEffect(isAnimating ? 1.3 : 0.9)
                .opacity(isAnimating ? 0.6 : 1.0)
                .animation(
                    .easeInOut(duration: 0.9)
                        .repeatForever(autoreverses: true),
                    value: isAnimating
                )
                .onAppear { isAnimating = true }
        }
    }

    // MARK: - 时间格式化

    /// 根据核心返回的 started_at（RFC3339）计算实时耗时
    private func formatElapsedTimeFrom(_ startedAtRFC3339: String?) -> String {
        guard let str = startedAtRFC3339,
              let date = Self.rfc3339Formatter.date(from: str) ?? Self.rfc3339FallbackFormatter.date(from: str) else {
            return "0s"
        }
        let elapsed = Date().timeIntervalSince(date)
        return Self.formatDuration(elapsed)
    }

    /// 将毫秒数格式化为可读时长
    private static func formatDurationMs(_ ms: UInt64) -> String {
        formatDuration(TimeInterval(ms) / 1000.0)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 {
            return "\(total)s"
        } else {
            let minutes = total / 60
            let secs = total % 60
            return "\(minutes)m\(String(format: "%02d", secs))s"
        }
    }

    private static let rfc3339Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let rfc3339FallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let cycleStartDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static let cycleDetailTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    /// 计算所有已完成代理的总耗时（核心累加）
    private var totalDurationText: String? {
        let executionDurations = (currentItem?.executions ?? [])
            .filter { isExecutionCompletedStatus($0.status) }
            .compactMap(\.durationMs)
        let totalMs = executionDurations.isEmpty
            ? (currentItem?.agents ?? []).compactMap(\.durationMs)
                .reduce(0, +)
            : executionDurations.reduce(0, +)
        guard totalMs > 0 else { return nil }
        return Self.formatDurationMs(totalMs)
    }

    // MARK: - 数据逻辑

    private func computeStandbyAgents() -> [PipelineStandbyAgent] {
        let runningStages = Set((currentItem?.agents ?? [])
            .filter { normalizedStageStatus($0.status) == "running" }
            .map { normalizedStageKey($0.stage) })

        let completedStages = Set((currentItem?.agents ?? [])
            .filter { isCompletedStatus(normalizedStageStatus($0.status)) }
            .map { normalizedStageKey($0.stage) })

        var standby: [PipelineStandbyAgent] = []

        for stage in evolutionStageOrder {
            let isRunning = runningStages.contains(stage)
            let isCompleted = completedStages.contains(stage)

            if !isRunning && !isCompleted {
                standby.append(PipelineStandbyAgent(
                    stage: stage,
                    isLoopable: loopableStages.contains(stage)
                ))
            } else if isCompleted && loopableStages.contains(stage) {
                // 可循环代理完成后回到待命区
                standby.append(PipelineStandbyAgent(
                    stage: stage,
                    isLoopable: true
                ))
            }
        }
        return standby
    }

    private func updateTimeline() {
        guard let item = currentItem else { return }

        // 检测轮次变化，如果轮次增加，清空当前时间线并重新请求历史
        if item.globalLoopRound > lastRecordedRound && lastRecordedRound > 0 && !completedTimeline.isEmpty {
            completedTimeline.removeAll()
            cycleStartDate = Date()
            // 从工作空间文件夹重新加载历史数据
            if let ws = workspace {
                appState.requestEvolutionCycleHistory(project: project, workspace: ws)
            }
        }
        lastRecordedRound = item.globalLoopRound

        let sortedExecutions = item.executions
            .filter { isExecutionCompletedStatus($0.status) }
            .sorted { lhs, rhs in
                switch (lhs.startedAt.isEmpty, rhs.startedAt.isEmpty) {
                case (false, false):
                    if lhs.startedAt != rhs.startedAt {
                        return lhs.startedAt < rhs.startedAt
                    }
                case (false, true):
                    return true
                case (true, false):
                    return false
                case (true, true):
                    break
                }
                return lhs.sessionID < rhs.sessionID
            }
        completedTimeline = sortedExecutions.map { execution in
            PipelineTimelineEntry(
                id: execution.sessionID + "|" + execution.startedAt,
                stage: normalizedStageKey(execution.stage),
                agent: execution.agent,
                toolCallCount: execution.toolCallCount,
                completedAt: pipelineTimeLabel(from: execution.completedAt),
                aiToolName: execution.aiTool,
                durationSeconds: execution.durationMs.map { TimeInterval($0) / 1000.0 } ?? 0
            )
        }
    }

    private func resetLocalTimeline() {
        completedTimeline.removeAll()
        cycleHistories.removeAll()
        lastRecordedRound = 0
        cycleStartDate = Date()
    }

    /// 将 API 返回的历史循环数据同步到本地视图模型
    private func syncCycleHistoriesFromAPI() {
        guard let ws = workspace else { return }
        let key = appState.globalWorkspaceKey(projectName: project, workspaceName: appState.normalizeEvolutionWorkspaceName(ws))
        guard let apiCycles = appState.evolutionCycleHistories[key] else { return }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        cycleHistories = apiCycles.map { cycle in
            let startDate = isoFormatter.date(from: cycle.createdAt)
                ?? fallbackFormatter.date(from: cycle.createdAt)
                ?? Date()
            let entries: [PipelineCycleStageEntry] = {
                let executionEntries = cycle.executions
                    .filter { isExecutionCompletedStatus($0.status) }
                    .sorted { lhs, rhs in
                        switch (lhs.startedAt.isEmpty, rhs.startedAt.isEmpty) {
                        case (false, false):
                            if lhs.startedAt != rhs.startedAt {
                                return lhs.startedAt < rhs.startedAt
                            }
                        case (false, true):
                            return true
                        case (true, false):
                            return false
                        case (true, true):
                            break
                        }
                        return lhs.sessionID < rhs.sessionID
                    }
                    .map { execution in
                        PipelineCycleStageEntry(
                            id: "\(cycle.cycleID)_\(execution.sessionID)_\(execution.startedAt)",
                            stage: normalizedStageKey(execution.stage),
                            agent: execution.agent,
                            aiToolName: execution.aiTool,
                            startedAt: trimmedNonEmptyText(execution.startedAt),
                            status: execution.status,
                            durationSeconds: execution.durationMs.map { TimeInterval($0) / 1000.0 } ?? 0
                        )
                    }
                if !executionEntries.isEmpty {
                    return executionEntries
                }
                return cycle.stages.map { stage in
                    PipelineCycleStageEntry(
                        id: "\(cycle.cycleID)_\(stage.stage)",
                        stage: normalizedStageKey(stage.stage),
                        agent: stage.agent,
                        aiToolName: stage.aiTool,
                        status: stage.status,
                        durationSeconds: stage.durationMs.map { TimeInterval($0) / 1000.0 } ?? 0
                    )
                }
            }()
            return PipelineCycleHistory(
                id: cycle.cycleID,
                title: cycle.title,
                round: cycle.globalLoopRound,
                stages: entries.map(\.stage),
                startDate: startDate,
                stageEntries: entries,
                terminalReasonCode: cycle.terminalReasonCode,
                terminalErrorMessage: cycle.terminalErrorMessage
            )
        }
    }

    // MARK: - Stage Chat

    private func openStageChat(stage: String) {
        guard let item = currentItem else { return }
        appState.openEvolutionStageChat(
            project: item.project,
            workspace: item.workspace,
            cycleId: item.cycleID,
            stage: stage
        )
        // macOS 端不再弹出 sheet，handleEvolutionStageChatOpened 会直接
        // 将会话加载到主聊天区，由左侧侧边栏高亮显示
    }

    private func canOpenStageChat(stage: String, status: String) -> Bool {
        if normalizedStageKey(stage) == "auto_commit" { return false }
        let normalized = normalizedStageStatus(status)
        return normalized == "running" || isCompletedStatus(normalized)
    }

    // MARK: - Handoff

    private func loadHandoffAndPresent() {
        guard let item = currentItem else { return }
        appState.requestEvolutionHandoff(project: project, workspace: item.workspace, cycleID: item.cycleID)
        isHandoffSheetPresented = true
    }

    private var handoffSheet: some View {
        NavigationStack {
            Group {
                if appState.evolutionHandoffLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("evolution.page.handoff.loading".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = appState.evolutionHandoffError {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content = appState.evolutionHandoffContent {
                    ScrollView {
                        MarkdownTextView(text: content, baseFontSize: 13, textColor: .primary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("evolution.page.handoff.empty".localized)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("evolution.page.handoff.title".localized)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        loadHandoffAndPresent()
                    } label: {
                        Label("evolution.page.handoff.refresh".localized, systemImage: "arrow.clockwise")
                    }
                    .disabled(currentItem == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) {
                        isHandoffSheetPresented = false
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: - Blocker Sheet

    private var blockerSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let blocking = appState.evolutionBlockingRequired {
                    Text("evolution.page.blocker.detectedHint".localized)
                        .font(.headline)
                    Text(
                        String(
                            format: "evolution.page.blocker.triggerAndFile".localized,
                            blocking.trigger,
                            blocking.blockerFilePath
                        )
                    )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    List {
                        ForEach(blocking.unresolvedItems, id: \.blockerID) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: bindingSelected(item.blockerID)) {
                                    Text(item.title)
                                }
                                .toggleStyle(.checkbox)
                                Text(item.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if !item.options.isEmpty {
                                    Picker("evolution.page.blocker.option".localized, selection: bindingOption(item.blockerID)) {
                                        Text("evolution.page.blocker.choose".localized).tag("")
                                        ForEach(item.options, id: \.optionID) { option in
                                            Text(option.label).tag(option.optionID)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }
                                if item.allowCustomInput || item.options.isEmpty {
                                    TextField("evolution.page.blocker.answerInput".localized, text: bindingAnswer(item.blockerID))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    HStack {
                        Button("common.close".localized) {
                            isBlockerSheetPresented = false
                        }
                        Spacer()
                        Button("evolution.page.blocker.submitSelected".localized) {
                            submitBlockerAnswers(blocking)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("evolution.page.blocker.noTasks".localized)
                    Button("common.close".localized) {
                        isBlockerSheetPresented = false
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 640, minHeight: 420)
            .navigationTitle("evolution.page.blocker.sheetTitle".localized)
        }
    }

    // MARK: - Blocker 辅助

    private func bindingSelected(_ blockerID: String) -> Binding<Bool> {
        Binding(
            get: { blockerDrafts[blockerID]?.selected ?? true },
            set: { value in
                var draft = blockerDrafts[blockerID] ?? EvolutionPipelineBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
                draft.selected = value
                blockerDrafts[blockerID] = draft
            }
        )
    }

    private func bindingOption(_ blockerID: String) -> Binding<String> {
        Binding(
            get: { blockerDrafts[blockerID]?.selectedOptionID ?? "" },
            set: { value in
                var draft = blockerDrafts[blockerID] ?? EvolutionPipelineBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
                draft.selectedOptionID = value
                blockerDrafts[blockerID] = draft
            }
        )
    }

    private func bindingAnswer(_ blockerID: String) -> Binding<String> {
        Binding(
            get: { blockerDrafts[blockerID]?.answerText ?? "" },
            set: { value in
                var draft = blockerDrafts[blockerID] ?? EvolutionPipelineBlockerDraft(selected: true, selectedOptionID: "", answerText: "")
                draft.answerText = value
                blockerDrafts[blockerID] = draft
            }
        )
    }

    private func syncBlockerSheetState(_ value: EvolutionBlockingRequiredV2?) {
        guard let value,
              let ws = workspace,
              value.project == project,
              appState.normalizeEvolutionWorkspaceName(value.workspace) == appState.normalizeEvolutionWorkspaceName(ws) else {
            return
        }
        for item in value.unresolvedItems {
            if blockerDrafts[item.blockerID] != nil { continue }
            blockerDrafts[item.blockerID] = EvolutionPipelineBlockerDraft(
                selected: true,
                selectedOptionID: item.options.first?.optionID ?? "",
                answerText: ""
            )
        }
        isBlockerSheetPresented = true
    }

    private func submitBlockerAnswers(_ blocking: EvolutionBlockingRequiredV2) {
        let resolutions: [EvolutionBlockerResolutionInputV2] = blocking.unresolvedItems.compactMap { item in
            let draft = blockerDrafts[item.blockerID] ?? EvolutionPipelineBlockerDraft(
                selected: true,
                selectedOptionID: "",
                answerText: ""
            )
            guard draft.selected else { return nil }
            let selectedOptionIDs = draft.selectedOptionID.isEmpty ? [] : [draft.selectedOptionID]
            let answer = draft.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
            return EvolutionBlockerResolutionInputV2(
                blockerID: item.blockerID,
                selectedOptionIDs: selectedOptionIDs,
                answerText: answer.isEmpty ? nil : answer
            )
        }
        appState.resolveEvolutionBlockers(
            project: blocking.project,
            workspace: blocking.workspace,
            resolutions: resolutions
        )
    }

    // MARK: - 启动逻辑

    private func triggerPrimaryControlAction() {
        if primaryControlShowsStop {
            stopCurrentWorkspace()
        } else {
            startCurrentWorkspace()
        }
    }

    private func stopCurrentWorkspace() {
        guard let workspace else { return }
        guard controlCapability.canStop else { return }
        appState.stopEvolution(project: project, workspace: workspace)
    }

    private func startCurrentWorkspace() {
        guard let workspace else { return }
        guard controlCapability.canStart else { return }
        let defaultProfiles = appState.evolutionDefaultProfiles
        let profiles: [EvolutionStageProfileInfoV2] = defaultProfiles.map { item in
            let model: EvolutionModelSelectionV2? = {
                guard !item.providerID.isEmpty, !item.modelID.isEmpty else { return nil }
                return EvolutionModelSelectionV2(providerID: item.providerID, modelID: item.modelID)
            }()
            return EvolutionStageProfileInfoV2(
                stage: item.stage,
                aiTool: item.aiTool,
                mode: item.mode.isEmpty ? nil : item.mode,
                model: model,
                configOptions: item.configOptions
            )
        }
        appState.startEvolution(
            project: project,
            workspace: workspace,
            loopRoundLimit: loopRoundLimit,
            profiles: profiles
        )
        resetLocalTimeline()
    }

    private func actionHelpText(_ base: String, reason: String?) -> String {
        guard let reason,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }
        return "\(base)\n\(reason)"
    }

    private func refreshData() {
        appState.requestEvolutionSnapshot()
        // 从工作空间文件夹加载历史循环数据
        if let ws = workspace {
            appState.requestEvolutionCycleHistory(project: project, workspace: ws)
        }
    }

    private func syncStartOptions() {
        guard workspaceReady else { return }
        if let item = currentItem {
            loopRoundLimit = max(1, item.loopRoundLimit)
            lastLoopRoundWorkspaceContext = workspaceContextKey
            return
        }
        guard workspaceContextKey != lastLoopRoundWorkspaceContext else { return }
        loopRoundLimit = 1
        lastLoopRoundWorkspaceContext = workspaceContextKey
    }

    // MARK: - 阶段辅助方法

    private func normalizedStageKey(_ stage: String) -> String {
        let normalized = stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "implement" { return "implement_general" }
        return normalized
    }

    private func normalizedStageStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func trimmedNonEmptyText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isCompletedStatus(_ status: String) -> Bool {
        ["completed", "done", "success", "succeeded", "已完成", "完成"].contains(status)
    }

    private func isExecutionCompletedStatus(_ status: String) -> Bool {
        let normalized = normalizedStageStatus(status)
        if normalized.isEmpty {
            return false
        }
        if ["running", "pending", "queued", "in_progress", "processing"].contains(normalized) {
            return false
        }
        return true
    }

    private func pipelineTimeLabel(from isoString: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        guard let isoString = trimmedNonEmptyText(isoString),
              let date = Self.rfc3339Formatter.date(from: isoString)
                ?? Self.rfc3339FallbackFormatter.date(from: isoString) else {
            return formatter.string(from: Date())
        }
        return formatter.string(from: date)
    }

    private func stageDisplayName(_ stage: String) -> String {
        let trimmed = stage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "evolution.stage.unnamed".localized }
        switch trimmed.lowercased() {
        case "direction": return "evolution.stage.direction".localized
        case "plan": return "evolution.stage.plan".localized
        case "implement_general": return "evolution.stage.implementGeneral".localized
        case "implement_visual": return "evolution.stage.implementVisual".localized
        case "implement_advanced": return "evolution.stage.implementAdvanced".localized
        case "implement": return "evolution.stage.implementGeneral".localized
        case "verify": return "evolution.stage.verify".localized
        case "judge": return "evolution.stage.judge".localized
        case "report": return "evolution.stage.report".localized
        case "auto_commit": return "evolution.stage.autoCommit".localized
        default: return trimmed
        }
    }

    private func stageIconName(_ stage: String) -> String {
        switch stage.lowercased() {
        case "direction": return "arrow.triangle.branch"
        case "plan": return "map"
        case "implement_general", "implement": return "hammer"
        case "implement_visual": return "paintbrush"
        case "implement_advanced": return "wand.and.stars"
        case "verify": return "checkmark.seal"
        case "judge": return "scalemass"
        case "report": return "doc.text"
        case "auto_commit": return "sparkles"
        default: return "person.crop.square"
        }
    }
}

// MARK: - 数据模型

struct PipelineStandbyAgent: Equatable {
    let stage: String
    let isLoopable: Bool
}

struct PipelineTimelineEntry: Identifiable, Equatable {
    let id: String
    let stage: String
    let agent: String
    let toolCallCount: Int
    let completedAt: String
    let aiToolName: String
    /// 运行时长（秒）
    let durationSeconds: TimeInterval
    /// 记录完成时的绝对时间，用于计算运行时长
    let completedDate: Date

    init(
        id: String,
        stage: String,
        agent: String,
        toolCallCount: Int,
        completedAt: String,
        aiToolName: String = "",
        durationSeconds: TimeInterval = 0,
        completedDate: Date = Date()
    ) {
        self.id = id
        self.stage = stage
        self.agent = agent
        self.toolCallCount = toolCallCount
        self.completedAt = completedAt
        self.aiToolName = aiToolName
        self.durationSeconds = durationSeconds
        self.completedDate = completedDate
    }
}

/// 历史循环中每个阶段的记录
struct PipelineCycleStageEntry: Identifiable, Equatable {
    let id: String
    let stage: String
    let agent: String
    let aiToolName: String
    /// 阶段开始时间（RFC3339）
    let startedAt: String?
    /// 阶段状态（运行中/已完成等）
    let status: String?
    /// 运行时长（秒）
    let durationSeconds: TimeInterval

    init(
        id: String,
        stage: String,
        agent: String,
        aiToolName: String = "",
        startedAt: String? = nil,
        status: String? = nil,
        durationSeconds: TimeInterval
    ) {
        self.id = id
        self.stage = stage
        self.agent = agent
        self.aiToolName = aiToolName
        self.startedAt = startedAt
        self.status = status
        self.durationSeconds = durationSeconds
    }

    var formattedDuration: String {
        if durationSeconds < 60 {
            return "\(Int(durationSeconds))s"
        } else {
            let minutes = Int(durationSeconds) / 60
            let seconds = Int(durationSeconds) % 60
            return "\(minutes)m\(String(format: "%02d", seconds))s"
        }
    }
}

struct PipelineCycleTimelineEntry: Identifiable, Equatable {
    let id: String
    let stage: String
    let agent: String
    let aiToolName: String
    let status: String
    let startedAt: String?
    let durationSeconds: TimeInterval?

    var startedAtDate: Date? {
        guard let startedAt else { return nil }
        return PipelineCycleTimelineEntry.rfc3339Formatter.date(from: startedAt)
            ?? PipelineCycleTimelineEntry.rfc3339FallbackFormatter.date(from: startedAt)
    }

    private static let rfc3339Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let rfc3339FallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

struct PipelineCycleDetailPayload: Identifiable, Equatable {
    let id: String
    let cycleID: String
    let title: String
    let round: Int
    let status: String?
    let startTimeText: String
    let totalDurationText: String?
    let terminalReasonCode: String?
    let terminalErrorMessage: String?
    let timelineEntries: [PipelineCycleTimelineEntry]
}

struct PipelineCycleHistory: Identifiable, Equatable {
    let id: String
    let title: String?
    let round: Int
    let stages: [String]
    /// 循环开始时间
    let startDate: Date
    /// 每个阶段的详细记录（含运行时长）
    let stageEntries: [PipelineCycleStageEntry]
    /// 终止原因码
    let terminalReasonCode: String?
    /// 终止错误详情
    let terminalErrorMessage: String?

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    init(
        id: String,
        title: String? = nil,
        round: Int,
        stages: [String],
        startDate: Date,
        stageEntries: [PipelineCycleStageEntry],
        terminalReasonCode: String? = nil,
        terminalErrorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.round = round
        self.stages = stages
        self.startDate = startDate
        self.stageEntries = stageEntries
        self.terminalReasonCode = terminalReasonCode
        self.terminalErrorMessage = terminalErrorMessage
    }
}

// MARK: - 横向换行布局（待命胶囊专用）

/// 简易 Flow Layout：子视图横向排列，空间不足时自动换行
struct StandbyFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(rows.count - 1) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct RowItem {
        let index: Int
        let size: CGSize
    }
    private struct Row {
        var items: [RowItem] = []
        var height: CGFloat = 0
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]
        var currentWidth: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = currentWidth == 0 ? size.width : currentWidth + spacing + size.width
            if needed > maxWidth && currentWidth > 0 {
                rows.append(Row())
                currentWidth = 0
            }
            rows[rows.count - 1].items.append(RowItem(index: index, size: size))
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            currentWidth = currentWidth == 0 ? size.width : currentWidth + spacing + size.width
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

#endif
