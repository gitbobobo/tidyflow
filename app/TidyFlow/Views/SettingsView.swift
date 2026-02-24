import SwiftUI

// MARK: - 设置页面主视图
//
// 组件拆分至：
// - CommandEditSheet.swift  — CommandEditSheet + IconPickerSheet + CommandIconView
// - AIAgentAboutViews.swift — AIAgentSection + AboutSection

struct SettingsContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var localizationManager: LocalizationManager

    var body: some View {
        TabView {
            CustomCommandsSection()
                .tabItem {
                    Label("settings.title".localized, systemImage: "gear")
                }
                .environmentObject(appState)
                .environmentObject(localizationManager)

            AIAgentSection()
                .tabItem {
                    Label("settings.aiAgent".localized, systemImage: "cpu")
                }
                .environmentObject(appState)

            EvolutionDefaultConfigSection()
                .tabItem {
                    Label("settings.evolution".localized, systemImage: "arrow.triangle.2.circlepath")
                }
                .environmentObject(appState)

            AboutSection()
                .tabItem {
                    Label("settings.about".localized, systemImage: "info.circle")
                }
        }
        .frame(width: 580, height: 520)
    }
}

private struct SettingsPageTopInsetModifier: ViewModifier {
    let height: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 8)
            }
            .padding(.top, height)
        #else
        content
        #endif
    }
}

extension View {
    func settingsPageTopInset(_ height: CGFloat = 32) -> some View {
        modifier(SettingsPageTopInsetModifier(height: height))
    }
}

// MARK: - 自定义命令配置部分

struct CustomCommandsSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var localizationManager: LocalizationManager
    @State private var editingCommand: CustomCommand?
    @State private var showingAddSheet = false
    @State private var fixedPortText: String = ""
    @State private var remoteAccessEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("settings.language".localized, selection: Binding(
                    get: { localizationManager.appLanguage },
                    set: { newLang in
                        localizationManager.appLanguage = newLang
                        appState.clientSettings.appLanguage = newLang
                        appState.saveClientSettings()
                    }
                )) {
                    Text("settings.language.system".localized).tag("system")
                    Text("settings.language.zh".localized).tag("zh-Hans")
                    Text("settings.language.en".localized).tag("en")
                }
            } header: {
                Text("settings.language".localized)
            }

            Section {
                Toggle("settings.mobile.remoteAccess".localized, isOn: $remoteAccessEnabled)
                    .onChange(of: remoteAccessEnabled) { _, enabled in
                        appState.clientSettings.remoteAccessEnabled = enabled
                        appState.saveClientSettings()
                    }

                if appState.remoteAccessReady {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("settings.mobile.lanAddress".localized)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(appState.mobileLanAddressDisplayText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("settings.mobile.port".localized)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(appState.mobileAccessPortDisplayText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 12) {
                    Button(action: { appState.requestMobilePairCode() }) {
                        if appState.mobilePairCodeLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("settings.mobile.generateCode".localized, systemImage: "iphone.and.arrow.forward")
                        }
                    }
                    .disabled(!appState.remoteAccessReady || appState.mobilePairCodeLoading)

                    if let code = appState.mobilePairCode {
                        Text(code)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.semibold)
                            .textSelection(.enabled)
                    }
                }

                if let expiresAt = appState.mobilePairCodeExpiresAt, !expiresAt.isEmpty {
                    Text(String(format: "settings.mobile.codeExpires".localized, expiresAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let error = appState.mobilePairCodeError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } header: {
                Text("settings.mobile.section".localized)
            } footer: {
                Text("settings.mobile.footer".localized)
            }

            Section {
                HStack {
                    Text("settings.mobile.fixedPort".localized)
                    Spacer()
                    TextField("settings.mobile.fixedPort.placeholder".localized, text: $fixedPortText)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .onChange(of: fixedPortText) { _, newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered != newValue { fixedPortText = filtered }
                            if let val = Int(filtered), val > 0, val <= 65535 {
                                appState.clientSettings.fixedPort = val
                            } else {
                                appState.clientSettings.fixedPort = 0
                            }
                            appState.saveClientSettings()
                        }
                }
                Text("settings.mobile.fixedPort.hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("settings.mobile.fixedPort.section".localized)
            }

            Section {
                if appState.clientSettings.customCommands.isEmpty {
                    Text("settings.noCommands".localized)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appState.clientSettings.customCommands) { command in
                        CustomCommandRow(
                            command: command,
                            onEdit: { editingCommand = command },
                            onDelete: { appState.deleteCustomCommand(id: command.id) }
                        )
                    }
                }

                // 新增按钮
                Button(action: { showingAddSheet = true }) {
                    Label("settings.addCommand".localized, systemImage: "plus")
                        .foregroundColor(.accentColor)
                }
            } header: {
                Text("settings.terminalCommands".localized)
            } footer: {
                Text("settings.terminalCommands.footer".localized)
            }
        }
        .formStyle(.grouped)
        .settingsPageTopInset()
        .sheet(isPresented: $showingAddSheet) {
            CommandEditSheet(
                command: CustomCommand(),
                isNew: true,
                onSave: { command in
                    appState.addCustomCommand(command)
                }
            )
            .environmentObject(appState)
        }
        .sheet(item: $editingCommand) { command in
            CommandEditSheet(
                command: command,
                isNew: false,
                onSave: { updatedCommand in
                    appState.updateCustomCommand(updatedCommand)
                }
            )
            .environmentObject(appState)
        }
        .onAppear {
            let val = appState.clientSettings.fixedPort
            fixedPortText = val > 0 ? "\(val)" : ""
            remoteAccessEnabled = appState.clientSettings.remoteAccessEnabled
        }
    }
    
    // Helper views removed as they are simplified into the Form or not needed
}

// MARK: - 命令行视图

struct CustomCommandRow: View {
    let command: CustomCommand
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    @State private var showDeleteConfirm = false
    
    var body: some View {
        HStack(spacing: 12) {
            // 图标
            CommandIconView(iconName: command.icon, size: 24)
            
            // 名称和命令预览
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(.system(size: 13, weight: .medium))
                Text(command.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // 操作按钮
            HStack(spacing: 8) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("common.edit".localized)
                
                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("common.delete".localized)
            }
        }
        .padding(.vertical, 4)
        .alert("settings.deleteCommand".localized, isPresented: $showDeleteConfirm) {
            Button("common.cancel".localized, role: .cancel) { }
            Button("common.delete".localized, role: .destructive) { onDelete() }
        } message: {
            Text(String(format: "settings.deleteCommand.message".localized, command.name))
        }
    }
}

// BrandIcon 枚举定义在 Models.swift 中
