// MARK: - Evolution 全局默认配置区块

#if os(macOS)
import SwiftUI

struct EvolutionDefaultConfigSection: View {
    @EnvironmentObject var appState: AppState
    @State private var editableProfiles: [EvolutionEditableProfile] = []
    @State private var optionsStore = EvolutionProfileOptionsProjectionStore()

    var body: some View {
        Form {
            Section {
                ForEach($editableProfiles) { $profile in
                    stageRow(profile: $profile)
                }
            } header: {
                Text("settings.evolution.title".localized)
            } footer: {
                Text("settings.evolution.footer".localized)
            }
        }
        .formStyle(.grouped)
        .settingsPageTopInset()
        .onAppear {
            editableProfiles = appState.evolutionDefaultProfiles
            optionsStore.bindSettings(appState: appState)
        }
        .onChange(of: appState.evolutionDefaultProfiles) {
            editableProfiles = appState.evolutionDefaultProfiles
        }
    }

    // MARK: - 单个 Stage 行

    @ViewBuilder
    private func stageRow(profile: Binding<EvolutionEditableProfile>) -> some View {
        let stage = profile.wrappedValue.stage

        VStack(alignment: .leading, spacing: 6) {
            Text(stageDisplayName(stage))
                .font(.subheadline)
                .fontWeight(.medium)

            LabeledContent("settings.evolution.aiTool".localized) {
                Picker("", selection: Binding<AIChatTool>(
                    get: { profile.wrappedValue.aiTool },
                    set: { newValue in
                        profile.wrappedValue.aiTool = newValue
                        profile.wrappedValue.mode = ""
                        profile.wrappedValue.providerID = ""
                        profile.wrappedValue.modelID = ""
                        profile.wrappedValue.configOptions = [:]
                        persist()
                    }
                )) {
                    ForEach(AIChatTool.allCases) { tool in
                        Text(tool.displayName).tag(tool)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            LabeledContent("settings.evolution.mode".localized) {
                Menu {
                    Button("settings.evolution.defaultMode".localized) {
                        profile.wrappedValue.mode = ""
                        persist()
                    }
                    let options = modeOptions(for: profile.wrappedValue.aiTool)
                    if options.isEmpty {
                        Text("settings.evolution.noModes".localized)
                    } else {
                        ForEach(options, id: \.self) { option in
                            Button(option) {
                                profile.wrappedValue.mode = option
                                persist()
                            }
                        }
                    }
                } label: {
                    Text(profile.wrappedValue.mode.isEmpty
                         ? "settings.evolution.defaultMode".localized
                         : profile.wrappedValue.mode)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
            }

            LabeledContent("settings.evolution.model".localized) {
                Menu {
                    Button("settings.evolution.defaultModel".localized) {
                        var next = profile.wrappedValue
                        next.providerID = ""
                        next.modelID = ""
                        sanitizeModelVariantSelection(profile: &next)
                        profile.wrappedValue = next
                        persist()
                    }
                    let providers = modelProviders(for: profile.wrappedValue.aiTool)
                    if providers.isEmpty {
                        Text("settings.evolution.noModels".localized)
                    } else if providers.count <= 1 {
                        if let onlyProvider = providers.first {
                            ForEach(onlyProvider.models) { model in
                                Button(model.name) {
                                    var next = profile.wrappedValue
                                    next.providerID = onlyProvider.id
                                    next.modelID = model.id
                                    sanitizeModelVariantSelection(profile: &next)
                                    profile.wrappedValue = next
                                    persist()
                                }
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
                                        persist()
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

            LabeledContent("模型变体") {
                Menu {
                    Button("默认") {
                        if let optionID = modelVariantOptionID(for: profile.wrappedValue.aiTool) {
                            profile.wrappedValue.configOptions.removeValue(forKey: optionID)
                            persist()
                        }
                    }
                    let options = modelVariantOptions(for: profile.wrappedValue)
                    if options.isEmpty {
                        Text("当前模型未提供可用变体")
                    } else {
                        ForEach(options, id: \.self) { option in
                            Button(option) {
                                if let optionID = modelVariantOptionID(for: profile.wrappedValue.aiTool) {
                                    profile.wrappedValue.configOptions[optionID] = option
                                    persist()
                                }
                            }
                        }
                    }
                } label: {
                    Text(selectedModelVariant(for: profile.wrappedValue) ?? "默认")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 辅助方法

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

    private func persist() {
        appState.saveEvolutionDefaultProfiles(editableProfiles)
    }
}

#endif
