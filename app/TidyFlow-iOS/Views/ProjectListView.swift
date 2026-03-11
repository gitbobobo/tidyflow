import SwiftUI

/// 项目列表视图
struct ProjectListView: View {
    let appState: MobileAppState
    @StateObject private var projectionStore = MobileSidebarProjectionStore()

    var body: some View {
        let _ = Self.debugPrintChangesIfNeeded()
        List {
            if projectionStore.projects.isEmpty && appState.projects.isEmpty {
                ContentUnavailableView("暂无项目", systemImage: "folder")
            } else {
                ForEach(displayedProjects) { project in
                    Section {
                        if project.isLoadingWorkspaces {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.85)
                                Text("加载工作空间中...")
                                    .foregroundColor(.secondary)
                            }
                            .onAppear {
                                appState.requestWorkspacesIfNeeded(project: project.projectName)
                            }
                        } else {
                            ForEach(project.visibleWorkspaces) { workspace in
                                NavigationLink(value: MobileRoute.workspaceDetail(
                                    project: project.projectName,
                                    workspace: workspace.workspaceName
                                )) {
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(workspace.workspaceName)
                                                .font(.body)
                                            HStack(spacing: 8) {
                                                if let branch = workspace.branch, !branch.isEmpty {
                                                    Text(branch)
                                                }
                                                if let statusText = workspace.statusText, !statusText.isEmpty {
                                                    Text(statusText)
                                                }
                                            }
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        if !workspace.activityIndicators.isEmpty {
                                            MobileWorkspaceActivityIconsView(indicators: workspace.activityIndicators)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .contextMenu {
                                    if let path = workspace.workspacePath, !path.isEmpty {
                                        Button {
                                            appState.copySidebarPath(path)
                                        } label: {
                                            Label("sidebar.copyPath".localized, systemImage: "doc.on.doc")
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        projectHeader(project: project)
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
        .task {
            projectionStore.bind(appState: appState)
            appState.refreshProjectTree()
        }
        .tfRenderProbe("ProjectListView", metadata: [
            "project_count": String(displayedProjects.count)
        ])
        .tfHotspotBaseline(
            .iosProjectList,
            renderProbeName: "ProjectListView",
            metadata: ["project_count": String(displayedProjects.count)]
        )
    }

    private var displayedProjects: [SidebarProjectProjection] {
        if !projectionStore.projects.isEmpty {
            return projectionStore.projects
        }
        return SidebarProjectionSemantics.buildMobileProjects(appState: appState)
    }

    @ViewBuilder
    private func projectHeader(project: SidebarProjectProjection) -> some View {
        Group {
            if let primaryWorkspaceName = project.primaryWorkspaceName {
                Button {
                    appState.navigationPath.append(
                        MobileRoute.workspaceDetail(project: project.projectName, workspace: primaryWorkspaceName)
                    )
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.projectName)
                                .font(.headline)
                                .foregroundColor(.primary)
                            if let projectPath = project.projectPath, !projectPath.isEmpty {
                                Text(projectPath)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if !project.activityIndicators.isEmpty {
                            MobileWorkspaceActivityIconsView(indicators: project.activityIndicators)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.projectName)
                            .font(.headline)
                        if let projectPath = project.projectPath, !projectPath.isEmpty {
                            Text(projectPath)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if project.isLoadingWorkspaces {
                        ProgressView()
                            .scaleEffect(0.75)
                    } else if !project.activityIndicators.isEmpty {
                        MobileWorkspaceActivityIconsView(indicators: project.activityIndicators)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onAppear {
                    if project.isLoadingWorkspaces {
                        appState.requestWorkspacesIfNeeded(project: project.projectName)
                    }
                }
            }
        }
        .contextMenu {
            if let projectPath = project.projectPath, !projectPath.isEmpty {
                Button {
                    appState.copySidebarPath(projectPath)
                } label: {
                    Label("sidebar.copyPath".localized, systemImage: "doc.on.doc")
                }
            }
        }
    }

    private static func debugPrintChangesIfNeeded() {
        SwiftUIPerformanceDebug.runPrintChangesIfEnabled(
            SwiftUIPerformanceDebug.projectListPrintChangesEnabled
        ) {
#if DEBUG
            Self._printChanges()
#endif
        }
    }
}

private struct MobileWorkspaceActivityIconsView: View {
    let indicators: [SidebarActivityIndicatorProjection]

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
    @State private var optionsStore = EvolutionProfileOptionsProjectionStore()

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
                                sanitizeModelVariantSelection(draft: &draft)
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
                                        sanitizeModelVariantSelection(draft: &draft)
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
                                                sanitizeModelVariantSelection(draft: &draft)
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

                    LabeledContent("模型变体") {
                        Menu {
                            Button("默认") {
                                if let optionID = modelVariantOptionID(for: draft.aiTool) {
                                    draft.configOptions.removeValue(forKey: optionID)
                                    persistDrafts()
                                }
                            }
                            let options = modelVariantOptions(for: draft)
                            if options.isEmpty {
                                Text("当前模型未提供可用变体")
                            } else {
                                ForEach(options, id: \.self) { option in
                                    Button(option) {
                                        if let optionID = modelVariantOptionID(for: draft.aiTool) {
                                            draft.configOptions[optionID] = option
                                            persistDrafts()
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(selectedModelVariant(for: draft) ?? "默认")
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
            optionsStore.bindSettings(appState: appState)
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
        EvolutionProfileOptionsProjectionSemantics.stageDisplayName(stage)
    }

    private func modeOptions(for tool: AIChatTool) -> [String] {
        optionsStore.options(for: tool).modeOptions
    }

    private func modelProviders(for tool: AIChatTool) -> [EvolutionProviderOptionProjection] {
        optionsStore.options(for: tool).providers
    }

    private func selectedModelDisplayName(for draft: MobileEvolutionDefaultDraft) -> String {
        optionsStore.selectedModelDisplayName(
            providerID: draft.providerID,
            modelID: draft.modelID,
            for: draft.aiTool,
            defaultLabel: "默认"
        )
    }

    private func modelVariantOptionID(for tool: AIChatTool) -> String? {
        optionsStore.modelVariantOptionID(for: tool)
    }

    private func modelVariantOptions(for draft: MobileEvolutionDefaultDraft) -> [String] {
        optionsStore.modelVariantOptions(
            for: draft.aiTool,
            providerID: draft.providerID,
            modelID: draft.modelID
        )
    }

    private func selectedModelVariant(for draft: MobileEvolutionDefaultDraft) -> String? {
        optionsStore.selectedModelVariant(
            configOptions: draft.configOptions,
            providerID: draft.providerID,
            modelID: draft.modelID,
            for: draft.aiTool
        )
    }

    private func sanitizeModelVariantSelection(draft: inout MobileEvolutionDefaultDraft) {
        guard let optionID = modelVariantOptionID(for: draft.aiTool) else { return }
        guard let raw = draft.configOptions[optionID] else { return }
        let value = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let options = modelVariantOptions(for: draft)
        if value.isEmpty || (!options.isEmpty && !options.contains(value)) {
            draft.configOptions.removeValue(forKey: optionID)
        }
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
