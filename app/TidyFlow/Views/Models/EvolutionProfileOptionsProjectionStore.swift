import Foundation
import Combine
import Observation

struct EvolutionModelChoiceProjection: Equatable {
    let providerID: String
    let modelID: String
}

struct EvolutionAgentOptionProjection: Identifiable, Equatable {
    let id: String
    let name: String
    let defaultProviderID: String?
    let defaultModelID: String?

    init(name: String, defaultProviderID: String?, defaultModelID: String?) {
        id = name
        self.name = name
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
    }

    init(_ agent: AIAgentInfo) {
        self.init(
            name: agent.name,
            defaultProviderID: agent.defaultProviderID,
            defaultModelID: agent.defaultModelID
        )
    }

    var defaultModelSelection: EvolutionModelChoiceProjection? {
        guard let defaultProviderID,
              let defaultModelID,
              !defaultProviderID.isEmpty,
              !defaultModelID.isEmpty else {
            return nil
        }
        return EvolutionModelChoiceProjection(providerID: defaultProviderID, modelID: defaultModelID)
    }
}

struct EvolutionModelOptionProjection: Identifiable, Equatable {
    let id: String
    let modelID: String
    let providerID: String
    let name: String

    init(_ model: AIModelInfo) {
        id = model.id
        modelID = model.id
        providerID = model.providerID
        name = model.name
    }
}

struct EvolutionProviderOptionProjection: Identifiable, Equatable {
    let id: String
    let name: String
    let models: [EvolutionModelOptionProjection]
}

struct EvolutionToolOptionsProjection: Equatable {
    let tool: AIChatTool
    let agents: [EvolutionAgentOptionProjection]
    let modeOptions: [String]
    let providers: [EvolutionProviderOptionProjection]
    let thoughtLevelOptionID: String?
    let thoughtLevelOptions: [String]

    static func empty(tool: AIChatTool) -> EvolutionToolOptionsProjection {
        EvolutionToolOptionsProjection(
            tool: tool,
            agents: [],
            modeOptions: [],
            providers: [],
            thoughtLevelOptionID: nil,
            thoughtLevelOptions: []
        )
    }
}

struct EvolutionProfileOptionsProjection: Equatable {
    let contextKey: String
    let toolOptionsByTool: [AIChatTool: EvolutionToolOptionsProjection]

    static let empty = EvolutionProfileOptionsProjection(
        contextKey: "",
        toolOptionsByTool: Dictionary(
            uniqueKeysWithValues: AIChatTool.allCases.map { ($0, .empty(tool: $0)) }
        )
    )

    func options(for tool: AIChatTool) -> EvolutionToolOptionsProjection {
        toolOptionsByTool[tool] ?? .empty(tool: tool)
    }
}

enum EvolutionProfileOptionsProjectionSemantics {
    static func make(
        contextKey: String,
        agentsByTool: (AIChatTool) -> [AIAgentInfo],
        providersByTool: (AIChatTool) -> [AIProviderInfo],
        thoughtLevelOptionIDByTool: (AIChatTool) -> String?,
        thoughtLevelOptionsByTool: (AIChatTool) -> [String]
    ) -> EvolutionProfileOptionsProjection {
        let toolOptionsByTool = Dictionary(
            uniqueKeysWithValues: AIChatTool.allCases.map { tool in
                let agents = makeAgents(from: agentsByTool(tool))
                return (
                    tool,
                    EvolutionToolOptionsProjection(
                        tool: tool,
                        agents: agents,
                        modeOptions: agents.map(\.name),
                        providers: makeProviders(from: providersByTool(tool)),
                        thoughtLevelOptionID: thoughtLevelOptionIDByTool(tool),
                        thoughtLevelOptions: thoughtLevelOptionsByTool(tool)
                    )
                )
            }
        )

        return EvolutionProfileOptionsProjection(
            contextKey: contextKey,
            toolOptionsByTool: toolOptionsByTool
        )
    }

    static func stageDisplayName(_ stage: String) -> String {
        switch EvolutionStageSemantics.profileStageKey(for: stage) {
        case "direction": return "Direction"
        case "plan": return "Plan"
        case "implement_general": return "Implement General"
        case "implement_visual": return "Implement Visual"
        case "implement_advanced": return "Implement Advanced"
        case "verify": return "Verify"
        case "judge": return "Judge"
        case "auto_commit": return "Auto Commit"
        default: return stage
        }
    }

    static func selectedModelDisplayName(
        providerID: String,
        modelID: String,
        options: EvolutionToolOptionsProjection,
        defaultLabel: String
    ) -> String {
        guard !providerID.isEmpty, !modelID.isEmpty else { return defaultLabel }
        for provider in options.providers where provider.id == providerID {
            if let model = provider.models.first(where: { $0.modelID == modelID }) {
                return model.name
            }
        }
        return modelID
    }

    static func selectedThoughtLevel(
        configOptions: [String: Any],
        options: EvolutionToolOptionsProjection
    ) -> String? {
        guard let optionID = options.thoughtLevelOptionID else { return nil }
        let raw = configOptions[optionID]
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

    static func defaultModelSelection(
        agentName: String,
        options: EvolutionToolOptionsProjection
    ) -> EvolutionModelChoiceProjection? {
        let target = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return options.agents.first(where: {
            $0.name == target || $0.name.caseInsensitiveCompare(target) == .orderedSame
        })?.defaultModelSelection
    }

    private static func makeAgents(from agents: [AIAgentInfo]) -> [EvolutionAgentOptionProjection] {
        var seen: Set<String> = []
        var values: [EvolutionAgentOptionProjection] = []

        for agent in agents {
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard seen.insert(name).inserted else { continue }
            values.append(
                EvolutionAgentOptionProjection(
                    name: name,
                    defaultProviderID: agent.defaultProviderID,
                    defaultModelID: agent.defaultModelID
                )
            )
        }

        return values
    }

    private static func makeProviders(from providers: [AIProviderInfo]) -> [EvolutionProviderOptionProjection] {
        providers.compactMap { provider in
            let models = provider.models.map(EvolutionModelOptionProjection.init)
            guard !models.isEmpty else { return nil }
            return EvolutionProviderOptionProjection(
                id: provider.id,
                name: provider.name,
                models: models
            )
        }
    }
}

@MainActor
@Observable
final class EvolutionProfileOptionsProjectionStore {
    private(set) var projection: EvolutionProfileOptionsProjection = .empty

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var boundContextKey: String = ""

    func options(for tool: AIChatTool) -> EvolutionToolOptionsProjection {
        projection.options(for: tool)
    }

    func selectedModelDisplayName(
        providerID: String,
        modelID: String,
        for tool: AIChatTool,
        defaultLabel: String
    ) -> String {
        EvolutionProfileOptionsProjectionSemantics.selectedModelDisplayName(
            providerID: providerID,
            modelID: modelID,
            options: options(for: tool),
            defaultLabel: defaultLabel
        )
    }

    func selectedThoughtLevel(configOptions: [String: Any], for tool: AIChatTool) -> String? {
        EvolutionProfileOptionsProjectionSemantics.selectedThoughtLevel(
            configOptions: configOptions,
            options: options(for: tool)
        )
    }

    func defaultModelSelection(agentName: String, for tool: AIChatTool) -> EvolutionModelChoiceProjection? {
        EvolutionProfileOptionsProjectionSemantics.defaultModelSelection(
            agentName: agentName,
            options: options(for: tool)
        )
    }

    #if os(macOS)
    @ObservationIgnored private weak var boundMacAppState: AppState?

    func bindSettings(appState: AppState) {
        bindPublisher(
            appState: appState,
            contextKey: "mac-settings"
        ) { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refreshSettings(appState: appState)
        }
    }

    func refreshSettings(appState: AppState) {
        let next = EvolutionProfileOptionsProjectionSemantics.make(
            contextKey: "mac-settings",
            agentsByTool: appState.aiAgents(for:),
            providersByTool: appState.aiProviders(for:),
            thoughtLevelOptionIDByTool: appState.thoughtLevelOptionID(for:),
            thoughtLevelOptionsByTool: appState.thoughtLevelOptions(for:)
        )
        _ = updateProjection(next)
    }
    #endif

    #if os(iOS)
    @ObservationIgnored private weak var boundMobileAppState: MobileAppState?

    func bindSettings(appState: MobileAppState) {
        bindPublisher(
            appState: appState,
            contextKey: "ios-settings"
        ) { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refreshSettings(appState: appState)
        }
    }

    func refreshSettings(appState: MobileAppState) {
        let next = EvolutionProfileOptionsProjectionSemantics.make(
            contextKey: "ios-settings",
            agentsByTool: appState.settingsAgents(aiTool:),
            providersByTool: appState.settingsProviders(aiTool:),
            thoughtLevelOptionIDByTool: appState.thoughtLevelOptionID(for:),
            thoughtLevelOptionsByTool: appState.thoughtLevelOptions(for:)
        )
        _ = updateProjection(next)
    }

    func bindEvolution(appState: MobileAppState, project: String, workspace: String) {
        let contextKey = "ios-evolution:\(project):\(workspace)"
        bindPublisher(
            appState: appState,
            contextKey: contextKey
        ) { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.refreshEvolution(appState: appState, project: project, workspace: workspace)
        }
    }

    func refreshEvolution(appState: MobileAppState, project: String, workspace: String) {
        let next = EvolutionProfileOptionsProjectionSemantics.make(
            contextKey: "ios-evolution:\(project):\(workspace)",
            agentsByTool: { appState.evolutionAgents(project: project, workspace: workspace, aiTool: $0) },
            providersByTool: { appState.evolutionProviders(project: project, workspace: workspace, aiTool: $0) },
            thoughtLevelOptionIDByTool: appState.thoughtLevelOptionID(for:),
            thoughtLevelOptionsByTool: appState.thoughtLevelOptions(for:)
        )
        _ = updateProjection(next)
    }
    #endif

    @discardableResult
    func updateProjection(_ next: EvolutionProfileOptionsProjection) -> Bool {
        guard projection != next else { return false }
        projection = next
        return true
    }

    #if os(macOS)
    private func bindPublisher(
        appState: AppState,
        contextKey: String,
        refresh: @escaping () -> Void
    ) {
        guard boundMacAppState !== appState || boundContextKey != contextKey else {
            refresh()
            return
        }

        boundMacAppState = appState
        boundContextKey = contextKey
        cancellables.removeAll()

        // 只订阅影响进化 Profile 选项的属性，避免 AI 流式更新等无关变化触发刷新
        Publishers.Merge4(
            appState.$aiProviders.map { _ in () },
            appState.$aiAgents.map { _ in () },
            appState.$aiSessionConfigOptions.map { _ in () },
            appState.$aiChatTool.map { _ in () }
        )
        .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
        .sink { _ in
            refresh()
        }
        .store(in: &cancellables)

        refresh()
    }
    #endif

    #if os(iOS)
    private func bindPublisher(
        appState: MobileAppState,
        contextKey: String,
        refresh: @escaping () -> Void
    ) {
        guard boundMobileAppState !== appState || boundContextKey != contextKey else {
            refresh()
            return
        }

        boundMobileAppState = appState
        boundContextKey = contextKey
        cancellables.removeAll()

        // iOS 端相关属性为 private @Published，无法直接订阅；
        // 使用 throttle 限制 objectWillChange 触发频率，减少无关刷新
        appState.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { _ in
                refresh()
            }
            .store(in: &cancellables)

        refresh()
    }
    #endif
}
