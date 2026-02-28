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
                    Section {
                        let workspaces = appState.workspacesForProject(project.name)
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
                            ForEach(workspaces, id: \.name) { workspace in
                                NavigationLink(value: MobileRoute.workspaceDetail(
                                    project: project.name,
                                    workspace: workspace.name
                                )) {
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
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(.headline)
                            if !project.root.isEmpty {
                                Text(project.root)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
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
}

private struct MobileImplementAgentDraft: Identifiable {
    let id: String
    let lane: String
    var aiTool: AIChatTool
    var mode: String
    var providerID: String
    var modelID: String
    var configOptions: [String: Any]
}

struct MobileSettingsView: View {
    @EnvironmentObject var appState: MobileAppState
    @State private var drafts: [MobileImplementAgentDraft] = []

    var body: some View {
        Form {
            ForEach($drafts) { $draft in
                Section(implementLaneTitle(draft.lane)) {
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
        .navigationTitle("实现代理设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            drafts = buildDrafts()
            _ = appState.requestAISelectorResourcesForSettings()
        }
        .onReceive(appState.$evolutionImplementAgentProfiles) { _ in
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

    private func implementLaneTitle(_ lane: String) -> String {
        switch lane {
        case "general": return "通用实现"
        case "visual": return "视觉实现"
        case "advanced": return "高级实现"
        default: return lane
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

    private func selectedModelDisplayName(for draft: MobileImplementAgentDraft) -> String {
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
        appState.aiSessionConfigOptions(for: tool).first(where: {
            let category = ($0.category ?? $0.optionID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return category == "thought_level"
        })?.optionID
    }

    private func selectedThoughtLevel(for draft: MobileImplementAgentDraft) -> String? {
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

    private func buildDrafts() -> [MobileImplementAgentDraft] {
        let profiles = appState.evolutionImplementAgentProfiles
        let items: [(id: String, profile: EvolutionImplementAgentProfileInfoV2)] = [
            ("general", profiles.general),
            ("visual", profiles.visual),
            ("advanced", profiles.advanced)
        ]
        return items.map { item in
            MobileImplementAgentDraft(
                id: item.id,
                lane: item.id,
                aiTool: item.profile.aiTool,
                mode: item.profile.mode ?? "",
                providerID: item.profile.model?.providerID ?? "",
                modelID: item.profile.model?.modelID ?? "",
                configOptions: item.profile.configOptions
            )
        }
    }

    private func persistDrafts() {
        func toProfile(_ draft: MobileImplementAgentDraft) -> EvolutionImplementAgentProfileInfoV2 {
            let mode = draft.mode.trimmingCharacters(in: .whitespacesAndNewlines)
            let model: EvolutionModelSelectionV2? = {
                guard !draft.providerID.isEmpty, !draft.modelID.isEmpty else { return nil }
                return EvolutionModelSelectionV2(
                    providerID: draft.providerID,
                    modelID: draft.modelID
                )
            }()
            return EvolutionImplementAgentProfileInfoV2(
                aiTool: draft.aiTool,
                mode: mode.isEmpty ? nil : mode,
                model: model,
                configOptions: draft.configOptions
            )
        }

        let general = drafts.first(where: { $0.lane == "general" }).map(toProfile)
            ?? EvolutionImplementAgentProfileInfoV2()
        let visual = drafts.first(where: { $0.lane == "visual" }).map(toProfile)
            ?? EvolutionImplementAgentProfileInfoV2()
        let advanced = drafts.first(where: { $0.lane == "advanced" }).map(toProfile)
            ?? EvolutionImplementAgentProfileInfoV2()

        appState.evolutionImplementAgentProfiles = EvolutionImplementAgentProfilesV2(
            general: general,
            visual: visual,
            advanced: advanced
        )
        appState.saveClientSettings()
    }
}
