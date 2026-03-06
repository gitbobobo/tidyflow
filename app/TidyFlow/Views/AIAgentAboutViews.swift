import SwiftUI

// MARK: - AI Agent 配置部分

struct AIAgentSection: View {
    @EnvironmentObject var appState: AppState
    @State private var editableProfiles: [EvolutionEditableProfile] = []

    /// AI Agent 选项列表（含"未配置"）
    private var agentOptions: [(value: String?, label: String, icon: String?)] {
        var options: [(value: String?, label: String, icon: String?)] = [
            (nil, "settings.aiAgent.notConfiguredOption".localized, nil)
        ]
        for agent in AIAgent.allCases {
            options.append((agent.rawValue, agent.displayName, agent.brandIcon.assetName))
        }
        return options
    }

    var body: some View {
        Form {
            aiAgentBaseSection
            evolutionSections
        }
        .formStyle(.grouped)
        .settingsPageTopInset()
        .onAppear {
            editableProfiles = appState.evolutionDefaultProfiles
            _ = appState.requestAISelectorResourcesForSettings()
        }
        .onChange(of: appState.evolutionDefaultProfiles) {
            editableProfiles = appState.evolutionDefaultProfiles
        }
        .onChange(of: appState.connectionState) { _, state in
            guard state == .connected else { return }
            _ = appState.requestAISelectorResourcesForSettings()
        }
        .onChange(of: appState.projects.map { $0.workspaces.count }) { _, _ in
            _ = appState.requestAISelectorResourcesForSettings()
        }
    }

    private var aiAgentBaseSection: some View {
        Section {
            agentPickerRow(title: "settings.aiAgent.mergeAgent".localized, selection: mergeBinding)
        } header: {
            Text("settings.aiAgent.title".localized)
        } footer: {
            Text("settings.aiAgent.footer".localized)
        }
    }

    @ViewBuilder
    private var evolutionSections: some View {
        ForEach($editableProfiles) { $profile in
            evolutionSection(
                profile: $profile,
                isLast: profile.id == editableProfiles.last?.id
            )
        }
    }

    private func agentPickerRow(title: String, selection: Binding<String?>) -> some View {
        LabeledContent(title) {
            Picker("", selection: selection) {
                ForEach(agentOptions, id: \.label) { option in
                    if let iconName = option.icon {
                        Label {
                            Text(option.label)
                        } icon: {
                            Image(iconName)
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                        }
                        .tag(option.value as String?)
                    } else {
                        Text(option.label)
                            .tag(option.value as String?)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func evolutionSection(profile: Binding<EvolutionEditableProfile>, isLast: Bool) -> some View {
        Section {
            evolutionToolRow(profile: profile)
            evolutionModeRow(profile: profile)
            evolutionModelRow(profile: profile)
            evolutionThoughtLevelRow(profile: profile)
        } header: {
            Text(stageDisplayName(profile.wrappedValue.stage))
        } footer: {
            if isLast {
                Text("settings.evolution.footer".localized)
            }
        }
    }

    private func evolutionToolRow(profile: Binding<EvolutionEditableProfile>) -> some View {
        LabeledContent("settings.evolution.aiTool".localized) {
            Picker("", selection: Binding<AIChatTool>(
                get: { profile.wrappedValue.aiTool },
                set: { newValue in
                    profile.wrappedValue.aiTool = newValue
                    profile.wrappedValue.mode = ""
                    profile.wrappedValue.providerID = ""
                    profile.wrappedValue.modelID = ""
                    profile.wrappedValue.configOptions = [:]
                    persistEvolutionProfiles()
                }
            )) {
                ForEach(AIChatTool.allCases) { tool in
                    Text(tool.displayName).tag(tool)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func evolutionModeRow(profile: Binding<EvolutionEditableProfile>) -> some View {
        let selectedMode = profile.wrappedValue.mode
        let options = modeOptions(for: profile.wrappedValue.aiTool)

        return LabeledContent("settings.evolution.mode".localized) {
            Menu {
                Button("settings.evolution.defaultMode".localized) {
                    profile.wrappedValue.mode = ""
                    persistEvolutionProfiles()
                }
                if options.isEmpty {
                    Text("settings.evolution.noModes".localized)
                } else {
                    ForEach(options, id: \.self) { option in
                        Button(option) {
                            profile.wrappedValue.mode = option
                            persistEvolutionProfiles()
                        }
                    }
                }
            } label: {
                Text(selectedMode.isEmpty
                     ? "settings.evolution.defaultMode".localized
                     : selectedMode)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func evolutionModelRow(profile: Binding<EvolutionEditableProfile>) -> some View {
        let providers = modelProviders(for: profile.wrappedValue.aiTool)

        return LabeledContent("settings.evolution.model".localized) {
            Menu {
                Button("settings.evolution.defaultModel".localized) {
                    profile.wrappedValue.providerID = ""
                    profile.wrappedValue.modelID = ""
                    persistEvolutionProfiles()
                }
                if providers.isEmpty {
                    Text("settings.evolution.noModels".localized)
                } else if providers.count == 1, let onlyProvider = providers.first {
                    ForEach(onlyProvider.models) { model in
                        Button(model.name) {
                            profile.wrappedValue.providerID = onlyProvider.id
                            profile.wrappedValue.modelID = model.id
                            persistEvolutionProfiles()
                        }
                    }
                } else {
                    ForEach(providers) { provider in
                        Menu(provider.name) {
                            ForEach(provider.models) { model in
                                Button(model.name) {
                                    profile.wrappedValue.providerID = provider.id
                                    profile.wrappedValue.modelID = model.id
                                    persistEvolutionProfiles()
                                }
                            }
                        }
                    }
                }
            } label: {
                Text(selectedModelDisplayName(for: profile.wrappedValue))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func evolutionThoughtLevelRow(profile: Binding<EvolutionEditableProfile>) -> some View {
        let options = thoughtLevelOptions(for: profile.wrappedValue.aiTool)
        let selected = selectedThoughtLevel(for: profile.wrappedValue)

        return LabeledContent("思考强度") {
            Menu {
                Button("默认") {
                    if let optionID = thoughtLevelOptionID(for: profile.wrappedValue.aiTool) {
                        profile.wrappedValue.configOptions.removeValue(forKey: optionID)
                        persistEvolutionProfiles()
                    }
                }
                if options.isEmpty {
                    Text("未提供 thought_level 选项")
                } else {
                    ForEach(options, id: \.self) { option in
                        Button(option) {
                            if let optionID = thoughtLevelOptionID(for: profile.wrappedValue.aiTool) {
                                profile.wrappedValue.configOptions[optionID] = option
                                persistEvolutionProfiles()
                            }
                        }
                    }
                }
            } label: {
                Text(selected ?? "默认")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func stageDisplayName(_ stage: String) -> String {
        switch stage.lowercased() {
        case "direction": return "Direction"
        case "plan":      return "Plan"
        case "implement_general": return "Implement General"
        case "implement_visual": return "Implement Visual"
        case "implement_advanced": return "Implement Advanced"
        case "verify":    return "Verify"
        case "auto_commit": return "Auto Commit"
        default:          return stage
        }
    }

    private func modeOptions(for tool: AIChatTool) -> [String] {
        var seen: Set<String> = []
        var values: [String] = []
        for agent in appState.aiAgents(for: tool) {
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard seen.insert(name).inserted else { continue }
            values.append(name)
        }
        return values
    }

    private func modelProviders(for tool: AIChatTool) -> [AIProviderInfo] {
        appState.aiProviders(for: tool).filter { !$0.models.isEmpty }
    }

    private func selectedModelDisplayName(for profile: EvolutionEditableProfile) -> String {
        guard !profile.providerID.isEmpty, !profile.modelID.isEmpty else {
            return "settings.evolution.defaultModel".localized
        }
        for provider in modelProviders(for: profile.aiTool) {
            if provider.id == profile.providerID,
               let model = provider.models.first(where: { $0.id == profile.modelID }) {
                return model.name
            }
        }
        return profile.modelID
    }

    private func thoughtLevelOptionID(for tool: AIChatTool) -> String? {
        appState.aiSessionConfigOptions(for: tool).first(where: {
            let category = ($0.category ?? $0.optionID).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return category == "thought_level"
        })?.optionID
    }

    private func thoughtLevelOptions(for tool: AIChatTool) -> [String] {
        appState.thoughtLevelOptions(for: tool)
    }

    private func selectedThoughtLevel(for profile: EvolutionEditableProfile) -> String? {
        guard let optionID = thoughtLevelOptionID(for: profile.aiTool) else { return nil }
        let raw = profile.configOptions[optionID]
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

    private func persistEvolutionProfiles() {
        appState.saveEvolutionDefaultProfiles(editableProfiles)
    }

    private var mergeBinding: Binding<String?> {
        Binding(
            get: { appState.clientSettings.mergeAIAgent },
            set: { newValue in
                appState.clientSettings.mergeAIAgent = newValue
                appState.saveClientSettings()
            }
        )
    }
}

// MARK: - 关于页面

struct AboutSection: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // 应用图标
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)

            // 应用名称
            Text("TidyFlow")
                .font(.system(size: 24, weight: .semibold))

            // 版本信息
            Text(String(format: "settings.about.version".localized, appVersion, buildNumber))
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            // 描述
            Text("settings.about.description".localized)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()

            // 版权信息
            Text("© 2026 TidyFlow. All rights reserved.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .settingsPageTopInset()
    }
}
