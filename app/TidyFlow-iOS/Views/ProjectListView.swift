import SwiftUI

/// 项目列表视图
struct ProjectListView: View {
    @EnvironmentObject var appState: MobileAppState

    var body: some View {
        List {
            if appState.sortedProjectsForSidebar.isEmpty {
                ContentUnavailableView("暂无项目", systemImage: "folder")
            } else {
                ForEach(appState.sortedProjectsForSidebar, id: \.name) { project in
                    let workspaces = appState.workspacesForProject(project.name)
                    let primaryWorkspace = appState.defaultWorkspaceForProject(project.name) ?? workspaces.first
                    let visibleWorkspaces = appState.sidebarVisibleWorkspacesForProject(project.name)
                    Section {
                        if workspaces.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.85)
                                Text("加载工作空间中...")
                                    .foregroundColor(.secondary)
                            }
                            .onAppear {
                                appState.requestWorkspacesIfNeeded(project: project.name)
                            }
                        } else {
                            ForEach(visibleWorkspaces, id: \.name) { workspace in
                                NavigationLink(value: MobileRoute.workspaceDetail(
                                    project: project.name,
                                    workspace: workspace.name
                                )) {
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(workspace.name)
                                                .font(.body)
                                            HStack(spacing: 8) {
                                                Text(workspace.branch)
                                                Text(workspace.status)
                                            }
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        let indicators = workspaceActivityIndicators(
                                            project: project.name,
                                            workspace: workspace.name
                                        )
                                        if !indicators.isEmpty {
                                            MobileWorkspaceActivityIconsView(indicators: indicators)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    } header: {
                        projectHeader(project: project, primaryWorkspace: primaryWorkspace, loading: workspaces.isEmpty)
                    }
                }
            }
        }
        .navigationTitle("项目")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.navigationPath.append(MobileRoute.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .refreshable {
            appState.refreshProjectTree()
        }
        .onAppear {
            appState.refreshProjectTree()
        }
    }

    @ViewBuilder
    private func projectHeader(project: ProjectInfo, primaryWorkspace: WorkspaceInfo?, loading: Bool) -> some View {
        if let primaryWorkspace {
            Button {
                appState.navigationPath.append(
                    MobileRoute.workspaceDetail(project: project.name, workspace: primaryWorkspace.name)
                )
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.headline)
                            .foregroundColor(.primary)
                        if !project.root.isEmpty {
                            Text(project.root)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    let indicators = workspaceActivityIndicators(
                        project: project.name,
                        workspace: primaryWorkspace.name
                    )
                    if !indicators.isEmpty {
                        MobileWorkspaceActivityIconsView(indicators: indicators)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.headline)
                    if !project.root.isEmpty {
                        Text(project.root)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if loading {
                    ProgressView()
                        .scaleEffect(0.75)
                }
            }
            .contentShape(Rectangle())
            .onAppear {
                if loading {
                    appState.requestWorkspacesIfNeeded(project: project.name)
                }
            }
        }
    }

    private func workspaceActivityIndicators(project: String, workspace: String) -> [MobileWorkspaceActivityIndicator] {
        var items: [MobileWorkspaceActivityIndicator] = []
        if let status = appState.workspaceAIStatus(project: project, workspace: workspace) {
            switch status.normalizedStatus {
            case "running":
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "bolt.circle.fill"))
            case "awaiting_input":
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "hourglass.circle.fill"))
            case "success":
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "checkmark.circle.fill"))
            case "failure", "error":
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "xmark.octagon.fill"))
            case "cancelled":
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "minus.circle.fill"))
            default:
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "bubble.left.and.bubble.right.fill"))
            }
        }
        if appState.hasWorkspaceActiveEvolutionLoop(project: project, workspace: workspace) {
            items.append(MobileWorkspaceActivityIndicator(id: "evolution", iconName: "brain.head.profile"))
        }
        if let taskIcon = appState.activeTaskIconForWorkspace(project: project, workspace: workspace) {
            items.append(MobileWorkspaceActivityIndicator(id: "task", iconName: taskIcon))
        }
        return items
    }
}

private struct MobileWorkspaceActivityIndicator: Identifiable {
    let id: String
    let iconName: String
}

private struct MobileWorkspaceActivityIconsView: View {
    let indicators: [MobileWorkspaceActivityIndicator]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(indicators) { indicator in
                MobileCommandIconView(iconName: indicator.iconName, size: 11)
                    .foregroundColor(.secondary)
                    .frame(width: 12, height: 12)
            }
        }
    }
}

private struct MobileEvolutionDefaultDraft: Identifiable {
    let id: String
    let stage: String
    var aiTool: AIChatTool
    var mode: String
    var providerID: String
    var modelID: String
    var configOptions: [String: Any]
}

struct MobileSettingsView: View {
    @EnvironmentObject var appState: MobileAppState
    @State private var drafts: [MobileEvolutionDefaultDraft] = []

    var body: some View {
        Form {
            ForEach($drafts) { $draft in
                Section(stageDisplayName(draft.stage)) {
                    LabeledContent("AI 工具") {
                        Picker("", selection: Binding<AIChatTool>(
                            get: { draft.aiTool },
                            set: { newValue in
                                draft.aiTool = newValue
                                draft.mode = ""
                                draft.providerID = ""
                                draft.modelID = ""
                                draft.configOptions = [:]
                                persistDrafts()
                            }
                        )) {
                            ForEach(AIChatTool.allCases) { tool in
                                Text(tool.displayName).tag(tool)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    LabeledContent("模式") {
                        Menu {
                            Button("默认") {
                                draft.mode = ""
                                persistDrafts()
                            }
                            let options = modeOptions(for: draft.aiTool)
                            if options.isEmpty {
                                Text("暂无可选模式")
                            } else {
                                ForEach(options, id: \.self) { option in
                                    Button(option) {
                                        draft.mode = option
                                        persistDrafts()
                                    }
                                }
                            }
                        } label: {
                            Text(draft.mode.isEmpty ? "默认" : draft.mode)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    LabeledContent("模型") {
                        Menu {
                            Button("默认") {
                                draft.providerID = ""
                                draft.modelID = ""
                                persistDrafts()
                            }
                            let providers = modelProviders(for: draft.aiTool)
                            if providers.isEmpty {
                                Text("暂无模型")
                            } else if providers.count == 1, let only = providers.first {
                                ForEach(only.models) { model in
                                    Button(model.name) {
                                        draft.providerID = only.id
                                        draft.modelID = model.id
                                        persistDrafts()
                                    }
                                }
                            } else {
                                ForEach(providers) { provider in
                                    Menu(provider.name) {
                                        ForEach(provider.models) { model in
                                            Button(model.name) {
                                                draft.providerID = provider.id
                                                draft.modelID = model.id
                                                persistDrafts()
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(selectedModelDisplayName(for: draft))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    LabeledContent("思考强度") {
                        Menu {
                            Button("默认") {
                                if let optionID = thoughtLevelOptionID(for: draft.aiTool) {
                                    draft.configOptions.removeValue(forKey: optionID)
                                    persistDrafts()
                                }
                            }
                            let options = appState.thoughtLevelOptions(for: draft.aiTool)
                            if options.isEmpty {
                                Text("暂无选项")
                            } else {
                                ForEach(options, id: \.self) { option in
                                    Button(option) {
                                        if let optionID = thoughtLevelOptionID(for: draft.aiTool) {
                                            draft.configOptions[optionID] = option
                                            persistDrafts()
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(selectedThoughtLevel(for: draft) ?? "默认")
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .navigationTitle("Evolution 代理设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            drafts = buildDrafts()
            _ = appState.requestAISelectorResourcesForSettings()
        }
        .onReceive(appState.$evolutionDefaultProfiles) { _ in
            drafts = buildDrafts()
        }
        .onChange(of: appState.isConnected) { _, connected in
            guard connected else { return }
            _ = appState.requestAISelectorResourcesForSettings()
        }
        .onChange(of: appState.projects.count) { _, _ in
            _ = appState.requestAISelectorResourcesForSettings()
        }
    }

    private func stageDisplayName(_ stage: String) -> String {
        switch stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "direction": return "Direction"
        case "plan": return "Plan"
        case "implement_general": return "Implement General"
        case "implement_visual": return "Implement Visual"
        case "implement_advanced": return "Implement Advanced"
        case "verify": return "Verify"
        case "judge": return "Judge"
        case "auto_commit": return "Auto Commit"
        case "implement": return "Implement General"
        default: return stage
        }
    }

    private func modeOptions(for tool: AIChatTool) -> [String] {
        var seen: Set<String> = []
        var values: [String] = []
        for agent in appState.settingsAgents(aiTool: tool) {
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard seen.insert(name).inserted else { continue }
            values.append(name)
        }
        return values
    }

    private func modelProviders(for tool: AIChatTool) -> [AIProviderInfo] {
        appState.settingsProviders(aiTool: tool).filter { !$0.models.isEmpty }
    }

    private func selectedModelDisplayName(for draft: MobileEvolutionDefaultDraft) -> String {
        guard !draft.providerID.isEmpty, !draft.modelID.isEmpty else { return "默认" }
        for provider in modelProviders(for: draft.aiTool) {
            if provider.id == draft.providerID,
               let model = provider.models.first(where: { $0.id == draft.modelID }) {
                return model.name
            }
        }
        return draft.modelID
    }

    private func thoughtLevelOptionID(for tool: AIChatTool) -> String? {
        appState.thoughtLevelOptionID(for: tool)
    }

    private func selectedThoughtLevel(for draft: MobileEvolutionDefaultDraft) -> String? {
        guard let optionID = thoughtLevelOptionID(for: draft.aiTool) else { return nil }
        let raw = draft.configOptions[optionID]
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = raw as? NSNumber {
            let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func buildDrafts() -> [MobileEvolutionDefaultDraft] {
        let profiles = appState.evolutionDefaultProfiles
        return profiles.map { profile in
            MobileEvolutionDefaultDraft(
                id: profile.stage,
                stage: profile.stage,
                aiTool: profile.aiTool,
                mode: profile.mode ?? "",
                providerID: profile.model?.providerID ?? "",
                modelID: profile.model?.modelID ?? "",
                configOptions: profile.configOptions
            )
        }
    }

    private func persistDrafts() {
        let profiles: [EvolutionStageProfileInfoV2] = drafts.map { draft in
            let mode = draft.mode.trimmingCharacters(in: .whitespacesAndNewlines)
            let model: EvolutionModelSelectionV2? = {
                guard !draft.providerID.isEmpty, !draft.modelID.isEmpty else { return nil }
                return EvolutionModelSelectionV2(
                    providerID: draft.providerID,
                    modelID: draft.modelID
                )
            }()
            return EvolutionStageProfileInfoV2(
                stage: draft.stage,
                aiTool: draft.aiTool,
                mode: mode.isEmpty ? nil : mode,
                model: model,
                configOptions: draft.configOptions
            )
        }
        appState.saveEvolutionDefaultProfiles(profiles)
    }
}
