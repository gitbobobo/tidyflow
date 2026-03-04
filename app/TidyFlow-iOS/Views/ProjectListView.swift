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

    private func workspaceActivityIndicators(project: String, workspace: String) -> [MobileWorkspaceActivityIndicator] {
        var items: [MobileWorkspaceActivityIndicator] = []
        if let status = appState.workspaceAIStatus(project: project, workspace: workspace) {
            switch status.normalizedStatus {
            case "running":
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "bolt.circle.fill", color: .blue))
            case "awaiting_input":
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "hourglass.circle.fill", color: .yellow))
            case "success":
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "checkmark.circle.fill", color: .green))
            case "failure", "error":
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "xmark.octagon.fill", color: .red))
            case "cancelled":
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "minus.circle.fill", color: .secondary))
            default:
                items.append(MobileWorkspaceActivityIndicator(id: "chat", iconName: "bubble.left.and.bubble.right.fill", color: .secondary))
            }
        }
        if appState.hasWorkspaceActiveEvolutionLoop(project: project, workspace: workspace) {
            items.append(MobileWorkspaceActivityIndicator(id: "evolution", iconName: "brain.head.profile", color: .purple))
        }
        if let taskIcon = appState.activeTaskIconForWorkspace(project: project, workspace: workspace) {
            items.append(MobileWorkspaceActivityIndicator(id: "task", iconName: taskIcon, color: .secondary))
        }
        return items
    }
}

private struct MobileWorkspaceActivityIndicator: Identifiable {
    let id: String
    let iconName: String
    let color: Color
}

private struct MobileWorkspaceActivityIconsView: View {
    let indicators: [MobileWorkspaceActivityIndicator]

    var body: some View {
        indicatorIcons(maskStyle: false)
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: indicators.isEmpty)) { timeline in
                    GeometryReader { proxy in
                        let cycle = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.8) / 1.8
                        let width = max(8, proxy.size.width * 0.45)
                        let offset = (cycle * 1.6 - 0.3) * proxy.size.width
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.85),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: width, height: proxy.size.height * 1.6)
                        .rotationEffect(.degrees(16))
                        .offset(x: offset, y: -proxy.size.height * 0.3)
                    }
                }
                .mask(indicatorIcons(maskStyle: true))
                .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private func indicatorIcons(maskStyle: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(indicators) { indicator in
                MobileCommandIconView(iconName: indicator.iconName, size: 11)
                    .foregroundColor(maskStyle ? .white : indicator.color)
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
        case "report": return "Report"
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
        appState.aiSessionConfigOptions(for: tool).first(where: {
            let category = ($0.category ?? $0.optionID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return category == "thought_level"
        })?.optionID
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
