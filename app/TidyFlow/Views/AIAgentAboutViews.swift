import SwiftUI

// MARK: - AI Agent 配置部分

struct AIAgentSection: View {
    @EnvironmentObject var appState: AppState
    @State private var editableProfiles: [EvolutionEditableProfile] = []
    @State private var optionsStore = EvolutionProfileOptionsProjectionStore()

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
            optionsStore.bindSettings(appState: appState)
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
            evolutionModelVariantRow(profile: profile)
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
                    var next = profile.wrappedValue
                    next.providerID = ""
                    next.modelID = ""
                    sanitizeModelVariantSelection(profile: &next)
                    profile.wrappedValue = next
                    persistEvolutionProfiles()
                }
                if providers.isEmpty {
                    Text("settings.evolution.noModels".localized)
                } else if providers.count == 1, let onlyProvider = providers.first {
                    ForEach(onlyProvider.models) { model in
                        Button(model.name) {
                            var next = profile.wrappedValue
                            next.providerID = onlyProvider.id
                            next.modelID = model.id
                            sanitizeModelVariantSelection(profile: &next)
                            profile.wrappedValue = next
                            persistEvolutionProfiles()
                        }
                    }
                } else {
                    ForEach(providers) { provider in
                        Menu(provider.name) {
                            ForEach(provider.models) { model in
                                Button(model.name) {
                                    var next = profile.wrappedValue
                                    next.providerID = provider.id
                                    next.modelID = model.id
                                    sanitizeModelVariantSelection(profile: &next)
                                    profile.wrappedValue = next
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

    private func evolutionModelVariantRow(profile: Binding<EvolutionEditableProfile>) -> some View {
        let options = modelVariantOptions(for: profile.wrappedValue)
        let selected = selectedModelVariant(for: profile.wrappedValue)

        return LabeledContent("模型变体") {
            Menu {
                Button("默认") {
                    if let optionID = modelVariantOptionID(for: profile.wrappedValue.aiTool) {
                        profile.wrappedValue.configOptions.removeValue(forKey: optionID)
                        persistEvolutionProfiles()
                    }
                }
                if options.isEmpty {
                    Text("当前模型未提供可用变体")
                } else {
                    ForEach(options, id: \.self) { option in
                        Button(option) {
                            if let optionID = modelVariantOptionID(for: profile.wrappedValue.aiTool) {
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
        EvolutionProfileOptionsProjectionSemantics.stageDisplayName(stage)
    }

    private func modeOptions(for tool: AIChatTool) -> [String] {
        optionsStore.options(for: tool).modeOptions
    }

    private func modelProviders(for tool: AIChatTool) -> [EvolutionProviderOptionProjection] {
        optionsStore.options(for: tool).providers
    }

    private func selectedModelDisplayName(for profile: EvolutionEditableProfile) -> String {
        optionsStore.selectedModelDisplayName(
            providerID: profile.providerID,
            modelID: profile.modelID,
            for: profile.aiTool,
            defaultLabel: "settings.evolution.defaultModel".localized
        )
    }

    private func modelVariantOptionID(for tool: AIChatTool) -> String? {
        optionsStore.modelVariantOptionID(for: tool)
    }

    private func modelVariantOptions(for profile: EvolutionEditableProfile) -> [String] {
        optionsStore.modelVariantOptions(
            for: profile.aiTool,
            providerID: profile.providerID,
            modelID: profile.modelID
        )
    }

    private func selectedModelVariant(for profile: EvolutionEditableProfile) -> String? {
        optionsStore.selectedModelVariant(
            configOptions: profile.configOptions,
            providerID: profile.providerID,
            modelID: profile.modelID,
            for: profile.aiTool
        )
    }

    private func sanitizeModelVariantSelection(profile: inout EvolutionEditableProfile) {
        guard let optionID = modelVariantOptionID(for: profile.aiTool) else { return }
        guard let raw = profile.configOptions[optionID] else { return }
        let value = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let options = modelVariantOptions(for: profile)
        if value.isEmpty || (!options.isEmpty && !options.contains(value)) {
            profile.configOptions.removeValue(forKey: optionID)
        }
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
            Image(systemName: "square.stack.3d.up.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .foregroundStyle(Color.accentColor)

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
