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

            AboutSection()
                .tabItem {
                    Label("settings.about".localized, systemImage: "info.circle")
                }

            KeybindingsSection()
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }
                .environmentObject(appState)
        }
        .frame(width: 580, height: 580)
    }
}

private struct SettingsPageTopInsetModifier: ViewModifier {
    let height: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: height)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 48)
            }
        #else
        content
        #endif
    }
}

extension View {
    func settingsPageTopInset(_ height: CGFloat = 64) -> some View {
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

// MARK: - 快捷键配置部分

struct KeybindingsSection: View {
    @EnvironmentObject var appState: AppState
    @State private var editingBinding: KeybindingConfig? = nil
    @State private var editedKeyCombination: String = ""
    @State private var conflictMessage: String? = nil
    @State private var showingImporter = false
    @State private var importResult: (mapped: Int, unmapped: Int)? = nil

    private var groupedBindings: [(String, [KeybindingConfig])] {
        let contexts = ["global", "workspace"]
        return contexts.compactMap { ctx -> (String, [KeybindingConfig])? in
            let bindings = appState.clientSettings.keybindings.filter { $0.context == ctx }
            return bindings.isEmpty ? nil : (ctx, bindings)
        }
    }

    private func contextHeader(_ ctx: String) -> String {
        switch ctx {
        case "global": return "全局 (Global)"
        case "workspace": return "工作区 (Workspace)"
        case "terminal": return "终端 (Terminal)"
        case "editor": return "编辑器 (Editor)"
        default: return ctx
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(groupedBindings, id: \.0) { ctx, bindings in
                    Section(header: Text(contextHeader(ctx))) {
                        ForEach(bindings) { binding in
                            keybindingRow(binding)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                Button(action: { showingImporter = true }) {
                    Label("导入 VS Code", systemImage: "square.and.arrow.down")
                }

                if let result = importResult {
                    Text("已导入 \(result.mapped) 个，\(result.unmapped) 个未映射")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: resetToDefaults) {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .settingsPageTopInset()
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    @ViewBuilder
    private func keybindingRow(_ binding: KeybindingConfig) -> some View {
        if editingBinding?.commandId == binding.commandId {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(KeybindingConfig.displayName(for: binding.commandId))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    TextField("快捷键", text: $editedKeyCombination)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: editedKeyCombination) { _, _ in
                            updateConflict(for: binding)
                        }
                }

                if let conflict = conflictMessage {
                    Text(conflict)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                HStack(spacing: 8) {
                    Button("取消") {
                        editingBinding = nil
                        conflictMessage = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    if conflictMessage != nil {
                        Button("自动解决") {
                            if let resolved = appState.autoResolveKeybindingConflict(for: binding) {
                                editedKeyCombination = resolved
                                updateConflict(for: binding)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.orange)
                    }

                    Spacer()

                    Button("保存") {
                        var updated = binding
                        updated.keyCombination = editedKeyCombination
                        appState.saveKeybinding(updated)
                        editingBinding = nil
                        conflictMessage = nil
                    }
                    .disabled(conflictMessage != nil || editedKeyCombination.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                Text(KeybindingConfig.displayName(for: binding.commandId))
                    .font(.system(size: 13))
                Spacer()
                Text(binding.keyCombination)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                editingBinding = binding
                editedKeyCombination = binding.keyCombination
                conflictMessage = nil
            }
        }
    }

    private func updateConflict(for binding: KeybindingConfig) {
        var temp = binding
        temp.keyCombination = editedKeyCombination
        let conflicts = appState.keybindingConflicts(for: temp, in: appState.clientSettings.keybindings)
        if conflicts.isEmpty {
            conflictMessage = nil
        } else {
            let names = conflicts.map { KeybindingConfig.displayName(for: $0.commandId) }.joined(separator: ", ")
            conflictMessage = "与 \(names) 冲突"
        }
    }

    private func resetToDefaults() {
        appState.clientSettings.keybindings = KeybindingConfig.defaultKeybindings()
        appState.saveClientSettings()
        editingBinding = nil
        conflictMessage = nil
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else { return }
        let (mapped, unmapped) = VSCodeKeybindingsImporter.importFrom(jsonData: data)

        for binding in mapped {
            appState.saveKeybinding(binding)
        }
        importResult = (mapped: mapped.count, unmapped: unmapped.count)
    }
}
