import SwiftUI
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - 设置页面主视图

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
        }
        .frame(width: 550, height: 400)
    }
}

// MARK: - 自定义命令配置部分

struct CustomCommandsSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var localizationManager: LocalizationManager
    @State private var editingCommand: CustomCommand?
    @State private var showingAddSheet = false

    var body: some View {
        Form {
            Section {
                Picker("settings.language".localized, selection: $localizationManager.appLanguage) {
                    Text("settings.language.system".localized).tag("system")
                    Text("settings.language.zh".localized).tag("zh-Hans")
                    Text("settings.language.en".localized).tag("en")
                }
            } header: {
                Text("settings.language".localized)
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

// MARK: - 命令编辑弹窗

struct CommandEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var command: CustomCommand
    let isNew: Bool
    let onSave: (CustomCommand) -> Void

    @State private var showIconPicker = false

    init(command: CustomCommand, isNew: Bool, onSave: @escaping (CustomCommand) -> Void) {
        _command = State(initialValue: command)
        self.isNew = isNew
        self.onSave = onSave
    }

    /// 当前选择的品牌图标
    private var selectedBrand: BrandIcon? {
        guard command.icon.hasPrefix("brand:") else { return nil }
        let brandName = String(command.icon.dropFirst(6))
        return BrandIcon(rawValue: brandName)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    // 图标在前
                    LabeledContent("settings.icon".localized) {
                        Button(action: { showIconPicker = true }) {
                            HStack(spacing: 4) {
                                CommandIconView(iconName: command.icon, size: 16)
                                Text("settings.icon.choose".localized)
                                    .font(.subheadline)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    // 名称在后
                    TextField("settings.name".localized, text: $command.name)
                }

                // 当选择品牌图标且有 AI Agent 时显示建议配置
                if let brand = selectedBrand, brand.hasAIAgent {
                    Section("settings.suggestedConfig".localized) {
                        if let cmd = brand.suggestedCommand {
                            HStack {
                                Text("settings.normalMode".localized)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(cmd)
                                    .font(.system(.body, design: .monospaced))
                                Button("common.use".localized) {
                                    command.command = cmd
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        if let yolo = brand.yoloCommand {
                            HStack {
                                Text("settings.yoloMode".localized)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(yolo)
                                    .font(.system(.body, design: .monospaced))
                                Button("common.use".localized) {
                                    command.command = yolo
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Section("settings.command".localized) {
                    TextEditor(text: $command.command)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                        )
                }
            }
            .formStyle(.grouped)

            // 底部按钮
            HStack {
                Button("common.cancel".localized) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(isNew ? "common.add".localized : "common.save".localized) {
                    onSave(command)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(command.name.isEmpty || command.command.isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 480)
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(selectedIcon: $command.icon)
        }
        .onChange(of: command.icon) { _, newIcon in
            // 选择品牌图标时自动填充名称
            if newIcon.hasPrefix("brand:") {
                let brandName = String(newIcon.dropFirst(6))
                if let brand = BrandIcon(rawValue: brandName) {
                    command.name = brand.displayName
                }
            }
        }
    }
}

// MARK: - 图标选择器

struct IconPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedIcon: String
    
    // 内置 SF Symbol 图标
    private let builtInIcons = [
        "terminal",
        "terminal.fill",
        "apple.terminal",
        "apple.terminal.fill",
        "chevron.left.forwardslash.chevron.right",
        "cursorarrow.rays",
        "sparkles",
        "brain",
        "brain.head.profile",
        "cpu",
        "server.rack",
        "network",
        "externaldrive",
        "doc.text",
        "folder",
        "gear",
        "wrench.and.screwdriver",
        "hammer",
        "ant",
        "ladybug",
        "play.circle",
        "bolt",
        "wand.and.stars"
    ]
    
    // 自定义图标（从 ~/.tidyflow/assets 加载）
    @State private var customIcons: [String] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text("settings.iconPicker.title".localized)
                    .font(.headline)
                Spacer()
                Button("common.done".localized) { dismiss() }
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 内置图标
                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.iconPicker.system".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 8), spacing: 8) {
                            ForEach(builtInIcons, id: \.self) { icon in
                                iconButton(icon: icon, isCustom: false)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // 品牌图标
                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.iconPicker.brand".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 8), spacing: 8) {
                            ForEach(BrandIcon.allCases, id: \.rawValue) { brand in
                                brandIconButton(brand: brand)
                            }
                        }
                    }
                    
                    // 自定义图标
                    if !customIcons.isEmpty {
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("settings.iconPicker.custom".localized)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 8), spacing: 8) {
                                ForEach(customIcons, id: \.self) { icon in
                                    iconButton(icon: icon, isCustom: true)
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    // 上传自定义图标按钮
                    Button(action: uploadCustomIcon) {
                        Label("settings.iconPicker.upload".localized, systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
        }
        .frame(width: 450, height: 400)
        .onAppear {
            loadCustomIcons()
        }
    }
    
    private func iconButton(icon: String, isCustom: Bool) -> some View {
        Button(action: {
            selectedIcon = isCustom ? "custom:\(icon)" : icon
            dismiss()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedIcon == (isCustom ? "custom:\(icon)" : icon) 
                          ? Color.accentColor.opacity(0.2) 
                          : Color(NSColor.controlBackgroundColor))
                    .frame(width: 40, height: 40)
                
                if isCustom {
                    // 自定义图标 - 从文件加载
                    if let image = loadCustomIconImage(icon) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }
                } else {
                    // SF Symbol
                    Image(systemName: icon)
                        .font(.system(size: 18))
                }
            }
        }
        .buttonStyle(.plain)
    }
    
    private func brandIconButton(brand: BrandIcon) -> some View {
        Button(action: {
            selectedIcon = "brand:\(brand.rawValue)"
            dismiss()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedIcon == "brand:\(brand.rawValue)" 
                          ? Color.accentColor.opacity(0.2) 
                          : Color(NSColor.controlBackgroundColor))
                    .frame(width: 40, height: 40)
                
                Image(brand.assetName)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            }
        }
        .buttonStyle(.plain)
        .help(brand.displayName)
    }
    
    private func loadCustomIcons() {
        let assetsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tidyflow/assets")
        
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: assetsPath,
            includingPropertiesForKeys: nil
        ) else { return }
        
        customIcons = contents
            .filter { $0.pathExtension == "png" || $0.pathExtension == "jpg" || $0.pathExtension == "jpeg" }
            .map { $0.lastPathComponent }
    }
    
    private func loadCustomIconImage(_ filename: String) -> NSImage? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tidyflow/assets/\(filename)")
        return NSImage(contentsOf: path)
    }
    
    private func uploadCustomIcon() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = "settings.iconPicker.uploadMessage".localized
        
        if panel.runModal() == .OK, let url = panel.url {
            // 创建 assets 目录
            let assetsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".tidyflow/assets")
            try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            
            // 复制文件
            let destURL = assetsDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: destURL)
            
            // 刷新列表
            loadCustomIcons()
            
            // 选中新上传的图标
            selectedIcon = "custom:\(url.lastPathComponent)"
        }
        #endif
    }
}

// MARK: - 命令图标视图

struct CommandIconView: View {
    let iconName: String
    let size: CGFloat
    
    var body: some View {
        Group {
            if iconName.hasPrefix("brand:") {
                // 品牌图标
                let brandName = String(iconName.dropFirst(6))
                if let brand = BrandIcon(rawValue: brandName) {
                    Image(brand.assetName)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                } else {
                    fallbackIcon
                }
            } else if iconName.hasPrefix("custom:") {
                // 自定义图标
                let filename = String(iconName.dropFirst(7))
                if let image = loadCustomIconImage(filename) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                } else {
                    fallbackIcon
                }
            } else {
                // SF Symbol
                Image(systemName: iconName)
                    .font(.system(size: size * 0.7))
                    .frame(width: size, height: size)
            }
        }
    }
    
    private var fallbackIcon: some View {
        Image(systemName: "terminal")
            .font(.system(size: size * 0.7))
            .frame(width: size, height: size)
    }
    
    private func loadCustomIconImage(_ filename: String) -> NSImage? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tidyflow/assets/\(filename)")
        return NSImage(contentsOf: path)
    }
}

// BrandIcon 枚举定义在 Models.swift 中

// MARK: - AI Agent 配置部分

struct AIAgentSection: View {
    @EnvironmentObject var appState: AppState
    @State private var agentStatus: [AIAgent: Bool] = [:]
    @State private var isDetecting = false

    var body: some View {
        Form {
            Section {
                ForEach(AIAgent.allCases) { agent in
                    HStack(spacing: 12) {
                        // 品牌图标
                        Image(agent.brandIcon.assetName)
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)

                        // 名称
                        Text(agent.displayName)
                            .font(.system(size: 13, weight: .medium))

                        Spacer()

                        // 状态
                        if isDetecting {
                            ProgressView()
                                .controlSize(.small)
                        } else if let available = agentStatus[agent] {
                            if available {
                                if appState.clientSettings.selectedAIAgent == agent.rawValue {
                                    // 已选中
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                        .font(.system(size: 16))
                                } else {
                                    // 已安装但未选中
                                    Button("common.use".localized) {
                                        appState.clientSettings.selectedAIAgent = agent.rawValue
                                        appState.saveClientSettings()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            } else {
                                Text("settings.aiAgent.notInstalled".localized)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("settings.aiAgent.title".localized)
            } footer: {
                Text("settings.aiAgent.footer".localized)
            }

            Section {
                Button(action: { detectAgents() }) {
                    Label("settings.aiAgent.redetect".localized, systemImage: "arrow.clockwise")
                }
                .disabled(isDetecting)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if agentStatus.isEmpty {
                detectAgents()
            }
        }
    }

    private func detectAgents() {
        isDetecting = true
        Task {
            let results = await AIAgentDetector.detectAll()
            await MainActor.run {
                agentStatus = results
                isDetecting = false
            }
        }
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
