import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置页面主视图
//
// 组件拆分至：
// - CommandEditSheet.swift  — CommandEditSheet + IconPickerSheet + CommandIconView
// - AIAgentAboutViews.swift — AIAgentSection + AboutSection

private struct TemplateExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

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

            TemplatesSection()
                .tabItem {
                    Label("模板", systemImage: "doc.text.below.ecg")
                }
                .tag("templates")
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
    @State private var nodeName: String = ""
    @State private var nodeDiscoveryEnabled: Bool = false
    @State private var nodeProfileSaveTask: Task<Void, Never>?
    @State private var pairHost: String = ""
    @State private var pairPort: String = ""
    @State private var pairKey: String = ""

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
                        guard enabled != appState.clientSettings.remoteAccessEnabled else { return }
                        appState.clientSettings.remoteAccessEnabled = enabled
                        appState.saveClientSettings()
                    }
                RemoteAccessStatusSection(coreProcessManager: appState.coreProcessManager)
                    .environmentObject(appState)
            } header: {
                Text("settings.mobile.section".localized)
            } footer: {
                Text("settings.mobile.footer".localized)
            }

            Section {
                TextField("节点名称", text: $nodeName)
                    .onChange(of: nodeName) { _, _ in
                        scheduleNodeProfileSave()
                    }
                    .onSubmit {
                        persistNodeProfileIfNeeded()
                    }
                Toggle("开启局域网发现广播", isOn: $nodeDiscoveryEnabled)
                    .onChange(of: nodeDiscoveryEnabled) { _, enabled in
                        nodeProfileSaveTask?.cancel()
                        persistNodeProfileIfNeeded(discoveryEnabled: enabled)
                    }
                if let selfInfo = appState.nodeSelfInfo {
                    LabeledContent("节点 ID") {
                        Text(selfInfo.nodeID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("首次启动配对 Key") {
                        Text(selfInfo.bootstrapPairKey)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("节点网络")
            } footer: {
                Text("填写节点名称后才能开启广播发现；配对时需要输入对端首次启动生成的 Key。")
            }

            Section {
                TextField("节点地址", text: $pairHost)
                TextField("端口", text: $pairPort)
                SecureField("对端配对 Key", text: $pairKey)
                Button("发起配对") {
                    let port = Int(pairPort) ?? 0
                    guard !pairHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          port > 0,
                          !pairKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return
                    }
                    appState.pairNodePeer(host: pairHost, port: port, pairKey: pairKey)
                }
                if let result = appState.nodeLastPairingResult {
                    Text(result.ok ? "配对成功" : (result.message ?? "配对失败"))
                        .font(.caption)
                        .foregroundColor(result.ok ? .green : .red)
                }
            } header: {
                Text("手动配对")
            }

            Section {
                if appState.nodeDiscoveryItems.isEmpty {
                    Text("当前未发现局域网节点")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appState.nodeDiscoveryItems) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.nodeName)
                                Text("\(item.host):\(item.port)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if item.paired {
                                Text("已配对")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
                Button("刷新发现结果") {
                    appState.refreshNodeNetwork()
                }
            } header: {
                Text("局域网发现")
            }

            Section {
                if appState.nodeNetworkPeers.isEmpty {
                    Text("当前没有已配对节点")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appState.nodeNetworkPeers) { peer in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.peerName)
                                Text("\(peer.addresses.first ?? "-"):\(peer.port)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(peer.status)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("取消配对") {
                                appState.unpairNodePeer(peerNodeID: peer.peerNodeID)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                Text("已配对节点")
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
                            let nextPort: Int
                            if let val = Int(filtered), val > 0, val <= 65535 {
                                nextPort = val
                            } else {
                                nextPort = 0
                            }
                            guard nextPort != appState.clientSettings.fixedPort else { return }
                            appState.clientSettings.fixedPort = nextPort
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
            syncClientSettingsSnapshot()
            appState.refreshNodeNetwork()
        }
        .onDisappear {
            nodeProfileSaveTask?.cancel()
            persistNodeProfileIfNeeded()
        }
        .onChange(of: appState.clientSettingsLoaded) { _, loaded in
            guard loaded else { return }
            syncClientSettingsSnapshot()
        }
        .onChange(of: appState.clientSettings.fixedPort) { _, _ in
            syncClientSettingsSnapshot()
        }
        .onChange(of: appState.clientSettings.remoteAccessEnabled) { _, _ in
            syncClientSettingsSnapshot()
        }
        .onChange(of: appState.clientSettings.nodeName) { _, _ in
            syncClientSettingsSnapshot()
        }
        .onChange(of: appState.clientSettings.nodeDiscoveryEnabled) { _, _ in
            syncClientSettingsSnapshot()
        }
    }

    private func syncClientSettingsSnapshot() {
        let fixedPort = appState.clientSettings.fixedPort
        fixedPortText = fixedPort > 0 ? "\(fixedPort)" : ""
        remoteAccessEnabled = appState.clientSettings.remoteAccessEnabled
        nodeName = appState.clientSettings.nodeName ?? ""
        nodeDiscoveryEnabled = appState.clientSettings.nodeDiscoveryEnabled
    }

    private func scheduleNodeProfileSave() {
        nodeProfileSaveTask?.cancel()
        nodeProfileSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            persistNodeProfileIfNeeded()
        }
    }

    private func persistNodeProfileIfNeeded(discoveryEnabled: Bool? = nil) {
        let nextDiscoveryEnabled = discoveryEnabled ?? nodeDiscoveryEnabled
        let normalizedName = nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = normalizedName.isEmpty ? nil : normalizedName
        let currentPending = appState.pendingNodeProfileUpdate
        let currentServer = appState.lastKnownServerNodeProfile
        let currentName = currentPending?.nodeName ?? currentServer?.nodeName ?? appState.clientSettings.nodeName
        let currentDiscoveryEnabled = currentPending?.discoveryEnabled ?? currentServer?.discoveryEnabled ?? appState.clientSettings.nodeDiscoveryEnabled
        guard nextName != currentName || nextDiscoveryEnabled != currentDiscoveryEnabled else {
            return
        }
        appState.updateNodeProfile(nodeName: nextName, discoveryEnabled: nextDiscoveryEnabled)
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

private struct RemoteAccessStatusSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var coreProcessManager: CoreProcessManager
    @State private var showCreateSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.remoteAccessReady {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("settings.mobile.lanAddress".localized)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(appState.mobileLanAddressDisplayText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("settings.mobile.port".localized)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(appState.mobileAccessPortDisplayText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 12) {
                Button {
                    appState.refreshRemoteAPIKeys()
                } label: {
                    if appState.remoteAPIKeysLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("settings.mobile.refreshKeys".localized, systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!appState.remoteAccessReady || appState.remoteAPIKeysLoading)

                Button {
                    showCreateSheet = true
                } label: {
                    Label("settings.mobile.createKey".localized, systemImage: "plus")
                }
                .disabled(!appState.remoteAccessReady || appState.remoteAPIKeysLoading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("settings.mobile.apiKeys".localized)
                    .font(.headline)

                if appState.remoteAPIKeys.isEmpty {
                    Text("settings.mobile.noKeys".localized)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.remoteAPIKeys) { item in
                        RemoteAPIKeyRow(item: item) {
                            appState.deleteRemoteAPIKey(id: item.id)
                        }
                    }
                }
            }

            if let error = appState.remoteAPIKeysError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            guard appState.remoteAccessReady, appState.remoteAPIKeys.isEmpty else { return }
            appState.refreshRemoteAPIKeys()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateRemoteAPIKeySheet { name in
                appState.createRemoteAPIKey(name: name)
            }
        }
    }
}

private struct RemoteAPIKeyRow: View {
    let item: RemoteAPIKeyRecord
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                Text(item.maskedKey)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(item.createdAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("settings.mobile.copyKey".localized) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(item.apiKey, forType: .string)
            }

            Button("common.delete".localized, role: .destructive, action: onDelete)
        }
        .padding(.vertical, 4)
    }
}

private struct CreateRemoteAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    let onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("settings.mobile.createKey".localized)
                .font(.headline)
            TextField("settings.mobile.keyNamePlaceholder".localized, text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("common.cancel".localized) {
                    dismiss()
                }
                Button("settings.mobile.createAction".localized) {
                    onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
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

// MARK: - 工作流模板管理

struct TemplatesSection: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddSheet = false
    @State private var editingTemplate: TemplateInfo?
    @State private var showingImportPicker = false
    @State private var exportTemplate: TemplateInfo?

    var body: some View {
        List {
            // 内置模板
            Section(header: Text("内置模板")) {
                let builtins = appState.templates.filter { $0.builtin }
                if builtins.isEmpty {
                    Text("暂无内置模板").foregroundColor(.secondary)
                } else {
                    ForEach(builtins) { tpl in
                        TemplateRow(template: tpl, onEdit: {
                            editingTemplate = tpl
                        }, onExport: {
                            exportTemplate = tpl
                        }, onDelete: nil)
                    }
                }
            }
            // 自定义模板
            Section(header: Text("自定义模板")) {
                let customs = appState.templates.filter { !$0.builtin }
                if customs.isEmpty {
                    Text("点击 + 新建模板").foregroundColor(.secondary)
                } else {
                    ForEach(customs) { tpl in
                        TemplateRow(template: tpl, onEdit: {
                            editingTemplate = tpl
                        }, onExport: {
                            exportTemplate = tpl
                        }, onDelete: {
                            appState.deleteTemplate(templateId: tpl.id)
                        })
                    }
                }
            }
        }
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button(action: { showingImportPicker = true }) {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
            }
            ToolbarItem {
                Button(action: { showingAddSheet = true }) {
                    Label("新建模板", systemImage: "plus")
                }
            }
            #endif
        }
        .sheet(isPresented: $showingAddSheet) {
            TemplateEditSheet(template: nil) { tpl in
                appState.saveTemplate(tpl)
            }
        }
        .sheet(item: $editingTemplate) { tpl in
            TemplateEditSheet(template: tpl) { updated in
                appState.saveTemplate(updated)
            }
        }
        #if os(macOS)
        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                importTemplateFromFile(url: url)
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportTemplate != nil },
                set: { newValue in
                    if !newValue {
                        exportTemplate = nil
                    }
                }
            ),
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportTemplateFileName
        ) { _ in
            exportTemplate = nil
        }
        #endif
        .onAppear {
            appState.loadTemplates()
        }
    }

    #if os(macOS)
    private var exportDocument: TemplateExportDocument {
        guard let exportTemplate,
              let data = try? JSONSerialization.data(
                withJSONObject: exportTemplate.toDict(),
                options: [.prettyPrinted]
              ) else {
            return TemplateExportDocument(data: Data("{}".utf8))
        }
        return TemplateExportDocument(data: data)
    }

    private var exportTemplateFileName: String {
        guard let exportTemplate else { return "template.json" }
        return "\(exportTemplate.name).json"
    }
    #endif

    #if os(macOS)
    /// 从文件导入模板
    private func importTemplateFromFile(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tpl = TemplateInfo.from(json: json) else { return }
        appState.importTemplate(tpl)
    }
    #endif
}

/// 模板列表行
private struct TemplateRow: View {
    let template: TemplateInfo
    let onEdit: () -> Void
    let onExport: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(template.name).fontWeight(.medium)
                    if template.builtin {
                        Text("内置").font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15)).foregroundColor(.blue).cornerRadius(4)
                    }
                    ForEach(template.tags, id: \.self) { tag in
                        Text(tag).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.gray.opacity(0.15)).foregroundColor(.secondary).cornerRadius(4)
                    }
                }
                if !template.description.isEmpty {
                    Text(template.description).font(.caption).foregroundColor(.secondary)
                }
                Text("\(template.commands.count) 个命令").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            // 导出按钮
            #if os(macOS)
            Button(action: onExport) {
                Image(systemName: "square.and.arrow.up").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            #endif
            Button(action: onEdit) {
                Image(systemName: "pencil").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            if let onDelete, !template.builtin {
                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 模板编辑 Sheet
struct TemplateEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let template: TemplateInfo?
    let onSave: (TemplateInfo) -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var tagsText: String = ""
    @State private var commands: [EditableTemplateCommand] = []
    @State private var envVarsText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("基本信息")) {
                    TextField("模板名称", text: $name)
                    TextField("描述（可选）", text: $description)
                    TextField("标签（逗号分隔，如 node,javascript）", text: $tagsText)
                }
                Section(header: Text("命令列表")) {
                    ForEach($commands) { $cmd in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("命令名称", text: $cmd.name).font(.subheadline)
                                Spacer()
                                Toggle("阻塞", isOn: $cmd.blocking).labelsHidden()
                                    .help("阻塞模式：命令执行完成后才能执行下一个")
                                Toggle("交互", isOn: $cmd.interactive).labelsHidden()
                                    .help("交互模式：在新终端 Tab 中执行")
                            }
                            TextField("命令字符串（如 npm install）", text: $cmd.command).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { indices in
                        commands.remove(atOffsets: indices)
                    }
                    Button("添加命令") {
                        commands.append(EditableTemplateCommand())
                    }
                }
                Section(header: Text("环境变量（每行 KEY=VALUE）")) {
                    TextEditor(text: $envVarsText).frame(minHeight: 60).font(.caption)
                }
            }
            .navigationTitle(template == nil ? "新建模板" : "编辑模板")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let tpl = buildTemplate()
                        onSave(tpl)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 500)
        .onAppear {
            if let tpl = template {
                name = tpl.name
                description = tpl.description
                tagsText = tpl.tags.joined(separator: ", ")
                commands = tpl.commands.map { EditableTemplateCommand(from: $0) }
                envVarsText = tpl.envVars.map { "\($0[0])=\($0[1])" }.joined(separator: "\n")
            }
        }
    }

    private func buildTemplate() -> TemplateInfo {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cmdInfos = commands.map { cmd in
            TemplateCommandInfo(
                id: cmd.id.isEmpty ? UUID().uuidString : cmd.id,
                name: cmd.name,
                icon: cmd.icon.isEmpty ? "terminal" : cmd.icon,
                command: cmd.command,
                blocking: cmd.blocking,
                interactive: cmd.interactive
            )
        }
        let envVars: [[String]] = envVarsText.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "=")
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            return [key, value]
        }
        return TemplateInfo(
            id: template?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            description: description,
            tags: tags,
            commands: cmdInfos,
            envVars: envVars,
            builtin: false
        )
    }
}

/// 编辑用临时命令模型
private final class EditableTemplateCommand: ObservableObject, Identifiable {
    let id: String
    @Published var name: String
    @Published var icon: String
    @Published var command: String
    @Published var blocking: Bool
    @Published var interactive: Bool

    init() {
        id = UUID().uuidString
        name = ""
        icon = ""
        command = ""
        blocking = true
        interactive = false
    }

    init(from info: TemplateCommandInfo) {
        id = info.id
        name = info.name
        icon = info.icon
        command = info.command
        blocking = info.blocking
        interactive = info.interactive
    }
}
