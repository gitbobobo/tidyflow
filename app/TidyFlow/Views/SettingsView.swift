import SwiftUI
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - 设置页面主视图

struct SettingsContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 页面标题
                Text("设置")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.bottom, 8)
                
                // 自定义命令部分
                CustomCommandsSection()
                    .environmentObject(appState)
                
                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - 自定义命令配置部分

struct CustomCommandsSection: View {
    @EnvironmentObject var appState: AppState
    @State private var editingCommand: CustomCommand?
    @State private var showingAddSheet = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题和添加按钮
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("自定义终端命令")
                        .font(.headline)
                    Text("配置快捷命令，在新建终端时快速执行")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { showingAddSheet = true }) {
                    Label("添加命令", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            
            // 命令列表
            if appState.clientSettings.customCommands.isEmpty {
                emptyStateView
            } else {
                commandListView
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
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
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))
            Text("暂无自定义命令")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("点击「添加命令」创建你的第一个快捷命令")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
    
    private var commandListView: some View {
        VStack(spacing: 8) {
            ForEach(appState.clientSettings.customCommands) { command in
                CustomCommandRow(
                    command: command,
                    onEdit: { editingCommand = command },
                    onDelete: { appState.deleteCustomCommand(id: command.id) }
                )
            }
        }
    }
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
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("编辑")
                
                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("删除")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
        .alert("删除命令", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) { onDelete() }
        } message: {
            Text("确定要删除命令「\(command.name)」吗？")
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
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(isNew ? "添加命令" : "编辑命令")
                    .font(.headline)
                Spacer()
            }
            .padding()
            
            Divider()
            
            // 表单内容
            Form {
                // 图标选择
                HStack {
                    Text("图标")
                    Spacer()
                    Button(action: { showIconPicker = true }) {
                        HStack(spacing: 8) {
                            CommandIconView(iconName: command.icon, size: 20)
                            Text("选择图标")
                                .font(.system(size: 12))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                
                // 名称
                TextField("名称", text: $command.name)
                    .textFieldStyle(.roundedBorder)
                
                // 命令
                VStack(alignment: .leading, spacing: 4) {
                    Text("命令")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $command.command)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 80)
                        .border(Color(NSColor.separatorColor), width: 1)
                }
            }
            .formStyle(.grouped)
            .padding()
            
            Divider()
            
            // 底部按钮
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(isNew ? "添加" : "保存") {
                    onSave(command)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(command.name.isEmpty || command.command.isEmpty)
            }
            .padding()
        }
        .frame(width: 450, height: 420)
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(selectedIcon: $command.icon)
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
                Text("选择图标")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 内置图标
                    VStack(alignment: .leading, spacing: 8) {
                        Text("系统图标")
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
                        Text("品牌图标")
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
                            Text("自定义图标")
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
                        Label("上传图标", systemImage: "plus.circle")
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
        panel.message = "选择图标文件（推荐 32x32 或 64x64 PNG）"
        
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
