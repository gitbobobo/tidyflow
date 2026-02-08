import SwiftUI

// MARK: - AI Agent 配置部分

struct AIAgentSection: View {
    @EnvironmentObject var appState: AppState

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
            Section {
                // 提交代理选择
                Picker("settings.aiAgent.commitAgent".localized, selection: commitBinding) {
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

                // 合并代理选择
                Picker("settings.aiAgent.mergeAgent".localized, selection: mergeBinding) {
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
            } header: {
                Text("settings.aiAgent.title".localized)
            } footer: {
                Text("settings.aiAgent.footer".localized)
            }
        }
        .formStyle(.grouped)
    }

    private var commitBinding: Binding<String?> {
        Binding(
            get: { appState.clientSettings.commitAIAgent },
            set: { newValue in
                appState.clientSettings.commitAIAgent = newValue
                appState.saveClientSettings()
            }
        )
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
    }
}
