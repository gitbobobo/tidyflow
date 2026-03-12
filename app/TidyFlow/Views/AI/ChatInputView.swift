import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

private struct AIChatInputPasteHandlerKey: FocusedValueKey {
    typealias Value = () -> Bool
}

extension FocusedValues {
    var aiChatInputPasteHandler: (() -> Bool)? {
        get { self[AIChatInputPasteHandlerKey.self] }
        set { self[AIChatInputPasteHandlerKey.self] = newValue }
    }
}
#endif

#if os(iOS)
import UIKit
#endif

#if os(iOS) && canImport(PhotosUI)
import PhotosUI
#endif

struct ChatInputView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var text: String
    @Binding var imageAttachments: [ImageAttachment]

    var isStreaming: Bool
    var autoFocusOnAppear: Bool = false
    var canStopStreaming: Bool = true
    var isSendingPending: Bool = false
    var onSend: () -> Void
    var onStop: () -> Void

    var providers: [AIProviderInfo]
    @Binding var selectedModel: AIModelSelection?
    var contextRemainingPercent: Double?
    var agents: [AIAgentInfo]
    @Binding var selectedAgent: String?
    var modelVariantOptions: [String] = []
    @Binding var selectedModelVariant: String?
    var isLoadingModels: Bool = false
    var isLoadingAgents: Bool = false

    var autocomplete: AutocompleteState?
    var onSelectAutocomplete: ((AutocompleteItem) -> Void)?
    var onTriggerCodeCompletion: ((String, String?, String?) -> Void)?
    var onAcceptCodeCompletion: (() -> Void)?
    var slashCommands: [AISlashCommandInfo] = []
    var fileReferenceItems: [String] = []
    var onRequestFileReferences: (() -> Void)?
    var onSearchFileReferences: ((String) -> Void)?
    var projectNames: [String] = []
    var onInputContextChange: ((Int, Bool) -> Void)?

    @State private var textSelection: TextSelection?
    @FocusState private var inputFocused: Bool
    @State private var lastKnownInputOffset = 0

    #if os(iOS)
    private enum IOSInputPanelSheet: String, Identifiable {
        case commands
        case references

        var id: String { rawValue }
    }

    @State private var showIOSInputPanel = false
    @State private var iOSInputPanelSheet: IOSInputPanelSheet?
    @State private var commandSearchText = ""
    @State private var referenceSearchText = ""
    @FocusState private var commandSearchFocused: Bool
    @FocusState private var referenceSearchFocused: Bool
    #endif

    #if os(iOS) && canImport(PhotosUI)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    @State private var showImageImporter = false
    private let maxImageAttachmentCount = 9

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
    }

    var body: some View {
        composerCard
            .padding(.horizontal, outerHorizontalPadding)
            .padding(.top, outerTopPadding)
            .padding(.bottom, outerBottomPadding)
            #if os(macOS)
            .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: nil) { providers in
                handleDroppedImageProviders(providers)
            }
            .fileImporter(
                isPresented: $showImageImporter,
                allowedContentTypes: [.png, .jpeg, .gif, .webP, .heic, .heif, .tiff, .bmp],
                allowsMultipleSelection: true,
                onCompletion: handleImageImport
            )
            #endif
            .accessibilityIdentifier("tf.ai.input.container")
            #if os(macOS)
            .focusedSceneValue(\.aiChatInputPasteHandler, inputFocused ? handleFocusedPaste : nil)
            #endif
            .onAppear {
                guard autoFocusOnAppear else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    inputFocused = true
                }
            }
            .onChange(of: textSelection) { _, selection in
                publishInputContextChange(text: text, selection: selection)
            }
            .onChange(of: text) { _, newText in
                publishInputContextChange(text: newText, selection: textSelection)
            }
    }

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: cardContentSpacing) {
            if !imageAttachments.isEmpty {
                imagePreviewRow
            }

            #if os(iOS)
            iOSInputSection
            #else
            inputEditorPanel
            toolbar
            #endif
        }
        .padding(.horizontal, cardHorizontalPadding)
        .padding(.top, cardTopPadding)
        .padding(.bottom, cardBottomPadding)
        .modifier(
            AIChatFloatingComposerChrome(
                colorScheme: colorScheme,
                cornerRadius: floatingCardCornerRadius,
                fallbackBackgroundColor: floatingCardBackgroundColor,
                fallbackBorderColor: floatingCardBorderColor,
                primaryShadowColor: floatingCardPrimaryShadowColor,
                secondaryShadowColor: floatingCardSecondaryShadowColor
            )
        )
    }

    #if os(iOS)
    private var iOSInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputEditorPanel
            iOSFloatingToolbar
            if showIOSInputPanel {
                iOSInputPanelGrid
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
        .onChange(of: inputFocused) { _, focused in
            if focused {
                showIOSInputPanel = false
            }
        }
    }

    private var iOSFloatingToolbar: some View {
        HStack(alignment: .center, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    iOSInputModeToggleButton
                    agentButton
                    modelButton
                    modelVariantButton
                    contextRemainingRing
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            sendOrStopButton
        }
    }

    private var iOSInputModeToggleButton: some View {
        Button(action: toggleIOSInputPanel) {
            Image(systemName: "plus")
                .font(.system(size: accessoryIconFontSize, weight: .semibold))
                .foregroundStyle(showIOSInputPanel ? .white : .secondary)
                .frame(width: accessoryButtonDiameter, height: accessoryButtonDiameter)
                .background(showIOSInputPanel ? Color.accentColor : toolbarChipBackgroundColor)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(showIOSInputPanel ? Color.clear : toolbarChipBorderColor, lineWidth: 0.6)
                }
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
                iOSInputPanelTile(title: "命令", systemImage: "command", tint: .orange)
            }
            .buttonStyle(.plain)

            Button(action: {
                referenceSearchText = ""
                onRequestFileReferences?()
                openIOSInputSheet(.references)
            }) {
                iOSInputPanelTile(title: "引用", systemImage: "at", tint: .green)
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
            iOSInputPanelTile(title: "图片", systemImage: "photo", tint: .blue)
        }
        .onChange(of: selectedPhotoItems) { _, items in
            handleSelectedPhotoItems(items)
        }
        #else
        Button(action: pickImage) {
            iOSInputPanelTile(title: "图片", systemImage: "photo", tint: .blue)
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
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(toolbarChipBackgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(toolbarChipBorderColor, lineWidth: 0.5)
        }
    }

    private var filteredSlashCommandsForIOS: [AISlashCommandInfo] {
        let query = commandSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return slashCommands }
        return slashCommands.filter { command in
            command.name.localizedStandardContains(query)
                || command.description.localizedStandardContains(query)
        }
    }

    private var filteredFileReferencesForIOS: [String] {
        let query = referenceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return fileReferenceItems }
        return fileReferenceItems.filter { $0.localizedStandardContains(query) }
    }

    private var iOSCommandPickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    TextField("搜索命令", text: $commandSearchText)
                        .focused($commandSearchFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    ForEach(filteredSlashCommandsForIOS, id: \.id) { command in
                        Button {
                            insertSlashCommandAtInputStart(command.name, inputHint: command.inputHint)
                            iOSInputPanelSheet = nil
                            inputFocused = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: slashCommandIcon(command.name))
                                    .frame(width: 18)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("/\(command.name)")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                    let detail = command.description.isEmpty ? (command.inputHint ?? "") : command.description
                                    if !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        iOSInputPanelSheet = nil
                        inputFocused = true
                    }
                }
            }
            .task {
                commandSearchFocused = true
            }
        }
    }

    private var iOSReferencePickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    TextField("搜索引用", text: $referenceSearchText)
                        .focused($referenceSearchFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    ForEach(filteredFileReferencesForIOS, id: \.self) { path in
                        Button {
                            appendFileReferenceToInput(path)
                            iOSInputPanelSheet = nil
                            inputFocused = true
                        } label: {
                            Text(path)
                                .font(.system(size: 13))
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("引用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        iOSInputPanelSheet = nil
                        inputFocused = true
                    }
                }
            }
            .task {
                onSearchFileReferences?(referenceSearchText)
                referenceSearchFocused = true
            }
            .onChange(of: referenceSearchText) { _, query in
                onSearchFileReferences?(query)
            }
        }
    }

    private func openIOSInputSheet(_ sheet: IOSInputPanelSheet) {
        inputFocused = false
        showIOSInputPanel = false
        iOSInputPanelSheet = sheet
    }

    private func toggleIOSInputPanel() {
        if showIOSInputPanel {
            showIOSInputPanel = false
            inputFocused = true
        } else {
            showIOSInputPanel = true
            inputFocused = false
        }
    }

    private func insertSlashCommandAtInputStart(_ commandName: String, inputHint: String?) {
        let normalizedHint = inputHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if let normalizedHint, !normalizedHint.isEmpty {
            body = "\(commandName) \(normalizedHint)"
        } else {
            body = commandName
        }
        let prefix = "/\(body)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = trimmed.isEmpty ? "\(prefix) " : "\(prefix) \(text)"
        updateSelectionToEnd()
    }

    private func appendFileReferenceToInput(_ path: String) {
        let token = "@\(path)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            text = "\(token) "
        } else if text.hasSuffix(" ") || text.hasSuffix("\n") {
            text += "\(token) "
        } else {
            text += " \(token) "
        }
        updateSelectionToEnd()
    }
    #endif

    private var imagePreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(imageAttachments) { attachment in
                    ImageAttachmentChip(attachment: attachment) {
                        imageAttachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
        }
    }

    private var inputEditorPanel: some View {
        inputEditor
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: editorMinHeight, alignment: .topLeading)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .background(editorSurfaceBackgroundColor, in: .rect(cornerRadius: editorSurfaceCornerRadius, style: .continuous))
            .clipShape(.rect(cornerRadius: editorSurfaceCornerRadius, style: .continuous))
            .contentShape(.rect)
            .onTapGesture {
                inputFocused = true
            }
    }

    private var inputEditor: some View {
        ZStack(alignment: .topLeading) {
            #if os(iOS)
            if text.isEmpty && !inputFocused {
                Text(placeholderText)
                    .foregroundStyle(.secondary.opacity(0.6))
                    .font(.system(size: editorFontSize))
                    .padding(.horizontal, editorHorizontalInset)
                    .padding(.vertical, editorVerticalInset)
                    .allowsHitTesting(false)
            }
            #endif

            #if os(iOS)
            IOSPasteAwareTextView(
                text: $text,
                isFocused: Binding(
                    get: { inputFocused },
                    set: { inputFocused = $0 }
                ),
                selectionOffset: textSelection?.utf16InsertionOffset(in: text),
                fontSize: editorFontSize,
                onSelectionChange: { location in
                    let clampedLocation = min(max(0, location), text.utf16.count)
                    let index = String.Index(utf16Offset: clampedLocation, in: text)
                    textSelection = TextSelection(insertionPoint: index)
                    lastKnownInputOffset = clampedLocation
                    onInputContextChange?(location, false)
                },
                onPasteProviders: handlePastedImageProviders
            )
            .frame(minHeight: editorCollapsedMinHeight, maxHeight: editorExpandedMaxHeight)
            .padding(.horizontal, editorHorizontalInset)
            .padding(.vertical, editorVerticalInset)
            #else
            VStack(alignment: .leading, spacing: 0) {
                TextField(
                    "",
                    text: $text,
                    selection: $textSelection,
                    prompt: Text(placeholderText)
                        .foregroundStyle(.secondary.opacity(0.6)),
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: editorFontSize))
                    .lineLimit(1...6)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($inputFocused)
                    .onPasteCommand(of: [.image, .fileURL], perform: handlePastedImageProviders)
                    .onKeyPress(phases: [.down]) { keyPress in
                        handleKeyPress(keyPress)
                    }

                Spacer(minLength: 0)
            }
            .frame(minHeight: editorCollapsedMinHeight, maxHeight: editorExpandedMaxHeight, alignment: .topLeading)
            .padding(.horizontal, editorHorizontalInset)
            .padding(.vertical, editorVerticalInset)
            #endif
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            imageUploadButton
            agentButton
            modelButton
                    modelVariantButton
            contextRemainingRing

            Spacer()

            sendOrStopButton
        }
    }

    private var agentButton: some View {
        Group {
            if isLoadingAgents {
                loadingPlaceholder
            } else if !agents.isEmpty {
                Menu {
                    ForEach(agents) { agent in
                        Button {
                            selectedAgent = agent.name
                            if let pid = agent.defaultProviderID,
                               let mid = agent.defaultModelID,
                               !pid.isEmpty,
                               !mid.isEmpty {
                                selectedModel = AIModelSelection(providerID: pid, modelID: mid)
                            }
                        } label: {
                            HStack {
                                Text(agent.name)
                                if let desc = agent.description, !desc.isEmpty {
                                    Text("— \(desc)")
                                }
                            }
                        }
                    }
                } label: {
                    toolbarMenuLabel(title: selectedAgent ?? agents.first?.name ?? "Agent")
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var modelButton: some View {
        Group {
            if isLoadingModels {
                loadingPlaceholder
            } else if !providers.isEmpty {
                Menu {
                    if availableModelProviders.count <= 1 {
                        if let onlyProvider = availableModelProviders.first {
                            ForEach(onlyProvider.models) { model in
                                Button(model.name) {
                                    selectedModel = AIModelSelection(providerID: onlyProvider.id, modelID: model.id)
                                }
                            }
                        } else {
                            Text("暂无可用模型")
                        }
                    } else {
                        ForEach(availableModelProviders) { provider in
                            Menu(provider.name) {
                                ForEach(provider.models) { model in
                                    Button(model.name) {
                                        selectedModel = AIModelSelection(providerID: provider.id, modelID: model.id)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    toolbarMenuLabel(title: selectedModelDisplayName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var modelVariantButton: some View {
        Group {
            if !normalizedModelVariantOptions.isEmpty {
                Menu {
                    Button("默认") {
                        selectedModelVariant = nil
                    }
                    ForEach(normalizedModelVariantOptions, id: \.self) { option in
                        Button(option) {
                            selectedModelVariant = option
                        }
                    }
                } label: {
                    toolbarMenuLabel(title: selectedModelVariantDisplayName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var availableModelProviders: [AIProviderInfo] {
        providers.filter { !$0.models.isEmpty }
    }

    private var selectedModelDisplayName: String {
        guard let sel = selectedModel else { return "模型" }
        for provider in providers {
            if let model = provider.models.first(where: { $0.id == sel.modelID && provider.id == sel.providerID }) {
                return model.name
            }
        }
        return sel.modelID
    }

    private var normalizedModelVariantOptions: [String] {
        var seen: Set<String> = []
        var values: [String] = []
        for item in modelVariantOptions {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            values.append(trimmed)
        }
        return values
    }

    private var selectedModelVariantDisplayName: String {
        let trimmed = selectedModelVariant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultModelVariantLabel : trimmed
    }

    private var defaultModelVariantLabel: String {
        let normalized = normalizedModelVariantOptions.map { $0.lowercased() }
        if Set(normalized) == Set(["low", "medium", "high"]) {
            return "思考"
        }
        return "模型变体"
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 4) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
            Text("加载中...")
                .font(.system(size: chipFontSize))
                .foregroundStyle(dropdownSecondaryTextColor)
        }
        .frame(maxWidth: selectorLabelMaxWidth, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(toolbarChipBackgroundColor, in: .capsule)
        .overlay {
            Capsule()
                .stroke(toolbarChipBorderColor, lineWidth: 0.6)
        }
    }

    @ViewBuilder
    private var contextRemainingRing: some View {
        if let percent = normalizedContextRemainingPercent {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: percent / 100.0)
                    .stroke(contextRingColor(for: percent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: contextRingSize, height: contextRingSize)
            .accessibilityLabel("剩余上下文")
        }
    }

    private func slashCommandIcon(_ name: String) -> String {
        switch name {
        case "new":
            return "square.and.pencil"
        default:
            return "command"
        }
    }

    @ViewBuilder
    private var imageUploadButton: some View {
        #if os(iOS) && canImport(PhotosUI)
        PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: 6,
            matching: .images
        ) {
            toolbarAccessoryIcon(systemName: "plus")
        }
        .onChange(of: selectedPhotoItems) { _, items in
            handleSelectedPhotoItems(items)
        }
        #else
        Button(action: pickImage) {
            toolbarAccessoryIcon(systemName: "plus")
        }
        .buttonStyle(.plain)
        .help("添加附件")
        #endif
    }

    #if os(iOS) && canImport(PhotosUI)
    private func handleSelectedPhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var attachments: [ImageAttachment] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                guard let attachment = Self.makeImageAttachment(from: data, suggestedFilename: nil, fallbackPrefix: "image") else {
                    continue
                }
                attachments.append(attachment)
            }
            await MainActor.run {
                appendImageAttachments(attachments)
                selectedPhotoItems = []
            }
        }
    }
    #endif

    private func pickImage() {
        #if os(macOS)
        showImageImporter = true
        #endif
    }

    private func appendImageAttachments(_ attachments: [ImageAttachment]) {
        guard !attachments.isEmpty else { return }
        let remaining = max(0, maxImageAttachmentCount - imageAttachments.count)
        guard remaining > 0 else { return }
        imageAttachments.append(contentsOf: attachments.prefix(remaining))
    }

    private func handlePastedImageProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let fileURL = item as? URL {
                        url = fileURL
                    } else {
                        url = nil
                    }
                    guard let url, let attachment = Self.makeImageAttachment(from: url) else { return }
                    DispatchQueue.main.async {
                        self.appendImageAttachments([attachment])
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data,
                          let attachment = Self.makeImageAttachment(from: data, suggestedFilename: nil, fallbackPrefix: "pasted")
                    else {
                        return
                    }
                    DispatchQueue.main.async {
                        self.appendImageAttachments([attachment])
                    }
                }
            }
        }
    }

    private static func makeImageAttachment(from url: URL) -> ImageAttachment? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return makeImageAttachment(from: data, suggestedFilename: url.lastPathComponent)
    }

    private static func makeImageAttachment(
        from data: Data,
        suggestedFilename: String?,
        fallbackPrefix: String = "image"
    ) -> ImageAttachment? {
        let fileInfo = detectImageFileInfo(data: data)
        guard fileInfo.mime.hasPrefix("image/") else { return nil }
        let filename: String
        if let suggestedFilename,
           !suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filename = suggestedFilename
        } else {
            let suffix = UUID().uuidString.prefix(8)
            filename = "\(fallbackPrefix)_\(suffix).\(fileInfo.ext)"
        }
        return ImageAttachment(filename: filename, data: data, mime: fileInfo.mime)
    }

    #if os(macOS)
    fileprivate static func makeImageAttachments(
        from pasteboard: NSPasteboard,
        fallbackPrefix: String = "pasted"
    ) -> [ImageAttachment] {
        var attachments: [ImageAttachment] = []
        var seenKeys = Set<String>()
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls {
                guard let attachment = Self.makeImageAttachment(from: url) else { continue }
                let key = Self.imageAttachmentDedupKey(attachment)
                if seenKeys.insert(key).inserted {
                    attachments.append(attachment)
                }
            }
        }

        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard let utType = UTType(type.rawValue), utType.conforms(to: .image) else { continue }
                guard let data = item.data(forType: type),
                      let attachment = Self.makeImageAttachment(
                          from: data,
                          suggestedFilename: nil,
                          fallbackPrefix: fallbackPrefix
                      )
                else {
                    continue
                }
                let key = Self.imageAttachmentDedupKey(attachment)
                if seenKeys.insert(key).inserted {
                    attachments.append(attachment)
                }
                break
            }
        }

        return attachments
    }

    private static func imageAttachmentDedupKey(_ attachment: ImageAttachment) -> String {
        "\(attachment.filename)|\(attachment.data.count)|\(attachment.data.prefix(12).base64EncodedString())"
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let attachments = urls.compactMap(Self.makeImageAttachment(from:))
        appendImageAttachments(attachments)
    }

    private func handleDroppedImageProviders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let fileURL = item as? URL {
                        url = fileURL
                    } else {
                        url = nil
                    }
                    guard let url, let attachment = Self.makeImageAttachment(from: url) else { return }
                    DispatchQueue.main.async {
                        self.appendImageAttachments([attachment])
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data,
                          let attachment = Self.makeImageAttachment(from: data, suggestedFilename: nil, fallbackPrefix: "dropped")
                    else {
                        return
                    }
                    DispatchQueue.main.async {
                        self.appendImageAttachments([attachment])
                    }
                }
            }
        }
        return true
    }
    #endif

    private static func detectImageFileInfo(data: Data) -> (mime: String, ext: String) {
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
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let type = CGImageSourceGetType(source) as String? {
            switch type {
            case UTType.tiff.identifier:
                return ("image/tiff", "tiff")
            case UTType.bmp.identifier:
                return ("image/bmp", "bmp")
            default:
                break
            }
        }
        return ("application/octet-stream", "bin")
    }

    private func toolbarMenuLabel(systemImage: String? = nil, title: String) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: chipFontSize, weight: .semibold))
            }
            Text(title)
                .font(.system(size: chipFontSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: selectorLabelMaxWidth, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(toolbarChipBackgroundColor, in: .capsule)
        .overlay {
            Capsule()
                .stroke(toolbarChipBorderColor, lineWidth: 0.6)
        }
        .foregroundStyle(dropdownPrimaryTextColor)
    }

    private func toolbarAccessoryIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: accessoryIconFontSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: accessoryButtonDiameter, height: accessoryButtonDiameter)
            .background(toolbarChipBackgroundColor)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(toolbarChipBorderColor, lineWidth: 0.6)
            }
    }

    private var dropdownPrimaryTextColor: Color { .primary }
    private var dropdownSecondaryTextColor: Color { .secondary }

    private var normalizedContextRemainingPercent: Double? {
        guard let contextRemainingPercent, contextRemainingPercent.isFinite else { return nil }
        return min(max(contextRemainingPercent, 0), 100)
    }

    private func contextRingColor(for percent: Double) -> Color {
        switch percent {
        case ..<20: return .red
        case ..<50: return .orange
        default: return .green
        }
    }

    private var outerHorizontalPadding: CGFloat {
        #if os(iOS)
        10
        #else
        12
        #endif
    }

    private var outerTopPadding: CGFloat {
        #if os(iOS)
        6
        #else
        8
        #endif
    }

    private var outerBottomPadding: CGFloat {
        #if os(iOS)
        5
        #else
        6
        #endif
    }

    private var cardHorizontalPadding: CGFloat {
        #if os(iOS)
        12
        #else
        14
        #endif
    }

    private var cardTopPadding: CGFloat {
        #if os(iOS)
        12
        #else
        14
        #endif
    }

    private var cardBottomPadding: CGFloat {
        #if os(iOS)
        7
        #else
        8
        #endif
    }
    private var cardContentSpacing: CGFloat { 10 }
    private var floatingCardCornerRadius: CGFloat { 18 }
    private var floatingCardBackgroundColor: Color { Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.08) }
    private var floatingCardBorderColor: Color { colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12) }
    private var floatingCardPrimaryShadowColor: Color { colorScheme == .dark ? Color.black.opacity(0.34) : Color.black.opacity(0.16) }
    private var floatingCardSecondaryShadowColor: Color { colorScheme == .dark ? Color.black.opacity(0.2) : Color.black.opacity(0.08) }
    private var toolbarChipBackgroundColor: Color { colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04) }
    private var toolbarChipBorderColor: Color { colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08) }
    private var editorSurfaceCornerRadius: CGFloat { 16 }
    private var editorSurfaceBackgroundColor: Color { colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.03) }
    private var editorMinHeight: CGFloat {
        #if os(iOS)
        72
        #else
        60
        #endif
    }

    private var editorCollapsedMinHeight: CGFloat {
        #if os(iOS)
        36
        #else
        34
        #endif
    }

    private var editorExpandedMaxHeight: CGFloat {
        #if os(iOS)
        108
        #else
        96
        #endif
    }
    private var editorFontSize: CGFloat { 14 }
    private var editorHorizontalInset: CGFloat { 6 }
    private var editorVerticalInset: CGFloat { 6 }
    private var chipFontSize: CGFloat {
        #if os(iOS)
        13
        #else
        12
        #endif
    }

    private var accessoryButtonDiameter: CGFloat {
        #if os(iOS)
        30
        #else
        28
        #endif
    }

    private var accessoryIconFontSize: CGFloat {
        #if os(iOS)
        13
        #else
        12
        #endif
    }

    private var selectorLabelMaxWidth: CGFloat {
        #if os(iOS)
        128
        #else
        160
        #endif
    }

    private var actionButtonDiameter: CGFloat {
        #if os(iOS)
        32
        #else
        28
        #endif
    }

    private var actionIconFontSize: CGFloat {
        #if os(iOS)
        14
        #else
        12
        #endif
    }

    private var contextRingSize: CGFloat {
        #if os(iOS)
        16
        #else
        14
        #endif
    }

    private var placeholderText: String {
        #if os(iOS)
        "输入消息..."
        #else
        "输入消息...  @ 引用文件  / 斜杠命令"
        #endif
    }

    private var sendOrStopButton: some View {
        Group {
            if isSendingPending {
                ZStack {
                    Circle()
                        .fill(Color.gray.opacity(0.55))
                        .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                        .tint(.white)
                }
            } else if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: actionIconFontSize, weight: .bold))
                        .foregroundStyle(canStopStreaming ? .white : .white.opacity(0.72))
                        .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                        .background(canStopStreaming ? Color.red : Color.gray.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canStopStreaming)
                .help(canStopStreaming ? "停止生成" : "会话创建中，暂不可停止")
                .accessibilityIdentifier("tf.ai.input.stop-button")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: actionIconFontSize, weight: .bold))
                        .foregroundStyle(canSend ? .white : .white.opacity(0.72))
                        .frame(width: actionButtonDiameter, height: actionButtonDiameter)
                        .background(canSend ? Color.accentColor : Color.gray.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("发送")
                .accessibilityIdentifier("tf.ai.input.send-button")
            }
        }
        .accessibilityIdentifier("tf.ai.input.action-button")
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if isTextInputComposing {
            return .ignored
        }

        switch keyPress.key {
        case .return:
            if keyPress.modifiers.contains(.shift) {
                #if os(macOS)
                if insertLineBreakAtCurrentSelection() {
                    return .handled
                }
                #endif
                return .ignored
            }
            if let autocomplete, autocomplete.isVisible, let item = autocomplete.selectedItem {
                onSelectAutocomplete?(item)
                return .handled
            }
            guard canSend && !isStreaming else { return .handled }
            onSend()
            return .handled
        case .tab:
            if let autocomplete, autocomplete.mode == .codeCompletion, autocomplete.completionSuggestion != nil {
                onAcceptCodeCompletion?()
                return .handled
            }
            if let autocomplete, autocomplete.isVisible, let item = autocomplete.selectedItem {
                onSelectAutocomplete?(item)
                return .handled
            }
            return .ignored
        case .upArrow:
            if autocomplete?.isVisible == true {
                autocomplete?.moveUp()
                return .handled
            }
            return .ignored
        case .downArrow:
            if autocomplete?.isVisible == true {
                autocomplete?.moveDown()
                return .handled
            }
            return .ignored
        case .escape:
            if autocomplete?.isVisible == true {
                autocomplete?.reset()
                return .handled
            }
            return .ignored
        default:
            return .ignored
        }
    }

    #if os(macOS)
    private func insertLineBreakAtCurrentSelection() -> Bool {
        let candidateWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in candidateWindows {
            guard let textView = window.firstResponder as? NSTextView else { continue }
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }
    #endif

    private var isTextInputComposing: Bool {
        #if os(macOS)
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return false
        }
        return textView.hasMarkedText()
        #else
        return false
        #endif
    }

    private func updateSelectionToEnd() {
        let endIndex = text.endIndex
        textSelection = TextSelection(insertionPoint: endIndex)
        lastKnownInputOffset = text.utf16.count
        onInputContextChange?(text.utf16.count, false)
    }

    private func publishInputContextChange(text: String, selection: TextSelection?) {
        let location = resolvedInputOffset(in: text, selection: selection)
        lastKnownInputOffset = location
        onInputContextChange?(location, false)
    }

    private func resolvedInputOffset(in text: String, selection: TextSelection?) -> Int {
        #if os(macOS)
        if let currentOffset = currentFocusedTextViewSelectionOffset(in: text) {
            return currentOffset
        }
        return min(lastKnownInputOffset, text.utf16.count)
        #else
        return min(selection?.utf16InsertionOffset(in: text) ?? text.utf16.count, text.utf16.count)
        #endif
    }

    #if os(macOS)
    private func currentFocusedTextViewSelectionOffset(in text: String) -> Int? {
        let candidateWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in candidateWindows {
            guard let textView = window.firstResponder as? NSTextView else { continue }
            return min(max(0, textView.selectedRange().location), text.utf16.count)
        }
        return nil
    }
    #endif

    #if os(macOS)
    private func handleFocusedPaste() -> Bool {
        let attachments = Self.makeImageAttachments(from: .general)
        guard !attachments.isEmpty else { return false }
        appendImageAttachments(attachments)
        return true
    }
    #endif
}

#if os(iOS)
private struct IOSPasteAwareTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let selectionOffset: Int?
    let fontSize: CGFloat
    let onSelectionChange: (Int) -> Void
    let onPasteProviders: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PasteAwareUITextView {
        let textView = PasteAwareUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = true
        textView.keyboardDismissMode = .interactive
        textView.onPasteProviders = onPasteProviders
        textView.text = text
        return textView
    }

    func updateUIView(_ uiView: PasteAwareUITextView, context: Context) {
        context.coordinator.parent = self
        uiView.onPasteProviders = onPasteProviders

        if uiView.text != text {
            context.coordinator.isSyncingFromSwiftUI = true
            uiView.text = text
            context.coordinator.isSyncingFromSwiftUI = false
        }

        if uiView.font?.pointSize != fontSize {
            uiView.font = .systemFont(ofSize: fontSize)
        }

        if let selectionOffset {
            let clampedLocation = min(max(0, selectionOffset), uiView.text.utf16.count)
            if uiView.selectedRange.location != clampedLocation || uiView.selectedRange.length != 0 {
                uiView.selectedRange = NSRange(location: clampedLocation, length: 0)
            }
        }

        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSPasteAwareTextView
        var isSyncingFromSwiftUI = false

        init(parent: IOSPasteAwareTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard !parent.isFocused else { return }
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard parent.isFocused else { return }
            parent.isFocused = false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isSyncingFromSwiftUI else { return }
            let newText = textView.text ?? ""
            guard parent.text != newText else { return }
            parent.text = newText
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.onSelectionChange(textView.selectedRange.location)
        }
    }
}

private final class PasteAwareUITextView: UITextView {
    var onPasteProviders: (([NSItemProvider]) -> Void)?

    override func paste(_ sender: Any?) {
        let supportedProviders = UIPasteboard.general.itemProviders.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !supportedProviders.isEmpty else {
            super.paste(sender)
            return
        }

        onPasteProviders?(supportedProviders)
    }
}
#endif

private struct AIChatFloatingComposerChrome: ViewModifier {
    let colorScheme: ColorScheme
    let cornerRadius: CGFloat
    let fallbackBackgroundColor: Color
    let fallbackBorderColor: Color
    let primaryShadowColor: Color
    let secondaryShadowColor: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .background(.clear, in: .rect(cornerRadius: cornerRadius, style: .continuous))
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.28), lineWidth: 0.8)
                }
                .shadow(color: primaryShadowColor, radius: 26, x: 0, y: 14)
                .shadow(color: secondaryShadowColor, radius: 10, x: 0, y: 4)
        } else {
            content
                .background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius, style: .continuous))
                .background(fallbackBackgroundColor, in: .rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(fallbackBorderColor, lineWidth: 1.0)
                }
                .shadow(color: primaryShadowColor, radius: 22, x: 0, y: 12)
                .shadow(color: secondaryShadowColor, radius: 8, x: 0, y: 3)
        }
    }
}

private struct ImageAttachmentChip: View {
    @Environment(\.colorScheme) private var colorScheme

    let attachment: ImageAttachment
    let onRemove: () -> Void

    #if os(macOS)
    @State private var isHovering = false
    #endif

    var body: some View {
        HStack(spacing: 6) {
            attachmentThumbnail

            Text(attachment.filename)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: filenameMaxWidth, alignment: .leading)

            if showsRemoveButton {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("移除附件")
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                #endif
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, showsRemoveButton ? 7 : 10)
        .padding(.vertical, 3)
        .background(chipBackgroundColor, in: .capsule)
        .overlay {
            Capsule()
                .stroke(chipBorderColor, lineWidth: 0.8)
        }
        .fixedSize(horizontal: true, vertical: false)
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
        #endif
    }

    @ViewBuilder
    private var attachmentThumbnail: some View {
        if let image = attachment.previewImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipShape(Circle())
        } else {
            fallbackThumbnail
        }
    }

    private var fallbackThumbnail: some View {
        Circle()
            .fill(Color.secondary.opacity(0.14))
            .frame(width: 24, height: 24)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }

    private var showsRemoveButton: Bool {
        #if os(macOS)
        isHovering
        #else
        true
        #endif
    }

    private var chipBackgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.035)
    }

    private var chipBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private var filenameMaxWidth: CGFloat {
        #if os(iOS)
        return 92
        #else
        return 108
        #endif
    }
}

private extension TextSelection {
    func utf16InsertionOffset(in text: String) -> Int {
        switch indices {
        case .selection(let range):
            return text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        case .multiSelection:
            return text.utf16.count
        @unknown default:
            return text.utf16.count
        }
    }
}

private extension ImageAttachment {
    var previewImage: CGImage? {
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 128
        ]
        if let source,
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            return thumbnail
        }
        if let source {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return nil
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
            contextRemainingPercent: nil,
            agents: [],
            selectedAgent: .constant(nil),
            modelVariantOptions: [],
            selectedModelVariant: .constant(nil),
            autocomplete: nil,
            onSelectAutocomplete: nil,
            onInputContextChange: nil
        )

        ChatInputView(
            text: .constant(""),
            imageAttachments: .constant([]),
            isStreaming: true,
            onSend: {},
            onStop: {},
            providers: [],
            selectedModel: .constant(nil),
            contextRemainingPercent: nil,
            agents: [],
            selectedAgent: .constant(nil),
            modelVariantOptions: [],
            selectedModelVariant: .constant(nil),
            autocomplete: nil,
            onSelectAutocomplete: nil,
            onInputContextChange: nil
        )
    }
    .padding()
    .frame(width: 500)
}
