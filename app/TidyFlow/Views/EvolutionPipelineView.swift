import SwiftUI

#if os(macOS)

// MARK: - 进化流水线视图（右侧面板）

/// 自主进化的流水线视图，显示在右侧 Inspector 面板中
/// 聚焦当前轮次执行流程，以流水线动画展示代理执行状态
struct EvolutionPipelineView: View {
    @EnvironmentObject var appState: AppState

    // MARK: - 本地状态

    @State private var loopRoundLimit: Int = 3
    @State private var isSessionViewerPresented: Bool = false
    @State private var isBlockerSheetPresented: Bool = false
    @State private var isHandoffSheetPresented: Bool = false
    @State private var blockerDrafts: [String: EvolutionPipelineBlockerDraft] = [:]

    /// 已完成代理的时间线记录（本轮）
    @State private var completedTimeline: [PipelineTimelineEntry] = []
    /// 历史循环汇总（每轮结束后的合并记录）
    @State private var cycleHistories: [PipelineCycleHistory] = []
    /// 上次记录的轮次
    @State private var lastRecordedRound: Int = 0
    /// 运行计时器
    @State private var runningElapsed: TimeInterval = 0
    @State private var runningStartDate: Date? = nil
    @State private var timerActive: Bool = false

    private struct EvolutionPipelineBlockerDraft {
        var selected: Bool
        var selectedOptionID: String
        var answerText: String
    }

    // MARK: - 便捷属性

    private var project: String { appState.selectedProjectName }
    private var workspace: String? { appState.selectedWorkspaceKey }
    private var workspaceReady: Bool { workspace != nil && !(workspace ?? "").isEmpty }

    private var currentItem: EvolutionWorkspaceItemV2? {
        guard let workspace else { return nil }
        return appState.evolutionItem(project: project, workspace: workspace)
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

    private let loopRoundOptions = [3, 5, 10, 20]

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
                        controlSection
                        runningAgentSection
                        standbySection
                        completedTimelineSection
                        cycleHistorySection
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
        #if os(macOS)
        .sheet(isPresented: $isSessionViewerPresented) {
            EvolutionSessionDrawerView(isSessionViewerPresented: $isSessionViewerPresented)
                .environmentObject(appState)
                .frame(minWidth: 400, minHeight: 500)
        }
        #endif
        .sheet(isPresented: $isBlockerSheetPresented) {
            blockerSheet
        }
        .sheet(isPresented: $isHandoffSheetPresented) {
            handoffSheet
        }
    }

    // MARK: - 标题栏

    private var pipelineHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.linearGradient(
                    colors: [.purple, .blue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text("evolution.page.title".localized)
                .font(.system(size: 12, weight: .semibold))
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
                .pickerStyle(.menu)
                .frame(maxWidth: 100)
                .controlSize(.small)

                Spacer(minLength: 4)

                // 操作按钮
                HStack(spacing: 4) {
                    Button {
                        startCurrentWorkspace()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("evolution.page.action.startManual".localized)

                    Button {
                        guard let workspace else { return }
                        appState.stopEvolution(project: project, workspace: workspace)
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("evolution.page.action.stop".localized)

                    Button {
                        guard let workspace else { return }
                        appState.resumeEvolution(project: project, workspace: workspace)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("evolution.page.action.resume".localized)

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
                    sectionLabel("evolution.page.pipeline.running".localized, icon: "bolt.fill", color: .orange)

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

                // 运行时间
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(formatElapsedTime())
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
        .onAppear {
            if runningStartDate == nil {
                runningStartDate = Date()
            }
        }
    }

    // MARK: - 待命队列

    private var standbySection: some View {
        let standbyAgents = computeStandbyAgents()

        return Group {
            if !standbyAgents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("evolution.page.pipeline.standby".localized, icon: "clock", color: .secondary)

                    ForEach(standbyAgents, id: \.stage) { agent in
                        standbyAgentRow(agent)
                            .transition(.opacity.combined(with: .slide))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: standbyAgents.map(\.stage))
            }
        }
    }

    private func standbyAgentRow(_ agent: PipelineStandbyAgent) -> some View {
        HStack(spacing: 8) {
            // 连接线指示
            Circle()
                .fill(stageColor(agent.stage).opacity(0.4))
                .frame(width: 6, height: 6)

            Image(systemName: stageIconName(agent.stage))
                .font(.system(size: 11))
                .foregroundColor(stageColor(agent.stage))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(stageColor(agent.stage).opacity(0.1))
                )

            Text(stageDisplayName(agent.stage))
                .font(.system(size: 11))
                .lineLimit(1)

            Spacer()

            if agent.isLoopable {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
                    .help("evolution.page.pipeline.loopable".localized)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    // MARK: - 已完成时间线

    private var completedTimelineSection: some View {
        return Group {
            if !completedTimeline.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("evolution.page.pipeline.completed".localized, icon: "checkmark.circle.fill", color: .green)

                    ForEach(Array(completedTimeline.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 8) {
                            // 时间线竖线 + 节点
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

                            // 查看聊天按钮
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
        }
    }

    // MARK: - 历史循环汇总

    private var cycleHistorySection: some View {
        return Group {
            if !cycleHistories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("evolution.page.pipeline.history".localized, icon: "clock.arrow.circlepath", color: .indigo)

                    ForEach(cycleHistories) { cycle in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "evolution.page.pipeline.roundLabel".localized, cycle.round))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)

                            // 彩色横线：每个代理为一段
                            HStack(spacing: 2) {
                                ForEach(cycle.stages, id: \.self) { stage in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(stageColor(stage))
                                        .frame(height: 6)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .clipShape(Capsule())
                        }
                        .padding(.horizontal, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .animation(.easeInOut(duration: 0.5), value: cycleHistories.count)
            }
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

    private func formatElapsedTime() -> String {
        guard let start = runningStartDate else { return "0s" }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 60 {
            return "\(Int(elapsed))s"
        } else {
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            return "\(minutes)m\(String(format: "%02d", seconds))s"
        }
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
            guard stage != "auto_commit" else { continue }
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

        // 检测轮次变化，如果轮次增加，将当前时间线归档为历史
        if item.globalLoopRound > lastRecordedRound && lastRecordedRound > 0 && !completedTimeline.isEmpty {
            let stages = completedTimeline.map(\.stage)
            cycleHistories.append(PipelineCycleHistory(
                id: UUID().uuidString,
                round: lastRecordedRound,
                stages: stages
            ))
            completedTimeline.removeAll()
        }
        lastRecordedRound = item.globalLoopRound

        // 更新已完成代理
        let agents = item.agents
        let completedAgents = agents.filter { isCompletedStatus(normalizedStageStatus($0.status)) }
        let existingStages = Set(completedTimeline.map(\.stage))

        for agent in completedAgents {
            let key = normalizedStageKey(agent.stage)
            if !existingStages.contains(key) {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                completedTimeline.append(PipelineTimelineEntry(
                    id: UUID().uuidString,
                    stage: key,
                    agent: agent.agent,
                    toolCallCount: agent.toolCallCount,
                    completedAt: formatter.string(from: Date())
                ))
            }
        }

        // 更新运行计时器
        let hasRunning = agents.contains { normalizedStageStatus($0.status) == "running" }
        if hasRunning && runningStartDate == nil {
            runningStartDate = Date()
        } else if !hasRunning {
            runningStartDate = nil
        }
    }

    private func resetLocalTimeline() {
        completedTimeline.removeAll()
        cycleHistories.removeAll()
        lastRecordedRound = 0
        runningStartDate = nil
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
        isSessionViewerPresented = true
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

    private func startCurrentWorkspace() {
        guard let workspace else { return }
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

    private func refreshData() {
        appState.requestEvolutionSnapshot()
    }

    private func syncStartOptions() {
        guard let item = currentItem else {
            loopRoundLimit = 3
            return
        }
        loopRoundLimit = max(1, item.loopRoundLimit)
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

    private func isCompletedStatus(_ status: String) -> Bool {
        ["completed", "done", "success", "succeeded", "已完成", "完成"].contains(status)
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
}

struct PipelineCycleHistory: Identifiable, Equatable {
    let id: String
    let round: Int
    let stages: [String]
}

#endif
