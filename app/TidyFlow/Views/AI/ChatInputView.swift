import SwiftUI
#if os(iOS)
import UIKit
#if canImport(PhotosUI)
import PhotosUI
#endif
#endif
#if os(macOS)
import AppKit
#endif
struct ChatInputView: View {
    @Binding var text: String
    @Binding var imageAttachments: [ImageAttachment]
    var isStreaming: Bool
    /// iOS: 视图出现后自动聚焦输入框。
    var autoFocusOnAppear: Bool = false
    /// 仅当已有 sessionId 时允许点击停止，避免会话创建竞态下误触。
    var canStopStreaming: Bool = true
    var onSend: () -> Void
    var onStop: () -> Void

    // 模型 / Agent 状态
    var providers: [AIProviderInfo]
    @Binding var selectedModel: AIModelSelection?
    var agents: [AIAgentInfo]
    @Binding var selectedAgent: String?
    var isLoadingModels: Bool = false
    var isLoadingAgents: Bool = false

    // 自动补全
    var autocomplete: AutocompleteState?
    var onSelectAutocomplete: ((AutocompleteItem) -> Void)?
    /// iOS 输入辅助：命令列表
    var slashCommands: [AISlashCommandInfo] = []
    /// iOS 输入辅助：引用列表（文件路径）
    var fileReferenceItems: [String] = []
    /// iOS 输入辅助：打开引用列表前按需拉取索引
    var onRequestFileReferences: (() -> Void)?
    /// iOS 输入辅助：引用搜索词变化时触发实时查询
    var onSearchFileReferences: ((String) -> Void)?
    /// 输入上下文变化（光标 UTF16 位置, 是否处于 IME 组合态）
    var onInputContextChange: ((Int, Bool) -> Void)?
    /// 光标位置（外部读取用于定位弹出层）
    @Binding var cursorRectInInput: CGRect

    @State private var textContentHeight: CGFloat = 28
    /// 光标在输入框内的位置（由 NSTextView 上报）
    @State private var cursorRect: CGRect = .zero
    #if os(iOS)
    private enum IOSInputPanelSheet: String, Identifiable {
        case commands
        case references
        var id: String { rawValue }
    }

    @FocusState private var isIOSInputFocused: Bool
    @State private var showIOSInputPanel: Bool = false
    @State private var iOSInputPanelSheet: IOSInputPanelSheet?
    @State private var commandSearchText: String = ""
    @State private var referenceSearchText: String = ""
    #endif
    #if os(iOS) && canImport(PhotosUI)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
    }
    #if os(macOS)
    private let maxImageAttachmentCount = 9
    #endif

    private var inputEditorBackgroundColor: Color {
        #if os(iOS)
        return Color(UIColor.secondarySystemBackground)
        #else
        return Color.secondary.opacity(0.08)
        #endif
    }

    private var inputEditorBorderColor: Color {
        #if os(iOS)
        return Color.white.opacity(0.15)
        #else
        return Color.secondary.opacity(0.2)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            // 图片缩略图预览行
            if !imageAttachments.isEmpty {
                imagePreviewRow
            }

            #if os(iOS)
            iOSInputSection
            #else
            // 输入区域
            inputEditor

            // 工具栏
            toolbar
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        #if os(iOS)
        .padding(.bottom, 0)
        #else
        .padding(.bottom, 12)
        #endif
        .onChange(of: cursorRect) { _, newRect in
            cursorRectInInput = newRect
        }
    }

    #if os(iOS)
    private var iOSInputSection: some View {
        VStack(spacing: 8) {
            iOSSelectorRow

            HStack(alignment: .center, spacing: 10) {
                iOSInputModeToggleButton

                inputEditor
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 36)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(inputEditorBackgroundColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(inputEditorBorderColor, lineWidth: 0.5)
                    )

                sendOrStopButton
            }

            if showIOSInputPanel {
                iOSInputPanelGrid
            }
        }
        .padding(.bottom, 8)
        .onAppear {
            guard autoFocusOnAppear else { return }
            requestIOSInputFocus()
        }
        .onChange(of: isIOSInputFocused) { _, focused in
            if focused {
                showIOSInputPanel = false
            }
        }
        .sheet(item: $iOSInputPanelSheet) { item in
            switch item {
            case .commands:
                iOSCommandPickerSheet
            case .references:
                iOSReferencePickerSheet
            }
        }
    }

    @ViewBuilder
    private var iOSSelectorRow: some View {
        if isLoadingAgents || isLoadingModels || !agents.isEmpty || !providers.isEmpty {
            HStack(spacing: 8) {
                agentButton
                modelButton
                Spacer(minLength: 0)
            }
        }
    }

    private var iOSInputModeToggleButton: some View {
        Button(action: toggleIOSInputPanel) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(showIOSInputPanel ? Color.accentColor : Color.white.opacity(0.18))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var iOSInputPanelGrid: some View {
        let columns: [GridItem] = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
        return LazyVGrid(columns: columns, spacing: 8) {
            iOSImagePanelButton

            Button(action: {
                commandSearchText = ""
                openIOSInputSheet(.commands)
            }) {
                iOSInputPanelTile(
                    title: "命令",
                    systemImage: "command",
                    tint: .orange
                )
            }
            .buttonStyle(.plain)

            Button(action: {
                referenceSearchText = ""
                onRequestFileReferences?()
                openIOSInputSheet(.references)
            }) {
                iOSInputPanelTile(
                    title: "引用",
                    systemImage: "at",
                    tint: .green
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var iOSImagePanelButton: some View {
        #if canImport(PhotosUI)
        PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: 6,
            matching: .images
        ) {
            iOSInputPanelTile(
                title: "图片",
                systemImage: "photo",
                tint: .blue
            )
        }
        .onChange(of: selectedPhotoItems) { _, items in
            handleSelectedPhotoItems(items)
        }
        #else
        Button(action: pickImage) {
            iOSInputPanelTile(
                title: "图片",
                systemImage: "photo",
                tint: .blue
            )
        }
        .buttonStyle(.plain)
        #endif
    }

    private func iOSInputPanelTile(
        title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var filteredSlashCommandsForIOS: [AISlashCommandInfo] {
        let query = commandSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return slashCommands }
        return slashCommands.filter { command in
            command.name.localizedCaseInsensitiveContains(query)
                || command.description.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredFileReferencesForIOS: [String] {
        let query = referenceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return fileReferenceItems }
        return fileReferenceItems.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var iOSCommandPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    IOSAutoFocusTextField(text: $commandSearchText, placeholder: "搜索命令")
                        .frame(height: 22)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)

                List(filteredSlashCommandsForIOS, id: \.id) { command in
                    Button(action: {
                        insertSlashCommandAtInputStart(command.name)
                        iOSInputPanelSheet = nil
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: slashCommandIcon(command.name))
                                .frame(width: 18)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("/\(command.name)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.primary)
                                if !command.description.isEmpty {
                                    Text(command.description)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        iOSInputPanelSheet = nil
                    }) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
    }

    private var iOSReferencePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    IOSAutoFocusTextField(text: $referenceSearchText, placeholder: "搜索引用")
                        .frame(height: 22)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)

                List(filteredFileReferencesForIOS, id: \.self) { path in
                    Button(action: {
                        appendFileReferenceToInput(path)
                        iOSInputPanelSheet = nil
                    }) {
                        Text(path)
                            .font(.system(size: 13))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("引用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        iOSInputPanelSheet = nil
                    }) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭")
                }
            }
            .onAppear {
                onSearchFileReferences?(referenceSearchText)
            }
            .onChange(of: referenceSearchText) { _, query in
                onSearchFileReferences?(query)
            }
        }
    }

    private func openIOSInputSheet(_ sheet: IOSInputPanelSheet) {
        // 先让主输入框失焦，sheet 内的 IOSAutoFocusTextField 会通过 UIKit
        // becomeFirstResponder() 自动接管键盘，无需 dismissIOSKeyboard()。
        isIOSInputFocused = false
        showIOSInputPanel = false
        iOSInputPanelSheet = sheet
    }

    private func toggleIOSInputPanel() {
        if showIOSInputPanel {
            showIOSInputPanel = false
            isIOSInputFocused = true
        } else {
            showIOSInputPanel = true
            isIOSInputFocused = false
        }
    }

    private func requestIOSInputFocus() {
        showIOSInputPanel = false
        // 进入页面时多次尝试，覆盖导航动画和键盘系统时序。
        for delay in [0.0, 0.12, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard iOSInputPanelSheet == nil else { return }
                isIOSInputFocused = true
            }
        }
    }

    private func insertSlashCommandAtInputStart(_ commandName: String) {
        let prefix = "/\(commandName)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            text = "\(prefix) "
            return
        }
        text = "\(prefix) \(text)"
    }

    private func appendFileReferenceToInput(_ path: String) {
        let token = "@\(path)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            text = "\(token) "
            return
        }
        if text.hasSuffix(" ") || text.hasSuffix("\n") {
            text += "\(token) "
        } else {
            text += " \(token) "
        }
    }
    #endif

    // MARK: - 图片预览行

    private var imagePreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(imageAttachments) { attachment in
                    imagePreviewItem(attachment)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func imagePreviewItem(_ attachment: ImageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            #if os(macOS)
            Image(nsImage: attachment.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 60)
                .cornerRadius(8)
                .clipped()
            #else
            if let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    )
            }
            #endif

            Button(action: {
                imageAttachments.removeAll { $0.id == attachment.id }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)).frame(width: 18, height: 18))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    // MARK: - 输入编辑器

    private var inputEditor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Group {
                    #if os(iOS)
                    Text("输入消息...")
                    #else
                    Text("输入消息...  @ 引用文件  / 斜杠命令")
                    #endif
                }
                    .foregroundColor(.secondary.opacity(0.6))
                    .font(.system(size: 13))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            #if os(macOS)
            ChatTextView(
                text: $text,
                contentHeight: $textContentHeight,
                cursorRect: $cursorRect,
                font: .systemFont(ofSize: 13),
                onEnter: {
                    imeDebugLog("ChatInputView.onEnter start text=\(text.debugDescription) canSend=\(canSend) isStreaming=\(isStreaming) autocompleteVisible=\(autocomplete?.isVisible == true)")
                    // 弹出层可见时，Enter 选择当前项
                    if let ac = autocomplete, ac.isVisible, let item = ac.selectedItem {
                        imeDebugLog("ChatInputView.onEnter select autocomplete item=\(item.value)")
                        onSelectAutocomplete?(item)
                        return
                    }
                    if canSend && !isStreaming {
                        imeDebugLog("ChatInputView.onEnter call onSend")
                        onSend()
                    } else {
                        imeDebugLog("ChatInputView.onEnter ignored canSend=\(canSend) isStreaming=\(isStreaming)")
                    }
                },
                isEnterEnabled: { [canSend, isStreaming] in
                    if let ac = autocomplete, ac.isVisible { return true }
                    return canSend && !isStreaming
                },
                onArrowUp: { autocomplete?.isVisible == true ? { autocomplete?.moveUp(); return true }() : false },
                onArrowDown: { autocomplete?.isVisible == true ? { autocomplete?.moveDown(); return true }() : false },
                onEscape: { autocomplete?.isVisible == true ? { autocomplete?.reset(); return true }() : false },
                onTab: {
                    guard let ac = autocomplete, ac.isVisible, let item = ac.selectedItem else { return false }
                    onSelectAutocomplete?(item)
                    return true
                },
                onPaste: {
                    handleMacOSPasteImages()
                },
                onInputContextChange: onInputContextChange
            )
            .frame(height: min(max(textContentHeight, 28), 80))
            #else
            TextField("", text: $text, axis: .vertical)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($isIOSInputFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .onTapGesture {
                    if !isIOSInputFocused {
                        isIOSInputFocused = true
                    }
                }
            #endif
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            // 左侧：Agent 切换 + 模型选择
            agentButton
            modelButton

            Spacer()

            // 右侧：图片上传 + 发送/停止
            imageUploadButton
            sendOrStopButton
        }
        .padding(.top, 8)
    }

    // MARK: - Agent 切换按钮

    private var agentButton: some View {
        Group {
            if isLoadingAgents {
                loadingPlaceholder
            } else if !agents.isEmpty {
                Menu {
                    ForEach(agents) { agent in
                        Button(action: {
                            selectedAgent = agent.name
                            // 自动切换到 agent 默认模型
                            if let pid = agent.defaultProviderID,
                               let mid = agent.defaultModelID,
                               !pid.isEmpty, !mid.isEmpty {
                                selectedModel = AIModelSelection(providerID: pid, modelID: mid)
                            }
                        }) {
                            HStack {
                                Text(agent.name)
                                if let desc = agent.description, !desc.isEmpty {
                                    Text("— \(desc)")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                        Text(selectedAgent ?? agents.first?.name ?? "Agent")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: selectorLabelMaxWidth, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                    .foregroundStyle(dropdownPrimaryTextColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - 模型选择按钮

    private var modelButton: some View {
        Group {
            if isLoadingModels {
                loadingPlaceholder
            } else if !providers.isEmpty {
                Menu {
                    if availableModelProviders.count <= 1 {
                        if let onlyProvider = availableModelProviders.first {
                            ForEach(onlyProvider.models) { model in
                                Button(action: {
                                    selectedModel = AIModelSelection(providerID: onlyProvider.id, modelID: model.id)
                                }) {
                                    Text(model.name)
                                }
                            }
                        } else {
                            Text("暂无可用模型")
                        }
                    } else {
                        ForEach(availableModelProviders) { provider in
                            Menu(provider.name) {
                                ForEach(provider.models) { model in
                                    Button(action: {
                                        selectedModel = AIModelSelection(providerID: provider.id, modelID: model.id)
                                    }) {
                                        Text(model.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11))
                        Text(selectedModelDisplayName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .frame(maxWidth: selectorLabelMaxWidth, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                    .foregroundStyle(dropdownPrimaryTextColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// 仅保留有模型的提供商，避免展示空菜单。
    private var availableModelProviders: [AIProviderInfo] {
        providers.filter { !$0.models.isEmpty }
    }

    private var selectedModelDisplayName: String {
        guard let sel = selectedModel else { return "模型" }
        for p in providers {
            if let m = p.models.first(where: { $0.id == sel.modelID && p.id == sel.providerID }) {
                return m.name
            }
        }
        return sel.modelID
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 4) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
            Text("加载中...")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: selectorLabelMaxWidth, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }

    private func slashCommandIcon(_ name: String) -> String {
        switch name {
        case "new":
            return "square.and.pencil"
        default:
            return "command"
        }
    }

    // MARK: - 图片上传按钮

    @ViewBuilder
    private var imageUploadButton: some View {
        #if os(iOS) && canImport(PhotosUI)
        PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: 6,
            matching: .images
        ) {
            Image(systemName: "photo")
                .font(.system(size: actionIconFontSize, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                .background(Color.white.opacity(0.18))
                .clipShape(Circle())
        }
        .onChange(of: selectedPhotoItems) { _, items in
            handleSelectedPhotoItems(items)
        }
        #else
        Button(action: pickImage) {
            Image(systemName: "photo")
                .font(.system(size: actionIconFontSize, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("上传图片")
        #endif
    }

    #if os(iOS) && canImport(PhotosUI)
    private func handleSelectedPhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let fileInfo = detectImageFileInfo(data: data)
                let suffix = UUID().uuidString.prefix(8)
                let filename = "image_\(suffix).\(fileInfo.ext)"
                let attachment = ImageAttachment(filename: filename, data: data, mime: fileInfo.mime)
                await MainActor.run {
                    imageAttachments.append(attachment)
                }
            }
            await MainActor.run {
                selectedPhotoItems = []
            }
        }
    }
    #endif

    private func pickImage() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.lowercased()
                let mime: String
                switch ext {
                case "png": mime = "image/png"
                case "jpg", "jpeg": mime = "image/jpeg"
                case "gif": mime = "image/gif"
                case "webp": mime = "image/webp"
                default: mime = "image/png"
                }
                let attachment = ImageAttachment(
                    filename: url.lastPathComponent,
                    data: data,
                    mime: mime
                )
                DispatchQueue.main.async {
                    imageAttachments.append(attachment)
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private func handleMacOSPasteImages() -> Bool {
        let pasteboard = NSPasteboard.general
        let imageDataList = collectClipboardImageData(from: pasteboard, maxCount: maxImageAttachmentCount)
        guard !imageDataList.isEmpty else {
            return false
        }

        let remaining = max(0, maxImageAttachmentCount - imageAttachments.count)
        guard remaining > 0 else {
            return true
        }

        var appendedCount = 0
        for sourceData in imageDataList.prefix(remaining) {
            guard let jpegData = encodeClipboardImageAsJPEG(sourceData) else { continue }
            let suffix = UUID().uuidString.prefix(8)
            let filename = "clipboard_\(suffix).jpg"
            imageAttachments.append(
                ImageAttachment(
                    filename: filename,
                    data: jpegData,
                    mime: "image/jpeg"
                )
            )
            appendedCount += 1
        }

        return appendedCount > 0
    }

    private func collectClipboardImageData(from pasteboard: NSPasteboard, maxCount: Int) -> [Data] {
        var result: [Data] = []

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            for url in urls {
                guard isSupportedClipboardImageURL(url) else { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                result.append(data)
                if result.count >= maxCount {
                    return result
                }
            }
        }

        if let items = pasteboard.pasteboardItems, !items.isEmpty {
            let preferredTypes: [NSPasteboard.PasteboardType] = [
                .png,
                .tiff,
                NSPasteboard.PasteboardType("public.jpeg"),
                NSPasteboard.PasteboardType("public.heic"),
                NSPasteboard.PasteboardType("public.heif"),
                NSPasteboard.PasteboardType("com.compuserve.gif"),
                NSPasteboard.PasteboardType("org.webmproject.webp")
            ]

            for item in items {
                var appended = false
                for type in preferredTypes {
                    if let data = item.data(forType: type), !data.isEmpty {
                        result.append(data)
                        appended = true
                        break
                    }
                }
                if !appended,
                   let fileURLString = item.string(forType: .fileURL),
                   let url = URL(string: fileURLString),
                   isSupportedClipboardImageURL(url),
                   let data = try? Data(contentsOf: url) {
                    result.append(data)
                }
                if result.count >= maxCount {
                    return result
                }
            }
        }

        if result.isEmpty,
           let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in images {
                guard let tiffData = image.tiffRepresentation else { continue }
                result.append(tiffData)
                if result.count >= maxCount {
                    return result
                }
            }
        }

        return result
    }

    private func isSupportedClipboardImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let supported: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"
        ]
        return supported.contains(ext)
    }

    private func encodeClipboardImageAsJPEG(_ sourceData: Data) -> Data? {
        if let bitmap = NSBitmapImageRep(data: sourceData),
           let encoded = bitmap.representation(
               using: .jpeg,
               properties: [.compressionFactor: 0.85]
           ) {
            return encoded
        }

        guard let image = NSImage(data: sourceData),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let encoded = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.85]
              ) else {
            return nil
        }
        return encoded
    }
    #endif

    /// 根据文件头推断图片 MIME 与扩展名
    private func detectImageFileInfo(data: Data) -> (mime: String, ext: String) {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return ("image/png", "png")
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return ("image/jpeg", "jpg")
        }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return ("image/gif", "gif")
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return ("image/webp", "webp")
        }
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii)?.lowercased() ?? ""
            if brand.hasPrefix("hei") || brand.hasPrefix("hev") {
                return ("image/heic", "heic")
            }
            if brand == "mif1" || brand == "msf1" {
                return ("image/heif", "heif")
            }
        }
        return ("application/octet-stream", "bin")
    }

    private var dropdownPrimaryTextColor: Color {
        #if os(iOS)
        return .white
        #else
        return .primary
        #endif
    }

    private var dropdownSecondaryTextColor: Color {
        #if os(iOS)
        return .white.opacity(0.72)
        #else
        return .secondary
        #endif
    }

    private var selectorLabelMaxWidth: CGFloat {
        #if os(iOS)
        return 140
        #else
        return 180
        #endif
    }

    private var actionButtonDiameter: CGFloat {
        #if os(iOS)
        return 36
        #else
        return 28
        #endif
    }

    private var actionIconFontSize: CGFloat {
        #if os(iOS)
        return 16
        #else
        return 13
        #endif
    }

    // MARK: - 发送/停止按钮

    private var sendOrStopButton: some View {
        Group {
            if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: actionIconFontSize, weight: .bold))
                        .foregroundColor(canStopStreaming ? .white : .white.opacity(0.72))
                        .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                        .background(canStopStreaming ? Color.red : Color.gray.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canStopStreaming)
                .help(canStopStreaming ? "停止生成" : "会话创建中，暂不可停止")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: actionIconFontSize, weight: .bold))
                        .foregroundColor(canSend ? .white : .white.opacity(0.72))
                        .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                        .background(canSend ? Color.accentColor : Color.gray.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("发送")
            }
        }
    }
}

#Preview {
    VStack {
        ChatInputView(
            text: .constant("Hello"),
            imageAttachments: .constant([]),
            isStreaming: false,
            onSend: {},
            onStop: {},
            providers: [],
            selectedModel: .constant(nil),
            agents: [],
            selectedAgent: .constant(nil),
            autocomplete: nil,
            onSelectAutocomplete: nil,
            onInputContextChange: nil,
            cursorRectInInput: .constant(.zero)
        )

        ChatInputView(
            text: .constant(""),
            imageAttachments: .constant([]),
            isStreaming: true,
            onSend: {},
            onStop: {},
            providers: [],
            selectedModel: .constant(nil),
            agents: [],
            selectedAgent: .constant(nil),
            autocomplete: nil,
            onSelectAutocomplete: nil,
            onInputContextChange: nil,
            cursorRectInInput: .constant(.zero)
        )
    }
    .padding()
    .frame(width: 500)
}
