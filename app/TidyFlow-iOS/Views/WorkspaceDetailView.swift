import SwiftUI

/// 工作空间详情页：终端、后台任务、代码变更汇总与工具栏操作。
struct WorkspaceDetailView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String

    private var terminals: [TerminalSessionInfo] {
        appState.terminalsForWorkspace(project: project, workspace: workspace)
    }

    private var runningTasks: [MobileWorkspaceTask] {
        appState.runningTasksForWorkspace(project: project, workspace: workspace)
    }

    private var allTasks: [MobileWorkspaceTask] {
        appState.tasksForWorkspace(project: project, workspace: workspace)
    }

    private var completedTaskCount: Int {
        allTasks.filter { !$0.status.isActive }.count
    }

    private var gitSummary: MobileWorkspaceGitSummary {
        appState.gitSummaryForWorkspace(project: project, workspace: workspace)
    }

    private var projectCommands: [ProjectCommand] {
        appState.projectCommands(for: project)
    }

    var body: some View {
        List {
            Section("代码变更") {
                HStack(spacing: 16) {
                    Label("+\(gitSummary.additions)", systemImage: "plus")
                        .foregroundColor(.green)
                    Label("-\(gitSummary.deletions)", systemImage: "minus")
                        .foregroundColor(.red)
                }
                .font(.headline)
                .padding(.vertical, 4)
            }

            Section("活跃终端") {
                if terminals.isEmpty {
                    Text("暂无活跃终端")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(terminals.enumerated()), id: \.element.termId) { index, term in
                        NavigationLink(value: MobileRoute.terminalAttach(
                            project: project,
                            workspace: workspace,
                            termId: term.termId
                        )) {
                            HStack(spacing: 10) {
                                let presentation = appState.terminalPresentation(for: term.termId)
                                MobileCommandIconView(
                                    iconName: presentation?.icon ?? "terminal",
                                    size: 18
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(presentation?.name ?? "终端 \(index + 1)")
                                        .font(.body)
                                    Text(String(term.termId.prefix(8)))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.closeTerminal(termId: term.termId)
                            } label: {
                                Label("终止", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }

            Section("后台任务") {
                if runningTasks.isEmpty {
                    Text("当前无进行中的后台任务")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(runningTasks) { task in
                        HStack(spacing: 10) {
                            MobileCommandIconView(iconName: task.icon, size: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                Text(task.message)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if appState.canCancelTask(task) {
                                Button {
                                    appState.cancelTask(task)
                                } label: {
                                    Image(systemName: "stop.circle")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            ProgressView()
                                .scaleEffect(0.9)
                        }
                        .padding(.vertical, 2)
                    }
                }

                NavigationLink(value: MobileRoute.workspaceTasks(project: project, workspace: workspace)) {
                    HStack {
                        Text("查看全部任务")
                        Spacer()
                        if completedTaskCount > 0 {
                            Text("\(completedTaskCount)")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.secondary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .navigationTitle(workspace)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                evolutionButton
                aiChatButton
                moreActionsMenu
            }
        }
        .refreshable {
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
        .onAppear {
            appState.refreshWorkspaceDetail(project: project, workspace: workspace)
        }
    }

    private var evolutionButton: some View {
        Button {
            appState.navigationPath.append(MobileRoute.evolution(project: project, workspace: workspace))
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
    }

    private var aiChatButton: some View {
        Button {
            appState.navigationPath.append(MobileRoute.aiChat(project: project, workspace: workspace))
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
        }
    }

    private var moreActionsMenu: some View {
        Menu {
            Menu("新建终端") {
                Button {
                    appState.navigationPath.append(MobileRoute.terminal(project: project, workspace: workspace))
                } label: {
                    Label("新建终端", systemImage: "terminal")
                }

                if !appState.customCommands.isEmpty {
                    Divider()
                    ForEach(appState.customCommands) { cmd in
                        Button {
                            appState.navigationPath.append(MobileRoute.terminal(
                                project: project,
                                workspace: workspace,
                                command: cmd.command,
                                commandIcon: cmd.icon,
                                commandName: cmd.name
                            ))
                        } label: {
                            Label {
                                Text(cmd.name)
                            } icon: {
                                MobileCommandIconView(iconName: cmd.icon, size: 14)
                            }
                        }
                    }
                }
            }

            Button {
                appState.runAICommit(project: project, workspace: workspace)
            } label: {
                Label("一键提交", systemImage: "sparkles")
            }

            Button {
                appState.runAIMerge(project: project, workspace: workspace)
            } label: {
                Label("智能合并", systemImage: "cpu")
            }

            Menu("执行") {
                if projectCommands.isEmpty {
                    Text("当前项目未配置命令")
                } else {
                    ForEach(projectCommands) { command in
                        Button {
                            appState.runProjectCommand(project: project, workspace: workspace, command: command)
                        } label: {
                            Label {
                                Text(command.name)
                            } icon: {
                                MobileCommandIconView(iconName: command.icon, size: 14)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

private struct EvolutionProfileDraft: Identifiable {
    let id: String
    let stage: String
    var aiTool: AIChatTool
    var mode: String
    var providerID: String
    var modelID: String
}

struct MobileEvolutionView: View {
    @EnvironmentObject var appState: MobileAppState

    let project: String
    let workspace: String

    @State private var maxVerifyIterationsText: String = "3"
    @State private var autoLoopEnabled: Bool = true
    @State private var profiles: [EvolutionProfileDraft] = []
    @State private var isApplyingRemoteProfiles: Bool = false
    @State private var lastSyncedProfileSignature: String = ""
    @State private var pendingProfileSaveSignature: String?
    @State private var pendingProfileSaveDate: Date?
    @StateObject private var replayStore = AIChatStore()

    private var item: EvolutionWorkspaceItemV2? {
        appState.evolutionItem(project: project, workspace: workspace)
    }

    var body: some View {
        List {
            Section("调度器状态") {
                LabeledContent("激活状态") {
                    Text(appState.evolutionScheduler.activationState)
                }
                LabeledContent("并发上限") {
                    Text("\(appState.evolutionScheduler.maxParallelWorkspaces)")
                }
                LabeledContent("运行中 / 排队") {
                    Text("\(appState.evolutionScheduler.runningCount) / \(appState.evolutionScheduler.queuedCount)")
                }
            }

            Section("工作空间控制") {
                LabeledContent("当前工作空间") {
                    Text("\(project)/\(workspace)")
                }
                if let item {
                    LabeledContent("状态") {
                        Text(item.status)
                    }
                    LabeledContent("当前阶段") {
                        Text(item.currentStage)
                    }
                    LabeledContent("轮次") {
                        Text("\(item.globalLoopRound)")
                    }
                    LabeledContent("校验轮次") {
                        Text("\(item.verifyIteration)/\(item.verifyIterationLimit)")
                    }
                    LabeledContent("活跃代理") {
                        Text(item.activeAgents.isEmpty ? "无" : item.activeAgents.joined(separator: ", "))
                            .lineLimit(1)
                    }
                } else {
                    Text("状态: 未启动")
                        .foregroundColor(.secondary)
                }

                LabeledContent("最大 verify 次数") {
                    TextField("3", text: $maxVerifyIterationsText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }

                Toggle("循环续轮", isOn: $autoLoopEnabled)
                Text(autoLoopEnabled ? "运行模式: 自动循环续轮" : "运行模式: 仅运行 1 轮后结束")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ControlGroup {
                    Button("手动启动") {
                        startEvolution()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("停止") {
                        appState.stopEvolution(project: project, workspace: workspace)
                    }
                    Button("恢复") {
                        appState.resumeEvolution(project: project, workspace: workspace)
                    }
                }
                .buttonStyle(.bordered)
            }

            Section("代理配置") {
                Text("进入页面自动拉取配置，切换 AI 工具 / 模式 / 模型后自动保存。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach($profiles) { $profile in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(profile.stage)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)

                        LabeledContent("AI 工具") {
                            Picker("AI 工具", selection: $profile.aiTool) {
                                ForEach(AIChatTool.allCases) { tool in
                                    Text(tool.displayName).tag(tool)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: profile.aiTool) { _, _ in
                                sanitizeProfileSelection(profileID: profile.id)
                                autoSaveProfilesIfNeeded()
                            }
                        }

                        LabeledContent("模式") {
                            Menu {
                                Button("默认模式") {
                                    profile.mode = ""
                                    autoSaveProfilesIfNeeded()
                                }
                                let options = modeOptions(for: profile.aiTool)
                                if options.isEmpty {
                                    Text("暂无可用模式")
                                } else {
                                    ForEach(options, id: \.self) { mode in
                                        Button(mode) {
                                            profile.mode = mode
                                            applyAgentDefaultModelIfAvailable(
                                                profileID: profile.id,
                                                agentName: mode
                                            )
                                            autoSaveProfilesIfNeeded()
                                        }
                                    }
                                }
                            } label: {
                                Text(profile.mode.isEmpty ? "默认模式" : profile.mode)
                                    .foregroundColor(.secondary)
                            }
                        }

                        LabeledContent("模型") {
                            Menu {
                                Button("默认模型") {
                                    profile.providerID = ""
                                    profile.modelID = ""
                                    autoSaveProfilesIfNeeded()
                                }
                                let providers = modelProviders(for: profile.aiTool)
                                if providers.isEmpty {
                                    Text("暂无可用模型")
                                } else if providers.count == 1 {
                                    if let onlyProvider = providers.first {
                                        ForEach(onlyProvider.models) { model in
                                            Button(model.name) {
                                                profile.providerID = onlyProvider.id
                                                profile.modelID = model.id
                                                autoSaveProfilesIfNeeded()
                                            }
                                        }
                                    }
                                } else {
                                    ForEach(providers) { provider in
                                        Menu(provider.name) {
                                            ForEach(provider.models) { model in
                                                Button(model.name) {
                                                    profile.providerID = provider.id
                                                    profile.modelID = model.id
                                                    autoSaveProfilesIfNeeded()
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Text(selectedModelDisplayName(for: profile))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("代理列表") {
                if let item {
                    ForEach(item.agents, id: \.stage) { agent in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.stage)
                                    .font(.system(.body, design: .monospaced))
                                Text(agent.agent)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(agent.status)
                                .foregroundColor(agent.status == "running" ? .orange : .secondary)
                            Button("聊天") {
                                appState.openEvolutionStageChat(
                                    project: item.project,
                                    workspace: item.workspace,
                                    cycleId: item.cycleID,
                                    stage: agent.stage
                                )
                            }
                            .disabled(!(agent.status == "running" || agent.status == "done"))
                        }
                    }
                } else {
                    Text("当前工作空间暂无轮次")
                        .foregroundColor(.secondary)
                }
            }

            if appState.evolutionReplayLoading ||
                !appState.evolutionReplayMessages.isEmpty ||
                appState.evolutionReplayError != nil {
                Section("阶段聊天") {
                    if appState.evolutionReplayLoading {
                        ProgressView("加载聊天记录中...")
                    } else if let error = appState.evolutionReplayError, !error.isEmpty {
                        Text(error)
                            .foregroundColor(.red)
                    } else {
                        MessageListView(
                            messages: appState.evolutionReplayMessages,
                            onQuestionReply: { _, _ in },
                            onQuestionReject: { _ in },
                            onQuestionReplyAsMessage: { _ in }
                        )
                        .environmentObject(replayStore)
                        .frame(minHeight: 320)
                    }
                    Button("关闭聊天") {
                        appState.clearEvolutionReplay()
                    }
                }
            }
        }
        .navigationTitle("自主进化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") {
                    appState.refreshEvolution(project: project, workspace: workspace)
                    loadProfiles()
                }
            }
        }
        .onAppear {
            appState.openEvolution(project: project, workspace: workspace)
            loadProfiles()
            syncStartOptionsFromItem()
        }
        .onReceive(appState.$evolutionStageProfilesByWorkspace) { _ in
            loadProfiles()
        }
        .onReceive(appState.$evolutionWorkspaceItems) { _ in
            syncStartOptionsFromItem()
        }
        .onReceive(appState.$evolutionReplayMessages) { messages in
            replayStore.replaceMessages(messages)
        }
    }

    private func loadProfiles() {
        let values = appState.evolutionProfiles(project: project, workspace: workspace)
        let loadedProfiles = values.map { profile in
            EvolutionProfileDraft(
                id: profile.stage,
                stage: profile.stage,
                aiTool: profile.aiTool,
                mode: profile.mode ?? "",
                providerID: profile.model?.providerID ?? "",
                modelID: profile.model?.modelID ?? ""
            )
        }
        let incomingSignature = profileSignature(loadedProfiles)
        if shouldIgnoreIncomingProfiles(signature: incomingSignature) {
            return
        }

        isApplyingRemoteProfiles = true
        profiles = loadedProfiles
        let profileIDs = profiles.map(\.id)
        for id in profileIDs {
            sanitizeProfileSelection(profileID: id)
        }
        lastSyncedProfileSignature = profileSignature(profiles)
        if pendingProfileSaveSignature == lastSyncedProfileSignature {
            pendingProfileSaveSignature = nil
            pendingProfileSaveDate = nil
        }
        DispatchQueue.main.async {
            isApplyingRemoteProfiles = false
        }
    }

    private func modeOptions(for tool: AIChatTool) -> [String] {
        // 与 macOS 端保持一致：mode 选项来自 agent.name。
        var seen: Set<String> = []
        var values: [String] = []
        for agent in appState.evolutionAgents(project: project, workspace: workspace, aiTool: tool) {
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard seen.insert(name).inserted else { continue }
            values.append(name)
        }
        return values
    }

    private func applyAgentDefaultModelIfAvailable(profileID: String, agentName: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var profile = profiles[index]
        let target = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        let agent = appState.evolutionAgents(project: project, workspace: workspace, aiTool: profile.aiTool)
            .first { info in
                info.name == target || info.name.caseInsensitiveCompare(target) == .orderedSame
            }
        guard let agent,
              let providerID = agent.defaultProviderID,
              let modelID = agent.defaultModelID,
              !providerID.isEmpty,
              !modelID.isEmpty else { return }

        profile.providerID = providerID
        profile.modelID = modelID
        profiles[index] = profile
    }

    private func modelProviders(for tool: AIChatTool) -> [AIProviderInfo] {
        appState.evolutionProviders(project: project, workspace: workspace, aiTool: tool)
            .filter { !$0.models.isEmpty }
    }

    private func selectedModelDisplayName(for profile: EvolutionProfileDraft) -> String {
        guard !profile.providerID.isEmpty, !profile.modelID.isEmpty else {
            return "默认模型"
        }
        for provider in modelProviders(for: profile.aiTool) {
            if provider.id == profile.providerID,
               let model = provider.models.first(where: { $0.id == profile.modelID }) {
                return model.name
            }
        }
        return profile.modelID
    }

    private func sanitizeProfileSelection(profileID: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var profile = profiles[index]

        if !profile.mode.isEmpty {
            let modes = modeOptions(for: profile.aiTool)
            if !modes.isEmpty, !modes.contains(profile.mode) {
                profile.mode = ""
            }
        }

        if !profile.providerID.isEmpty || !profile.modelID.isEmpty {
            let providers = modelProviders(for: profile.aiTool)
            let modelExists = providers.contains { provider in
                provider.id == profile.providerID &&
                    provider.models.contains(where: { $0.id == profile.modelID })
            }
            if !providers.isEmpty, !modelExists {
                profile.providerID = ""
                profile.modelID = ""
            }
        }

        profiles[index] = profile
    }

    private func buildStageProfilesForSubmit() -> [EvolutionStageProfileInfoV2] {
        profiles.map { profile in
            var mode: String?
            if !profile.mode.isEmpty {
                let modes = modeOptions(for: profile.aiTool)
                if modes.isEmpty || modes.contains(profile.mode) {
                    mode = profile.mode
                }
            }

            let model: EvolutionModelSelectionV2? = {
                guard !profile.providerID.isEmpty, !profile.modelID.isEmpty else { return nil }
                let providers = modelProviders(for: profile.aiTool)
                if providers.isEmpty {
                    return EvolutionModelSelectionV2(providerID: profile.providerID, modelID: profile.modelID)
                }
                let exists = providers.contains { provider in
                    provider.id == profile.providerID &&
                        provider.models.contains(where: { $0.id == profile.modelID })
                }
                guard exists else { return nil }
                return EvolutionModelSelectionV2(providerID: profile.providerID, modelID: profile.modelID)
            }()

            return EvolutionStageProfileInfoV2(
                stage: profile.stage,
                aiTool: profile.aiTool,
                mode: mode,
                model: model
            )
        }
    }

    private func saveProfiles() {
        let values = buildStageProfilesForSubmit()
        appState.updateEvolutionAgentProfile(project: project, workspace: workspace, profiles: values)
    }

    private func autoSaveProfilesIfNeeded() {
        guard !isApplyingRemoteProfiles else { return }
        let signature = profileSignature(profiles)
        guard signature != lastSyncedProfileSignature else { return }
        guard signature != pendingProfileSaveSignature else { return }
        pendingProfileSaveSignature = signature
        pendingProfileSaveDate = Date()
        saveProfiles()
    }

    private func shouldIgnoreIncomingProfiles(signature: String) -> Bool {
        guard let pending = pendingProfileSaveSignature else { return false }
        guard pending != signature else { return false }

        let timeout: TimeInterval = 3
        if let date = pendingProfileSaveDate, Date().timeIntervalSince(date) < timeout {
            return true
        }

        pendingProfileSaveSignature = nil
        pendingProfileSaveDate = nil
        return false
    }

    private func profileSignature(_ values: [EvolutionProfileDraft]) -> String {
        values
            .sorted { $0.stage < $1.stage }
            .map {
                [
                    $0.stage,
                    $0.aiTool.rawValue,
                    $0.mode,
                    $0.providerID,
                    $0.modelID
                ].joined(separator: "::")
            }
            .joined(separator: "||")
    }

    private func startEvolution() {
        let verify = max(1, Int(maxVerifyIterationsText) ?? 3)
        let values = buildStageProfilesForSubmit()
        appState.startEvolution(
            project: project,
            workspace: workspace,
            maxVerifyIterations: verify,
            autoLoopEnabled: autoLoopEnabled,
            profiles: values
        )
    }

    private func syncStartOptionsFromItem() {
        guard let item else { return }
        autoLoopEnabled = item.autoLoopEnabled
    }
}
