// MARK: - Evolution 全局默认配置区块

#if os(macOS)
import SwiftUI

struct EvolutionDefaultConfigSection: View {
    @EnvironmentObject var appState: AppState
    @State private var editableProfiles: [EvolutionEditableProfile] = []

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
        .onAppear {
            editableProfiles = appState.evolutionDefaultProfiles
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
                        profile.wrappedValue.providerID = ""
                        profile.wrappedValue.modelID = ""
                        persist()
                    }
                    let providers = modelProviders(for: profile.wrappedValue.aiTool)
                    if providers.isEmpty {
                        Text("settings.evolution.noModels".localized)
                    } else if providers.count <= 1 {
                        if let onlyProvider = providers.first {
                            ForEach(onlyProvider.models) { model in
                                Button(model.name) {
                                    profile.wrappedValue.providerID = onlyProvider.id
                                    profile.wrappedValue.modelID = model.id
                                    persist()
                                }
                            }
                        }
                    } else {
                        ForEach(providers) { provider in
                            Menu(provider.name) {
                                ForEach(provider.models) { model in
                                    Button(model.name) {
                                        profile.wrappedValue.providerID = provider.id
                                        profile.wrappedValue.modelID = model.id
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
        }
        .padding(.vertical, 4)
    }

    // MARK: - 辅助方法

    private func stageDisplayName(_ stage: String) -> String {
        switch stage.lowercased() {
        case "direction": return "Direction"
        case "plan":      return "Plan"
        case "implement": return "Implement"
        case "verify":    return "Verify"
        case "judge":     return "Judge"
        case "report":    return "Report"
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

    private func persist() {
        appState.saveEvolutionDefaultProfiles(editableProfiles)
    }
}

#endif
