import SwiftUI
import TidyFlowShared

/// iOS 工作区编辑器页面。
///
/// 使用 UIViewRepresentable 包装 UITextView，依赖系统原生长按选择、
/// 拖拽句柄、复制粘贴菜单和 interactive keyboard dismiss 作为基础触控手势方案。
/// 消费 EditorDocumentSession 作为唯一文档状态真源。
struct MobileEditorView: View {
    @ObservedObject var appState: MobileAppState
    let project: String
    let workspace: String
    let path: String

    /// 查找替换面板内的匹配状态（本地驱动，不持久化到 session）
    @State private var matchRanges: [Range<String.Index>] = []
    @State private var currentMatchIndex: Int = -1
    @State private var showUnsavedAlert = false
    /// 纯视图层保存中指示（非业务真源，仅驱动即时视觉反馈）
    @State private var isSavingLocally = false

    @Environment(\.dismiss) private var dismiss

    private var globalWorkspaceKey: String {
        appState.globalWorkspaceKey(project: project, workspace: workspace)
    }

    private var documentKey: EditorDocumentKey {
        EditorDocumentKey(project: project, workspace: workspace, path: path)
    }

    private var session: EditorDocumentSession? {
        appState.getEditorDocument(globalWorkspaceKey: globalWorkspaceKey, path: path)
    }

    private var findState: EditorFindReplaceState {
        appState.findReplaceState(for: documentKey)
    }

    private var fileName: String {
        (path as NSString).lastPathComponent
    }

    /// 当前文档是否正在保存（组合本地指示与 MobileAppState 的 pending 请求集合）
    private var isSaving: Bool {
        isSavingLocally || appState.pendingEditorFileWriteRequests.contains(
            EditorRequestKey(project: project, workspace: workspace, path: path)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // 冲突提示条
            conflictBanner

            // 查找替换条
            if findState.isVisible {
                findReplaceBar
            }

            // 编辑器主体
            editorContent

            // 底部状态条
            statusBar
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    handleBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                }
                .accessibilityLabel("返回")
                .accessibilityHint("返回到文件列表")
                .accessibilityIdentifier("editor-back-button")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在保存文件")
                        .accessibilityIdentifier("editor-save-progress")
                } else {
                    Button {
                        isSavingLocally = true
                        appState.saveDocument(documentKey: documentKey)
                        // 超时保护：避免网络异常时永远停留在保存中状态
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            isSavingLocally = false
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(!(session?.isDirty ?? false))
                    .accessibilityLabel("保存文件")
                    .accessibilityHint(session?.isDirty == true ? "保存当前编辑的更改" : "文件无需保存")
                    .accessibilityIdentifier("editor-save-button")
                }
            }
        }
        .onAppear {
            appState.openEditorDocument(project: project, workspace: workspace, path: path)
        }
        .alert("未保存的更改", isPresented: $showUnsavedAlert) {
            Button("保存并关闭") {
                appState.saveDocument(documentKey: documentKey)
                dismiss()
            }
            Button("放弃更改", role: .destructive) {
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文件「\(fileName)」有未保存的更改，是否保存？")
        }
        .onChange(of: session?.isDirty) { _, newValue in
            if newValue == false {
                isSavingLocally = false
            }
        }
    }

    // MARK: - 编辑器内容

    @ViewBuilder
    private var editorContent: some View {
        if let session = session {
            switch session.loadStatus {
            case .loading, .idle:
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取文件…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在读取文件")
                .accessibilityIdentifier("editor-loading")
                Spacer()
            case .error(let message):
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)
                    Text("无法打开文件")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("打开文件失败，\(message)")
                .accessibilityIdentifier("editor-error")
                Spacer()
            case .ready:
                EditorTextViewWrapper(
                    appState: appState,
                    documentKey: documentKey,
                    globalWorkspaceKey: globalWorkspaceKey,
                    path: path
                )
                .accessibilityIdentifier("editor-text-view")
            }
        } else {
            Spacer()
            VStack(spacing: 12) {
                ProgressView()
                Text("正在打开文件…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在打开文件")
            .accessibilityIdentifier("editor-opening")
            Spacer()
        }
    }

    // MARK: - 冲突提示条

    @ViewBuilder
    private var conflictBanner: some View {
        if let session = session {
            switch session.conflictState {
            case .changedOnDisk:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.subheadline)
                    Text("文件已在磁盘上被修改")
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer()
                    Button("重新加载") {
                        appState.reloadEditorDocument(project: project, workspace: workspace, path: path)
                    }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("从磁盘重新加载文件内容")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editor-conflict-changed")
            case .deletedOnDisk:
                HStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.red)
                        .font(.subheadline)
                    Text("文件已从磁盘删除")
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.12))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("文件已从磁盘删除")
                .accessibilityIdentifier("editor-conflict-deleted")
            case .none:
                EmptyView()
            }
        }
    }

    // MARK: - 查找替换条

    private var findReplaceBar: some View {
        VStack(spacing: 6) {
            // 查找行
            HStack(spacing: 4) {
                TextField("查找", text: findTextBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("查找文本")
                    .accessibilityIdentifier("editor-find-field")

                // 大小写切换
                Button {
                    var state = findState
                    state.isCaseSensitive.toggle()
                    appState.updateFindReplaceState(state, for: documentKey)
                    refreshFindMatches()
                } label: {
                    Text("Aa")
                        .font(.caption.bold())
                        .foregroundColor(findState.isCaseSensitive ? .accentColor : .secondary)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .accessibilityLabel(findState.isCaseSensitive ? "区分大小写：已开启" : "区分大小写：已关闭")
                .accessibilityHint("切换区分大小写")

                // 正则切换
                Button {
                    var state = findState
                    state.useRegex.toggle()
                    appState.updateFindReplaceState(state, for: documentKey)
                    refreshFindMatches()
                } label: {
                    Text(".*")
                        .font(.caption.bold())
                        .foregroundColor(findState.useRegex ? .accentColor : .secondary)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .accessibilityLabel(findState.useRegex ? "正则表达式：已开启" : "正则表达式：已关闭")
                .accessibilityHint("切换正则表达式匹配")

                Text(EditorFindReplaceEngine.matchStatusText(
                    currentIndex: currentMatchIndex, matchCount: matchRanges.count
                ))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize()
                .accessibilityLabel(
                    matchRanges.isEmpty
                        ? "无匹配结果"
                        : "第 \(max(currentMatchIndex + 1, 1)) 个，共 \(matchRanges.count) 个匹配"
                )

                // 上一个/下一个
                Button { navigatePrevious() } label: {
                    Image(systemName: "chevron.up")
                        .frame(minWidth: 32, minHeight: 32)
                }
                .disabled(matchRanges.isEmpty)
                .accessibilityLabel("上一个匹配")

                Button { navigateNext() } label: {
                    Image(systemName: "chevron.down")
                        .frame(minWidth: 32, minHeight: 32)
                }
                .disabled(matchRanges.isEmpty)
                .accessibilityLabel("下一个匹配")

                // 关闭
                Button {
                    appState.dismissFindReplace(documentKey: documentKey)
                    matchRanges = []
                    currentMatchIndex = -1
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 32, minHeight: 32)
                }
                .accessibilityLabel("关闭查找替换")
            }
            .padding(.horizontal, 10)

            // 替换行
            HStack(spacing: 4) {
                TextField("替换", text: replaceTextBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("替换文本")
                    .accessibilityIdentifier("editor-replace-field")

                Button("替换") { replaceCurrentMatch() }
                    .font(.caption)
                    .disabled(currentMatchIndex < 0 || findState.regexError != nil)
                    .accessibilityLabel("替换当前匹配")
                    .accessibilityHint("将当前匹配替换为指定文本")

                Button("全部") { replaceAllMatches() }
                    .font(.caption)
                    .disabled(matchRanges.isEmpty || findState.regexError != nil)
                    .accessibilityLabel("替换全部匹配")
                    .accessibilityHint("将所有匹配替换为指定文本")
            }
            .padding(.horizontal, 10)

            // 正则错误提示
            if let regexError = findState.regexError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                    Text(regexError)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正则表达式错误：\(regexError)")
            }
        }
        .padding(.vertical, 6)
        .background(Color(UIColor.secondarySystemBackground))
        .accessibilityIdentifier("editor-find-replace-bar")
        .onChange(of: findState.findText) { _, _ in refreshFindMatches() }
        .onChange(of: findState.isCaseSensitive) { _, _ in refreshFindMatches() }
        .onChange(of: findState.useRegex) { _, _ in refreshFindMatches() }
        .onAppear { refreshFindMatches() }
    }

    // MARK: - 底部状态条

    private var statusBar: some View {
        HStack(spacing: 6) {
            if let session = session {
                // 保存状态指示
                if isSaving {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                        Text("保存中…")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("正在保存文件")
                } else if session.isDirty {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("已修改")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("文件已修改，尚未保存")
                } else if session.loadStatus == .ready {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.green)
                        Text("已保存")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("文件已保存")
                }

                // 冲突状态（可与保存状态共存）
                if session.conflictState != .none {
                    Text("·")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)

                    if session.conflictState == .changedOnDisk {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                            Text("磁盘已变更")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("文件在磁盘上被其他程序修改")
                    } else if session.conflictState == .deletedOnDisk {
                        HStack(spacing: 3) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.red)
                            Text("已删除")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("文件已从磁盘上被删除")
                    }
                }
            }
            Spacer()
            Text(path)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("文件路径：\(path)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(UIColor.secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-status-bar")
    }

    // MARK: - 绑定

    private var findTextBinding: Binding<String> {
        Binding(
            get: { findState.findText },
            set: {
                var state = findState
                state.findText = $0
                appState.updateFindReplaceState(state, for: documentKey)
            }
        )
    }

    private var replaceTextBinding: Binding<String> {
        Binding(
            get: { findState.replaceText },
            set: {
                var state = findState
                state.replaceText = $0
                appState.updateFindReplaceState(state, for: documentKey)
            }
        )
    }

    // MARK: - 查找替换操作

    private func refreshFindMatches() {
        guard let session = session, session.loadStatus == .ready else { return }
        let result = EditorFindReplaceEngine.findMatches(in: session.content, state: findState)
        matchRanges = result.ranges
        var updatedState = findState
        updatedState.regexError = result.regexError
        appState.updateFindReplaceState(updatedState, for: documentKey)
        currentMatchIndex = EditorFindReplaceEngine.clampMatchIndex(
            currentIndex: currentMatchIndex, matchCount: result.ranges.count, keepSelection: false
        )
    }

    private func navigateNext() {
        currentMatchIndex = EditorFindReplaceEngine.nextMatchIndex(
            currentIndex: currentMatchIndex, matchCount: matchRanges.count
        )
    }

    private func navigatePrevious() {
        currentMatchIndex = EditorFindReplaceEngine.previousMatchIndex(
            currentIndex: currentMatchIndex, matchCount: matchRanges.count
        )
    }

    private func replaceCurrentMatch() {
        guard let session = session else { return }
        guard let result = EditorFindReplaceEngine.replaceCurrent(
            in: session.content,
            matchRanges: matchRanges,
            currentIndex: currentMatchIndex,
            replaceText: findState.replaceText,
            state: findState
        ) else { return }
        appState.updateEditorDocumentContent(globalWorkspaceKey: globalWorkspaceKey, path: path, content: result.text)
        matchRanges = result.newRanges
        currentMatchIndex = result.currentMatchIndex
    }

    private func replaceAllMatches() {
        guard let session = session else { return }
        guard let result = EditorFindReplaceEngine.replaceAll(
            in: session.content,
            matchRanges: matchRanges,
            replaceText: findState.replaceText,
            state: findState
        ) else { return }
        appState.updateEditorDocumentContent(globalWorkspaceKey: globalWorkspaceKey, path: path, content: result.text)
        matchRanges = result.newRanges
        currentMatchIndex = result.currentMatchIndex
    }

    // MARK: - 返回保护

    private func handleBack() {
        if session?.requiresCloseConfirmation == true {
            showUnsavedAlert = true
        } else {
            dismiss()
        }
    }
}

// MARK: - UITextView 包装

/// UIViewRepresentable 包装 UITextView，提供基础文本编辑功能。
/// 使用系统原生长按选择、拖拽句柄、复制粘贴菜单和 undoManager。
// MARK: - iOS 语法高亮颜色映射

/// iOS 平台的语义角色到颜色映射。
/// 集中管理，不散落在词法规则或视图代码中。
enum EditorSyntaxColorMapIOS {
    static func colors(for theme: EditorSyntaxTheme) -> [EditorSyntaxRole: UIColor] {
        switch theme {
        case .systemDark:
            return [
                .plain: UIColor(red: 0.84, green: 0.84, blue: 0.84, alpha: 1.0),
                .keyword: UIColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1.0),
                .type: UIColor(red: 0.35, green: 0.75, blue: 0.84, alpha: 1.0),
                .string: UIColor(red: 0.99, green: 0.52, blue: 0.40, alpha: 1.0),
                .number: UIColor(red: 0.82, green: 0.73, blue: 0.55, alpha: 1.0),
                .comment: UIColor(red: 0.51, green: 0.55, blue: 0.59, alpha: 1.0),
                .attribute: UIColor(red: 0.80, green: 0.58, blue: 0.93, alpha: 1.0),
                .function: UIColor(red: 0.40, green: 0.78, blue: 0.47, alpha: 1.0),
                .punctuation: UIColor(red: 0.67, green: 0.67, blue: 0.67, alpha: 1.0),
            ]
        case .systemLight:
            return [
                .plain: UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0),
                .keyword: UIColor(red: 0.67, green: 0.05, blue: 0.33, alpha: 1.0),
                .type: UIColor(red: 0.11, green: 0.40, blue: 0.59, alpha: 1.0),
                .string: UIColor(red: 0.77, green: 0.20, blue: 0.13, alpha: 1.0),
                .number: UIColor(red: 0.10, green: 0.35, blue: 0.58, alpha: 1.0),
                .comment: UIColor(red: 0.42, green: 0.47, blue: 0.51, alpha: 1.0),
                .attribute: UIColor(red: 0.50, green: 0.18, blue: 0.68, alpha: 1.0),
                .function: UIColor(red: 0.20, green: 0.44, blue: 0.22, alpha: 1.0),
                .punctuation: UIColor(red: 0.40, green: 0.40, blue: 0.40, alpha: 1.0),
            ]
        }
    }
}

/// 支持硬件键盘补全快捷键的 UITextView 子类
class EditorAutocompleteTextView: UITextView {
    /// 补全快捷键回调（返回 true 表示已处理）
    var onAutocompleteKeyDown: ((UIKeyCommand) -> Bool)?

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        // Ctrl-Space 手动触发
        commands.append(UIKeyCommand(
            input: " ",
            modifierFlags: .control,
            action: #selector(handleAutocompleteKey(_:))
        ))
        // Tab 接受候选
        commands.append(UIKeyCommand(
            input: "\t",
            modifierFlags: [],
            action: #selector(handleAutocompleteKey(_:))
        ))
        // Esc 关闭候选
        commands.append(UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(handleAutocompleteKey(_:))
        ))
        // Enter 接受候选
        commands.append(UIKeyCommand(
            input: "\r",
            modifierFlags: [],
            action: #selector(handleAutocompleteKey(_:))
        ))
        // Up 导航
        commands.append(UIKeyCommand(
            input: UIKeyCommand.inputUpArrow,
            modifierFlags: [],
            action: #selector(handleAutocompleteKey(_:))
        ))
        // Down 导航
        commands.append(UIKeyCommand(
            input: UIKeyCommand.inputDownArrow,
            modifierFlags: [],
            action: #selector(handleAutocompleteKey(_:))
        ))
        return commands
    }

    @objc private func handleAutocompleteKey(_ command: UIKeyCommand) {
        if onAutocompleteKeyDown?(command) == true {
            return
        }
        // 未被补全处理的按键，交回系统默认行为
        // Tab 和 Enter 需要手动插入
        if command.input == "\t" {
            insertText("\t")
        } else if command.input == "\r" {
            insertText("\n")
        }
    }
}

struct EditorTextViewWrapper: UIViewRepresentable {
    @ObservedObject var appState: MobileAppState
    let documentKey: EditorDocumentKey
    let globalWorkspaceKey: String
    let path: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = EditorAutocompleteTextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .systemBackground

        // 硬件键盘补全快捷键处理
        textView.onAutocompleteKeyDown = { [weak textView] command in
            guard let textView = textView else { return false }
            let coordinator = context.coordinator

            // Ctrl-Space：手动触发
            if command.modifierFlags.contains(.control) && command.input == " " {
                coordinator.triggerManualAutocomplete(textView: textView)
                return true
            }

            guard coordinator.isAutocompleteVisible else { return false }

            let docKey = coordinator.parent.documentKey
            var state = coordinator.parent.appState.autocompleteState(for: docKey)

            switch command.input {
            case UIKeyCommand.inputUpArrow:
                if state.selectedIndex > 0 {
                    state.selectedIndex -= 1
                    coordinator.parent.appState.updateAutocompleteState(state, for: docKey)
                    coordinator.autocompletePopupView?.update(items: state.items, selectedIndex: state.selectedIndex)
                }
                return true
            case UIKeyCommand.inputDownArrow:
                if state.selectedIndex < state.items.count - 1 {
                    state.selectedIndex += 1
                    coordinator.parent.appState.updateAutocompleteState(state, for: docKey)
                    coordinator.autocompletePopupView?.update(items: state.items, selectedIndex: state.selectedIndex)
                }
                return true
            case "\t", "\r":
                coordinator.acceptSelectedAutocomplete(textView: textView)
                return true
            case UIKeyCommand.inputEscape:
                coordinator.dismissAutocompletePopup(textView: textView)
                return true
            default:
                return false
            }
        }

        // 设置键盘辅助栏
        let accessory = EditorInputAccessoryView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        accessory.onSave = { [weak textView] in
            guard textView != nil else { return }
            DispatchQueue.main.async {
                self.appState.saveDocument(documentKey: self.documentKey)
            }
        }
        accessory.onUndo = { [weak textView, weak appState] in
            guard let textView = textView, let appState = appState else { return }
            guard let result = appState.undoEditorEdit(
                documentKey: self.documentKey,
                currentText: textView.text ?? ""
            ) else { return }
            context.coordinator.isProgrammaticTextUpdate = true
            textView.text = result.text
            let maxLen = (result.text as NSString).length
            textView.selectedRange = NSRange(
                location: min(result.selection.location, maxLen),
                length: min(result.selection.length, max(0, maxLen - result.selection.location))
            )
            context.coordinator.isProgrammaticTextUpdate = false
            context.coordinator.accessoryView?.canUndo = result.canUndo
            context.coordinator.accessoryView?.canRedo = result.canRedo
            context.coordinator.applySyntaxHighlighting(to: textView, filePath: self.path)
            context.coordinator.applyFoldingProjection(to: textView)
            context.coordinator.refreshPairMatchOverlay(textView: textView)
        }
        accessory.onRedo = { [weak textView, weak appState] in
            guard let textView = textView, let appState = appState else { return }
            guard let result = appState.redoEditorEdit(
                documentKey: self.documentKey,
                currentText: textView.text ?? ""
            ) else { return }
            context.coordinator.isProgrammaticTextUpdate = true
            textView.text = result.text
            let maxLen = (result.text as NSString).length
            textView.selectedRange = NSRange(
                location: min(result.selection.location, maxLen),
                length: min(result.selection.length, max(0, maxLen - result.selection.location))
            )
            context.coordinator.isProgrammaticTextUpdate = false
            context.coordinator.accessoryView?.canUndo = result.canUndo
            context.coordinator.accessoryView?.canRedo = result.canRedo
            context.coordinator.applySyntaxHighlighting(to: textView, filePath: self.path)
            context.coordinator.applyFoldingProjection(to: textView)
            context.coordinator.refreshPairMatchOverlay(textView: textView)
        }
        accessory.onToggleFind = {
            DispatchQueue.main.async {
                let state = self.appState.findReplaceState(for: self.documentKey)
                if state.isVisible {
                    self.appState.dismissFindReplace(documentKey: self.documentKey)
                } else {
                    self.appState.presentFindReplace(documentKey: self.documentKey)
                }
            }
        }
        accessory.onFindPrevious = {
            NotificationCenter.default.post(name: .mobileEditorFindPrevious, object: nil)
        }
        accessory.onFindNext = {
            NotificationCenter.default.post(name: .mobileEditorFindNext, object: nil)
        }
        accessory.onDismissKeyboard = { [weak textView] in
            textView?.resignFirstResponder()
        }
        accessory.onAutocomplete = { [weak textView] in
            guard let textView = textView else { return }
            context.coordinator.triggerManualAutocomplete(textView: textView)
        }
        textView.inputAccessoryView = accessory
        context.coordinator.accessoryView = accessory

        // 添加折叠 overlay（统一 gutter 视图）
        let foldOverlay = EditorFoldOverlayUIView()
        foldOverlay.translatesAutoresizingMaskIntoConstraints = false
        foldOverlay.isUserInteractionEnabled = true
        foldOverlay.backgroundColor = .clear
        foldOverlay.onToggleFold = { [weak appState] regionID in
            guard let appState = appState else { return }
            var state = appState.foldingState(for: self.documentKey)
            state.toggle(regionID)
            appState.updateFoldingState(state, for: self.documentKey)
            context.coordinator.applyFoldingProjection(to: textView)
        }
        foldOverlay.onToggleBreakpoint = { [weak appState] line in
            guard let appState = appState else { return }
            appState.toggleBreakpoint(line: line, for: self.documentKey)
            context.coordinator.updateGutterOverlayIfNeeded(textView: textView)
        }
        textView.addSubview(foldOverlay)
        context.coordinator.foldOverlay = foldOverlay

        // 左侧留出 gutter 空间（初始值，后续由 gutter 投影动态更新）
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 48, bottom: 8, right: 8)

        // 注册外部撤销/重做回调（用于 requestUndo/requestRedo 命令入口）
        appState.onEditorUndo = { [weak textView, weak appState] docKey in
            guard let textView = textView, let appState = appState else { return }
            guard docKey == self.documentKey else { return }
            guard let result = appState.undoEditorEdit(
                documentKey: docKey,
                currentText: textView.text ?? ""
            ) else { return }
            context.coordinator.isProgrammaticTextUpdate = true
            textView.text = result.text
            let maxLen = (result.text as NSString).length
            textView.selectedRange = NSRange(
                location: min(result.selection.location, maxLen),
                length: 0
            )
            context.coordinator.isProgrammaticTextUpdate = false
            context.coordinator.accessoryView?.canUndo = result.canUndo
            context.coordinator.accessoryView?.canRedo = result.canRedo
            context.coordinator.applySyntaxHighlighting(to: textView, filePath: self.path)
            context.coordinator.applyFoldingProjection(to: textView)
            context.coordinator.refreshPairMatchOverlay(textView: textView)
        }
        appState.onEditorRedo = { [weak textView, weak appState] docKey in
            guard let textView = textView, let appState = appState else { return }
            guard docKey == self.documentKey else { return }
            guard let result = appState.redoEditorEdit(
                documentKey: docKey,
                currentText: textView.text ?? ""
            ) else { return }
            context.coordinator.isProgrammaticTextUpdate = true
            textView.text = result.text
            let maxLen = (result.text as NSString).length
            textView.selectedRange = NSRange(
                location: min(result.selection.location, maxLen),
                length: 0
            )
            context.coordinator.isProgrammaticTextUpdate = false
            context.coordinator.accessoryView?.canUndo = result.canUndo
            context.coordinator.accessoryView?.canRedo = result.canRedo
            context.coordinator.applySyntaxHighlighting(to: textView, filePath: self.path)
            context.coordinator.applyFoldingProjection(to: textView)
            context.coordinator.refreshPairMatchOverlay(textView: textView)
        }

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard let session = appState.getEditorDocument(globalWorkspaceKey: globalWorkspaceKey, path: path),
              session.loadStatus == .ready else {
            // loadStatus 非 ready 时关闭补全弹层
            context.coordinator.dismissAutocompletePopup(textView: textView)
            return
        }

        // 仅在内容不同时更新（避免光标跳转）
        if textView.text != session.content {
            let selectedRange = textView.selectedRange
            context.coordinator.isApplyingHighlight = true
            textView.text = session.content
            // 恢复光标位置（如果在有效范围内）
            let maxLocation = (textView.text as NSString).length
            if selectedRange.location <= maxLocation {
                textView.selectedRange = NSRange(
                    location: min(selectedRange.location, maxLocation),
                    length: 0
                )
            }
            context.coordinator.isApplyingHighlight = false
            // 外部文本变化时关闭补全弹层
            context.coordinator.dismissAutocompletePopup(textView: textView)
            // 文本变化后重新应用高亮和折叠
            context.coordinator.applySyntaxHighlighting(to: textView, filePath: path)
            context.coordinator.applyFoldingProjection(to: textView)
            context.coordinator.refreshPairMatchOverlay(textView: textView)
        } else {
            // 文本未变，检查主题变化和折叠状态变化
            context.coordinator.applyHighlightingIfThemeChanged(to: textView, filePath: path)
            context.coordinator.applyFoldingProjectionIfNeeded(to: textView)
            context.coordinator.refreshPairMatchOverlay(textView: textView)
        }

        // 更新辅助栏的撤销/重做状态（来自共享历史能力）
        context.coordinator.accessoryView?.canUndo = appState.editorCanUndo(documentKey: documentKey)
        context.coordinator.accessoryView?.canRedo = appState.editorCanRedo(documentKey: documentKey)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        let parent: EditorTextViewWrapper
        weak var accessoryView: EditorInputAccessoryView?
        weak var foldOverlay: EditorFoldOverlayUIView?
        private let highlighter = EditorSyntaxHighlighter()
        private let structureAnalyzer = EditorStructureAnalyzer()
        /// 补全引擎（共享语义层）
        private let autocompleteEngine = EditorAutocompleteEngine()
        /// 补全候选弹层
        var autocompletePopupView: EditorAutocompletePopupUIView?
        /// 上次应用的高亮快照指纹
        private var lastAppliedFingerprint: Int?
        /// 上次应用的主题
        private var lastAppliedTheme: EditorSyntaxTheme?
        /// 标记当前是否正在程序性地更新属性（防止循环写回）
        var isApplyingHighlight = false
        /// 标记当前是否正在程序性地回放共享历史（防止再次入栈）
        var isProgrammaticTextUpdate = false
        /// 最近一次结构分析快照
        var lastStructureSnapshot: EditorStructureSnapshot?
        /// 上次应用的折叠指纹
        private var lastAppliedFoldingFingerprint: Int?
        private var lastAppliedCollapsedCount: Int?
        /// 上次应用的 gutter 缓存键（内容指纹、折叠数、当前行、断点数）
        private var lastGutterCacheKey: (Int, Int, Int?, Int)?

        // MARK: - 括号/引号匹配覆盖层

        /// 匹配高亮覆盖层视图
        private var pairMatchOverlays: [UIView] = []
        /// 上次匹配快照缓存键（内容指纹、选区位置、主题）
        private var lastPairMatchCacheKey: (Int, Int, EditorSyntaxTheme)?

        init(parent: EditorTextViewWrapper) {
            self.parent = parent
        }

        // MARK: - 共享历史桥接

        /// 拦截文本变更前记录共享编辑命令
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !isProgrammaticTextUpdate, !isApplyingHighlight else { return true }

            let currentText = textView.text ?? ""
            let selectedRange = textView.selectedRange
            let replacedText = (currentText as NSString).substring(with: range)

            let command = EditorEditCommand(
                mutation: EditorTextMutation(
                    rangeLocation: range.location,
                    rangeLength: range.length,
                    replacementText: text
                ),
                beforeSelection: EditorSelectionSnapshot(
                    location: selectedRange.location,
                    length: selectedRange.length
                ),
                afterSelection: EditorSelectionSnapshot(
                    location: range.location + (text as NSString).length,
                    length: 0
                ),
                timestamp: Date(),
                replacedText: replacedText
            )

            let result = parent.appState.recordEditorEdit(
                currentText: currentText,
                command: command,
                documentKey: parent.documentKey
            )

            // 程序化写回新文本和选区
            isProgrammaticTextUpdate = true
            textView.text = result.text
            let maxLen = (result.text as NSString).length
            textView.selectedRange = NSRange(
                location: min(result.selection.location, maxLen),
                length: 0
            )
            isProgrammaticTextUpdate = false

            // 更新状态
            parent.appState.updateEditorDocumentContent(
                globalWorkspaceKey: parent.globalWorkspaceKey,
                path: parent.path,
                content: result.text
            )

            // 更新辅助栏状态
            accessoryView?.canUndo = result.canUndo
            accessoryView?.canRedo = result.canRedo

            // 编辑时自动展开包含光标位置的已折叠区域
            if let snapshot = lastStructureSnapshot {
                let cursorLine = lineNumber(for: result.selection.location, in: result.text)
                var foldState = parent.appState.foldingState(for: parent.documentKey)
                let beforeCount = foldState.collapsedRegionIDs.count
                foldState.expandRegions(containingLine: cursorLine, in: snapshot)
                if foldState.collapsedRegionIDs.count != beforeCount {
                    parent.appState.updateFoldingState(foldState, for: parent.documentKey)
                }
                parent.appState.updateCurrentLine(cursorLine, for: parent.documentKey)
            }

            // 重新应用高亮和折叠
            applySyntaxHighlighting(to: textView, filePath: parent.path)
            applyFoldingProjection(to: textView)
            refreshPairMatchOverlay(textView: textView)

            // 刷新补全状态
            refreshAutocompleteState(textView: textView, triggerKind: .automatic)

            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlight, !isProgrammaticTextUpdate else { return }
            // shouldChangeTextIn 已处理用户编辑并入栈；此回调仅处理未被拦截的情况
            parent.appState.updateEditorDocumentContent(
                globalWorkspaceKey: parent.globalWorkspaceKey,
                path: parent.path,
                content: textView.text
            )

            // 编辑时自动展开包含光标位置的已折叠区域
            if let snapshot = lastStructureSnapshot {
                let cursorLine = lineNumber(for: textView.selectedRange.location, in: textView.text ?? "")
                var foldState = parent.appState.foldingState(for: parent.documentKey)
                let beforeCount = foldState.collapsedRegionIDs.count
                foldState.expandRegions(containingLine: cursorLine, in: snapshot)
                if foldState.collapsedRegionIDs.count != beforeCount {
                    parent.appState.updateFoldingState(foldState, for: parent.documentKey)
                }
                parent.appState.updateCurrentLine(cursorLine, for: parent.documentKey)
            }

            // 更新辅助栏撤销/重做状态（来自共享历史）
            accessoryView?.canUndo = parent.appState.editorCanUndo(documentKey: parent.documentKey)
            accessoryView?.canRedo = parent.appState.editorCanRedo(documentKey: parent.documentKey)

            // 用户输入后重新应用高亮和折叠
            applySyntaxHighlighting(to: textView, filePath: parent.path)
            applyFoldingProjection(to: textView)
            refreshPairMatchOverlay(textView: textView)
            // 刷新补全状态
            refreshAutocompleteState(textView: textView, triggerKind: .automatic)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingHighlight else { return }
            let cursorLine = lineNumber(for: textView.selectedRange.location, in: textView.text ?? "")
            let oldLine = parent.appState.gutterState(for: parent.documentKey).currentLine
            if cursorLine != oldLine {
                parent.appState.updateCurrentLine(cursorLine, for: parent.documentKey)
                updateGutterOverlayIfNeeded(textView: textView)
            }
            // 选区变化时刷新括号/引号匹配覆盖层
            refreshPairMatchOverlay(textView: textView)
            // 选区变化时刷新补全（纯光标移动也应关闭不相关的补全）
            if !isProgrammaticTextUpdate {
                refreshAutocompleteState(textView: textView, triggerKind: .automatic)
            }
        }

        /// 计算字符偏移对应的行号（0-based）
        private func lineNumber(for charOffset: Int, in text: String) -> Int {
            let prefix = text.prefix(charOffset)
            return prefix.filter { $0 == "\n" }.count
        }

        /// 检测当前系统主题
        private func currentTheme(for textView: UITextView) -> EditorSyntaxTheme {
            if textView.traitCollection.userInterfaceStyle == .dark {
                return .systemDark
            }
            return .systemLight
        }

        /// 应用语法高亮到 UITextView
        func applySyntaxHighlighting(to textView: UITextView, filePath: String) {
            let text = textView.text ?? ""
            guard !text.isEmpty else {
                lastAppliedFingerprint = nil
                lastAppliedTheme = nil
                return
            }

            let theme = currentTheme(for: textView)
            let snapshot = highlighter.highlight(filePath: filePath, text: text, theme: theme)

            // 校验内容版本匹配
            let currentText = textView.text ?? ""
            let currentFingerprint = EditorSyntaxFingerprint.compute(currentText)
            guard snapshot.contentFingerprint == currentFingerprint else { return }

            // 跳过重复应用
            if lastAppliedFingerprint == snapshot.contentFingerprint,
               lastAppliedTheme == snapshot.theme {
                return
            }

            applySnapshot(snapshot, to: textView, theme: theme)
        }

        /// 当主题变化时重新应用高亮
        func applyHighlightingIfThemeChanged(to textView: UITextView, filePath: String) {
            let theme = currentTheme(for: textView)
            guard theme != lastAppliedTheme else { return }
            let text = textView.text ?? ""
            guard !text.isEmpty else { return }

            let snapshot = highlighter.highlight(filePath: filePath, text: text, theme: theme)
            let currentFingerprint = EditorSyntaxFingerprint.compute(textView.text ?? "")
            guard snapshot.contentFingerprint == currentFingerprint else { return }

            applySnapshot(snapshot, to: textView, theme: theme)
        }

        /// 将快照属性应用到 UITextView
        private func applySnapshot(_ snapshot: EditorSyntaxSnapshot, to textView: UITextView, theme: EditorSyntaxTheme) {
            let selectedRange = textView.selectedRange
            let scrollOffset = textView.contentOffset
            let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let colorMap = EditorSyntaxColorMapIOS.colors(for: theme)

            isApplyingHighlight = true

            let attrText = NSMutableAttributedString(string: textView.text ?? "")
            let fullRange = NSRange(location: 0, length: attrText.length)

            // 设置默认属性
            attrText.setAttributes([
                .font: font,
                .foregroundColor: colorMap[.plain] ?? UIColor.label,
            ], range: fullRange)

            // 逐条应用高亮
            for run in snapshot.runs {
                guard run.location + run.length <= attrText.length else { continue }
                let color = colorMap[run.role] ?? colorMap[.plain] ?? UIColor.label
                attrText.addAttributes([.foregroundColor: color], range: run.nsRange)
            }

            textView.attributedText = attrText

            // 恢复选区和滚动位置
            let maxLocation = (textView.text as NSString).length
            if selectedRange.location <= maxLocation {
                textView.selectedRange = NSRange(
                    location: min(selectedRange.location, maxLocation),
                    length: min(selectedRange.length, maxLocation - min(selectedRange.location, maxLocation))
                )
            }
            textView.setContentOffset(scrollOffset, animated: false)

            isApplyingHighlight = false

            lastAppliedFingerprint = snapshot.contentFingerprint
            lastAppliedTheme = theme
        }

        // MARK: - 折叠投影

        /// 计算并应用折叠投影到 overlay
        func applyFoldingProjection(to textView: UITextView) {
            let filePath = parent.path
            let text = textView.text ?? ""

            // 计算结构快照
            let snapshot = structureAnalyzer.analyze(filePath: filePath, text: text)
            lastStructureSnapshot = snapshot

            // 获取当前折叠状态并 reconcile
            let docKey = parent.documentKey
            var foldState = parent.appState.foldingState(for: docKey)
            foldState.reconcile(snapshot: snapshot)
            parent.appState.updateFoldingState(foldState, for: docKey)

            // 生成折叠投影
            let foldingProjection = EditorCodeFoldingProjection.make(snapshot: snapshot, state: foldState)

            // 获取 gutter 状态并构建 gutter 投影
            let gutterState = parent.appState.gutterState(for: docKey)
            let gutterProjection = EditorGutterProjectionBuilder.make(
                snapshot: snapshot,
                folding: foldingProjection,
                state: gutterState
            )

            // 更新缓存指纹
            lastAppliedFoldingFingerprint = snapshot.contentFingerprint
            lastAppliedCollapsedCount = foldState.collapsedRegionIDs.count
            lastGutterCacheKey = (snapshot.contentFingerprint, foldState.collapsedRegionIDs.count, gutterState.currentLine, gutterState.breakpoints.count)

            // 更新 overlay
            updateGutterOverlay(gutterProjection: gutterProjection, foldingProjection: foldingProjection, textView: textView)
        }

        /// 仅在折叠状态发生变化时重新应用
        func applyFoldingProjectionIfNeeded(to textView: UITextView) {
            let docKey = parent.documentKey
            let foldState = parent.appState.foldingState(for: docKey)
            let gutterState = parent.appState.gutterState(for: docKey)
            let currentFingerprint = EditorSyntaxFingerprint.compute(textView.text ?? "")
            let currentCacheKey = (currentFingerprint, foldState.collapsedRegionIDs.count, gutterState.currentLine, gutterState.breakpoints.count)

            if let last = lastGutterCacheKey,
               last.0 == currentCacheKey.0,
               last.1 == currentCacheKey.1,
               last.2 == currentCacheKey.2,
               last.3 == currentCacheKey.3 {
                return
            }
            applyFoldingProjection(to: textView)
        }

        /// 仅刷新 gutter 显示（当前行/断点变化但文本和折叠不变时）
        func updateGutterOverlayIfNeeded(textView: UITextView) {
            guard let snapshot = lastStructureSnapshot else { return }

            let docKey = parent.documentKey
            let foldState = parent.appState.foldingState(for: docKey)
            let foldingProjection = EditorCodeFoldingProjection.make(snapshot: snapshot, state: foldState)
            let gutterState = parent.appState.gutterState(for: docKey)
            let gutterProjection = EditorGutterProjectionBuilder.make(
                snapshot: snapshot,
                folding: foldingProjection,
                state: gutterState
            )

            lastGutterCacheKey = (snapshot.contentFingerprint, foldState.collapsedRegionIDs.count, gutterState.currentLine, gutterState.breakpoints.count)
            updateGutterOverlay(gutterProjection: gutterProjection, foldingProjection: foldingProjection, textView: textView)
        }

        /// 更新 gutter overlay 显示
        private func updateGutterOverlay(gutterProjection: EditorGutterProjection, foldingProjection: EditorCodeFoldingProjection, textView: UITextView) {
            guard let overlay = foldOverlay else { return }

            let text = textView.text ?? ""
            let lines = text.components(separatedBy: "\n")
            let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let lineHeight = font.lineHeight

            // 计算 gutter 宽度
            let charWidth: CGFloat = 8.4
            let metrics = gutterProjection.layoutMetrics
            let gutterWidth = charWidth * CGFloat(max(metrics.lineNumberDigits, metrics.minimumCharacterColumns) + metrics.leadingAccessorySlots) + 12

            // 同步更新 textView 左侧 inset
            let newInset = UIEdgeInsets(top: 8, left: gutterWidth, bottom: 8, right: 8)
            if textView.textContainerInset != newInset {
                textView.textContainerInset = newInset
            }

            // 构建 gutter 行项的 rect 信息
            var lineItemRects: [(item: EditorGutterLineItem, rect: CGRect)] = []
            for item in gutterProjection.lineItems {
                guard item.line < lines.count else { continue }
                let y = CGFloat(item.line) * lineHeight + textView.textContainerInset.top
                let rect = CGRect(x: 0, y: y, width: gutterWidth, height: lineHeight)
                lineItemRects.append((item, rect))
            }

            // 构建缩进导线的 rect 信息
            var guideLines: [(guide: EditorIndentGuideSegment, startY: CGFloat, endY: CGFloat, x: CGFloat)] = []
            for guide in gutterProjection.visibleIndentGuides {
                guard guide.startLine < lines.count, guide.endLine < lines.count else { continue }

                let startY = CGFloat(guide.startLine) * lineHeight + textView.textContainerInset.top
                let endY = CGFloat(guide.endLine + 1) * lineHeight + textView.textContainerInset.top
                let x = CGFloat(guide.column) * charWidth + textView.textContainerInset.left

                guideLines.append((guide, startY, endY, x))
            }

            let isDark = textView.traitCollection.userInterfaceStyle == .dark
            overlay.updateContent(
                lineItems: lineItemRects,
                guides: guideLines,
                isDarkMode: isDark,
                metrics: gutterProjection.layoutMetrics
            )

            // 更新 overlay 尺寸
            overlay.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: textView.contentSize.height)
        }

        // MARK: - 括号/引号匹配覆盖层

        /// 刷新括号/引号匹配覆盖层
        func refreshPairMatchOverlay(textView: UITextView) {
            let filePath = parent.path
            let text = textView.text ?? ""
            let selection = textView.selectedRange
            let theme = currentTheme(for: textView)
            let fingerprint = EditorSyntaxFingerprint.compute(text)

            // 缓存命中则跳过
            let cacheKey = (fingerprint, selection.location, theme)
            if let last = lastPairMatchCacheKey,
               last.0 == cacheKey.0,
               last.1 == cacheKey.1,
               last.2 == cacheKey.2,
               selection.length == 0 {
                return
            }
            lastPairMatchCacheKey = cacheKey

            let snapshot = EditorPairMatcher.match(
                filePath: filePath,
                text: text,
                selectionLocation: selection.location,
                selectionLength: selection.length
            )

            // 清空旧覆盖层
            clearPairMatchOverlay()

            guard snapshot.state != .inactive, !snapshot.highlights.isEmpty else { return }

            let isDark = theme == .systemDark
            let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let lineHeight = font.lineHeight

            for highlight in snapshot.highlights {
                let nsRange = NSRange(location: highlight.location, length: highlight.length)
                guard nsRange.location + nsRange.length <= (text as NSString).length else { continue }

                // 使用 UITextView 的坐标系统计算字符位置
                guard let start = textView.position(from: textView.beginningOfDocument, offset: nsRange.location),
                      let end = textView.position(from: start, offset: nsRange.length),
                      let textRange = textView.textRange(from: start, to: end) else { continue }

                let rect = textView.firstRect(for: textRange)
                guard !rect.isNull, !rect.isInfinite else { continue }

                let adjustedRect = CGRect(
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: max(rect.width, 8),
                    height: rect.height
                )

                let overlayView = UIView(frame: adjustedRect)

                switch highlight.role {
                case .activeDelimiter, .pairedDelimiter:
                    overlayView.backgroundColor = isDark
                        ? UIColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 0.25)
                        : UIColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 0.15)
                    overlayView.layer.cornerRadius = 2
                case .mismatchDelimiter:
                    overlayView.backgroundColor = .clear
                    overlayView.layer.borderColor = isDark
                        ? UIColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.7).cgColor
                        : UIColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 0.6).cgColor
                    overlayView.layer.borderWidth = 1
                    overlayView.layer.cornerRadius = 2
                }

                overlayView.isUserInteractionEnabled = false
                textView.addSubview(overlayView)
                pairMatchOverlays.append(overlayView)
            }
        }

        /// 清空匹配覆盖层
        func clearPairMatchOverlay() {
            for view in pairMatchOverlays {
                view.removeFromSuperview()
            }
            pairMatchOverlays.removeAll()
            lastPairMatchCacheKey = nil
        }

        // MARK: - 自动补全

        /// 刷新补全状态
        func refreshAutocompleteState(textView: UITextView, triggerKind: EditorAutocompleteTriggerKind) {
            let docKey = parent.documentKey

            // 检查文档加载状态
            let wsKey = parent.globalWorkspaceKey
            if let session = parent.appState.getEditorDocument(globalWorkspaceKey: wsKey, path: parent.path),
               session.loadStatus != .ready {
                dismissAutocompletePopup(textView: textView)
                return
            }

            let text = textView.text ?? ""
            let cursorLocation = textView.selectedRange.location

            let context = EditorAutocompleteContext(
                filePath: parent.path,
                text: text,
                cursorLocation: cursorLocation,
                triggerKind: triggerKind
            )

            let previousState = parent.appState.autocompleteState(for: docKey)
            let newState = autocompleteEngine.update(context: context, previousState: previousState)
            parent.appState.updateAutocompleteState(newState, for: docKey)

            if newState.isVisible && !newState.items.isEmpty {
                showAutocompletePopup(textView: textView, state: newState)
            } else {
                dismissAutocompletePopup(textView: textView)
            }

            // 更新辅助栏补全按钮状态
            accessoryView?.hasAutocompleteCandidates = newState.isVisible && !newState.items.isEmpty
        }

        /// 手动触发补全
        func triggerManualAutocomplete(textView: UITextView) {
            refreshAutocompleteState(textView: textView, triggerKind: .manual)
        }

        /// 接受候选
        func acceptSelectedAutocomplete(textView: UITextView) {
            let docKey = parent.documentKey
            let state = parent.appState.autocompleteState(for: docKey)
            guard state.isVisible, state.selectedIndex < state.items.count else { return }

            let selectedItem = state.items[state.selectedIndex]
            let currentText = textView.text ?? ""
            guard let result = parent.appState.applyAcceptedAutocomplete(
                selectedItem,
                for: docKey,
                currentText: currentText
            ) else { return }

            // 记录编辑命令到共享历史
            let command = EditorEditCommand(
                mutation: EditorTextMutation(
                    rangeLocation: state.replacementRange.location,
                    rangeLength: state.replacementRange.length,
                    replacementText: selectedItem.insertText
                ),
                beforeSelection: EditorSelectionSnapshot(
                    location: textView.selectedRange.location,
                    length: textView.selectedRange.length
                ),
                afterSelection: result.selection,
                timestamp: Date(),
                replacedText: (currentText as NSString).substring(with: state.replacementRange)
            )
            _ = parent.appState.recordEditorEdit(
                currentText: currentText,
                command: command,
                documentKey: docKey
            )

            // 写回
            isProgrammaticTextUpdate = true
            textView.text = result.text
            let maxLen = (result.text as NSString).length
            textView.selectedRange = NSRange(
                location: min(result.selection.location, maxLen),
                length: 0
            )
            isProgrammaticTextUpdate = false

            parent.appState.updateEditorDocumentContent(
                globalWorkspaceKey: parent.globalWorkspaceKey,
                path: parent.path,
                content: result.text
            )

            // 关闭弹层
            dismissAutocompletePopup(textView: textView)

            // 刷新
            accessoryView?.canUndo = parent.appState.editorCanUndo(documentKey: docKey)
            accessoryView?.canRedo = parent.appState.editorCanRedo(documentKey: docKey)
            applySyntaxHighlighting(to: textView, filePath: parent.path)
            applyFoldingProjection(to: textView)
            refreshPairMatchOverlay(textView: textView)
        }

        /// 显示补全弹层
        private func showAutocompletePopup(textView: UITextView, state: EditorAutocompleteState) {
            if autocompletePopupView == nil {
                let popup = EditorAutocompletePopupUIView()
                popup.onAccept = { [weak self, weak textView] index in
                    guard let self = self, let textView = textView else { return }
                    let docKey = self.parent.documentKey
                    var s = self.parent.appState.autocompleteState(for: docKey)
                    s.selectedIndex = index
                    self.parent.appState.updateAutocompleteState(s, for: docKey)
                    self.acceptSelectedAutocomplete(textView: textView)
                }
                textView.addSubview(popup)
                autocompletePopupView = popup
            }

            guard let popup = autocompletePopupView else { return }
            popup.update(items: state.items, selectedIndex: state.selectedIndex)

            let caretRect = caretRectInTextView(textView: textView, at: state.replacementRange.location)
            let popupSize = popup.fittingPopupSize
            var origin = CGPoint(
                x: caretRect.origin.x,
                y: caretRect.maxY + 2
            )

            // 确保显示在编辑区内
            let visibleRect = textView.bounds
            if origin.y + popupSize.height > visibleRect.maxY - 44 {
                origin.y = caretRect.origin.y - popupSize.height - 2
            }
            if origin.x + popupSize.width > visibleRect.maxX - 8 {
                origin.x = max(8, visibleRect.maxX - popupSize.width - 8)
            }

            popup.frame = CGRect(origin: origin, size: popupSize)
            popup.isHidden = false
        }

        /// 关闭补全弹层
        func dismissAutocompletePopup(textView: UITextView? = nil) {
            autocompletePopupView?.isHidden = true
            parent.appState.resetAutocompleteState(for: parent.documentKey)
            accessoryView?.hasAutocompleteCandidates = false
        }

        /// 补全面板是否可见
        var isAutocompleteVisible: Bool {
            parent.appState.autocompleteState(for: parent.documentKey).isVisible
        }

        /// 计算 textView 中指定字符偏移处的 caret rect
        private func caretRectInTextView(textView: UITextView, at charOffset: Int) -> CGRect {
            let nsText = (textView.text ?? "") as NSString
            let safeOffset = max(0, min(charOffset, nsText.length))
            guard let beginning = textView.position(from: textView.beginningOfDocument, offset: safeOffset),
                  let textRange = textView.textRange(from: beginning, to: beginning) else {
                return .zero
            }
            return textView.firstRect(for: textRange)
        }
    }
}

// MARK: - 编辑器补全候选弹层（iOS）

/// iOS 补全候选弹层视图（UIView 子类，作为 textView 的子视图显示）。
class EditorAutocompletePopupUIView: UIView {
    var onAccept: ((Int) -> Void)?
    private var items: [EditorAutocompleteItem] = []
    private var selectedIndex: Int = 0

    private let rowHeight: CGFloat = 36
    private let maxVisibleRows = 6
    private let popupWidth: CGFloat = 260

    var fittingPopupSize: CGSize {
        let rows = min(items.count, maxVisibleRows)
        return CGSize(width: popupWidth, height: CGFloat(rows) * rowHeight + 4)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 0.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(items: [EditorAutocompleteItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = selectedIndex
        rebuildRows()
    }

    private func rebuildRows() {
        subviews.forEach { $0.removeFromSuperview() }

        let scrollView = UIScrollView(frame: CGRect(origin: .zero, size: fittingPopupSize))
        scrollView.showsVerticalScrollIndicator = items.count > maxVisibleRows
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(scrollView)

        let contentHeight = CGFloat(items.count) * rowHeight
        scrollView.contentSize = CGSize(width: popupWidth, height: contentHeight)

        for (i, item) in items.enumerated() {
            let row = makeRow(item: item, index: i, isSelected: i == selectedIndex)
            row.frame = CGRect(x: 0, y: CGFloat(i) * rowHeight, width: popupWidth, height: rowHeight)
            scrollView.addSubview(row)
        }
    }

    private func makeRow(item: EditorAutocompleteItem, index: Int, isSelected: Bool) -> UIView {
        let row = UIView()
        row.backgroundColor = isSelected ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
        row.tag = index

        let iconLabel = UILabel()
        iconLabel.text = kindIcon(item.kind)
        iconLabel.font = .systemFont(ofSize: 12)
        iconLabel.textAlignment = .center
        iconLabel.frame = CGRect(x: 4, y: 8, width: 20, height: 20)
        row.addSubview(iconLabel)

        let titleLabel = UILabel()
        titleLabel.text = item.title
        titleLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = CGRect(x: 28, y: 8, width: popupWidth - 90, height: 20)
        row.addSubview(titleLabel)

        if let detail = item.detail {
            let detailLabel = UILabel()
            detailLabel.text = detail
            detailLabel.font = .systemFont(ofSize: 10)
            detailLabel.textColor = .secondaryLabel
            detailLabel.textAlignment = .right
            detailLabel.frame = CGRect(x: popupWidth - 64, y: 10, width: 58, height: 16)
            row.addSubview(detailLabel)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(rowTapped(_:)))
        row.addGestureRecognizer(tap)
        row.isUserInteractionEnabled = true

        return row
    }

    private func kindIcon(_ kind: EditorAutocompleteItemKind) -> String {
        switch kind {
        case .documentSymbol: return "𝑥"
        case .languageKeyword: return "K"
        case .languageTemplate: return "T"
        }
    }

    @objc private func rowTapped(_ sender: UITapGestureRecognizer) {
        guard let view = sender.view else { return }
        onAccept?(view.tag)
    }
}

// MARK: - 统一 Gutter 视图（iOS）

/// iOS 编辑器统一 gutter 覆盖层。
/// 作为 UITextView 的子视图，跟随内容滚动。
/// 通过共享 gutter 投影渲染行号、当前行高亮、断点圆点、折叠控件和缩进导线。
class EditorFoldOverlayUIView: UIView {
    /// 折叠/展开按钮点击回调
    var onToggleFold: ((EditorFoldRegionID) -> Void)?
    /// 断点切换回调（0-based 行号）
    var onToggleBreakpoint: ((Int) -> Void)?

    private var lineItemRects: [(item: EditorGutterLineItem, rect: CGRect)] = []
    private var guideLines: [(guide: EditorIndentGuideSegment, startY: CGFloat, endY: CGFloat, x: CGFloat)] = []
    private var isDarkMode: Bool = false
    private var metrics: EditorGutterLayoutMetrics = EditorGutterLayoutMetrics(lineNumberDigits: 1)

    func updateContent(
        lineItems: [(item: EditorGutterLineItem, rect: CGRect)],
        guides: [(guide: EditorIndentGuideSegment, startY: CGFloat, endY: CGFloat, x: CGFloat)],
        isDarkMode: Bool,
        metrics: EditorGutterLayoutMetrics
    ) {
        self.lineItemRects = lineItems
        self.guideLines = guides
        self.isDarkMode = isDarkMode
        self.metrics = metrics
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)

        guard let context = UIGraphicsGetCurrentContext() else { return }

        let charWidth: CGFloat = 8.4
        let breakpointAreaWidth: CGFloat = 16
        let foldAreaWidth: CGFloat = 16
        let accessoryWidth = breakpointAreaWidth + foldAreaWidth
        let lineNumberX = accessoryWidth + 2

        // 绘制缩进导线
        let guideColor = isDarkMode
            ? UIColor(white: 1.0, alpha: 0.08)
            : UIColor(white: 0.0, alpha: 0.08)
        context.setStrokeColor(guideColor.cgColor)
        context.setLineWidth(1.0)

        for guideLine in guideLines {
            guard guideLine.endY >= rect.minY, guideLine.startY <= rect.maxY else { continue }
            context.move(to: CGPoint(x: guideLine.x, y: guideLine.startY))
            context.addLine(to: CGPoint(x: guideLine.x, y: guideLine.endY))
            context.strokePath()
        }

        // 绘制行号、当前行高亮、断点和折叠按钮
        let normalLineNumberColor = isDarkMode
            ? UIColor(white: 1.0, alpha: 0.3)
            : UIColor(white: 0.0, alpha: 0.3)
        let currentLineNumberColor = isDarkMode
            ? UIColor(white: 1.0, alpha: 0.8)
            : UIColor(white: 0.0, alpha: 0.8)
        let currentLineHighlightColor = isDarkMode
            ? UIColor(white: 1.0, alpha: 0.06)
            : UIColor(white: 0.0, alpha: 0.04)
        let breakpointColor = UIColor(red: 0.9, green: 0.25, blue: 0.2, alpha: 0.85)
        let foldButtonColor = isDarkMode
            ? UIColor(white: 1.0, alpha: 0.35)
            : UIColor(white: 0.0, alpha: 0.35)

        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        for (item, itemRect) in lineItemRects {
            guard itemRect.intersects(rect) else { continue }

            // 当前行背景高亮
            if item.isCurrentLine {
                context.setFillColor(currentLineHighlightColor.cgColor)
                context.fill(CGRect(x: 0, y: itemRect.origin.y, width: bounds.width, height: itemRect.height))
            }

            // 断点圆点
            if item.hasBreakpoint {
                let bpSize: CGFloat = 12
                let bpRect = CGRect(
                    x: (breakpointAreaWidth - bpSize) / 2,
                    y: itemRect.midY - bpSize / 2,
                    width: bpSize,
                    height: bpSize
                )
                context.setFillColor(breakpointColor.cgColor)
                context.fillEllipse(in: bpRect)
            }

            // 折叠按钮
            if let foldControl = item.foldControl {
                let buttonSize: CGFloat = 12
                let buttonCenterX = breakpointAreaWidth + foldAreaWidth / 2
                let buttonCenterY = itemRect.midY

                let path = UIBezierPath()
                if foldControl.isCollapsed {
                    // 右指三角 ▶
                    path.move(to: CGPoint(x: buttonCenterX - buttonSize / 3, y: buttonCenterY - buttonSize / 2))
                    path.addLine(to: CGPoint(x: buttonCenterX + buttonSize / 3, y: buttonCenterY))
                    path.addLine(to: CGPoint(x: buttonCenterX - buttonSize / 3, y: buttonCenterY + buttonSize / 2))
                } else {
                    // 下指三角 ▼
                    path.move(to: CGPoint(x: buttonCenterX - buttonSize / 2, y: buttonCenterY - buttonSize / 3))
                    path.addLine(to: CGPoint(x: buttonCenterX + buttonSize / 2, y: buttonCenterY - buttonSize / 3))
                    path.addLine(to: CGPoint(x: buttonCenterX, y: buttonCenterY + buttonSize / 3))
                }
                path.close()
                foldButtonColor.setFill()
                path.fill()
            }

            // 行号文字（右对齐）
            let textColor = item.isCurrentLine ? currentLineNumberColor : normalLineNumberColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
            ]
            let numStr = item.displayLineNumber as NSString
            let textSize = numStr.size(withAttributes: attributes)
            let maxDigitWidth = charWidth * CGFloat(max(metrics.lineNumberDigits, metrics.minimumCharacterColumns))
            let textX = lineNumberX + maxDigitWidth - textSize.width
            let textY = itemRect.origin.y + (itemRect.height - textSize.height) / 2
            numStr.draw(at: CGPoint(x: textX, y: textY), withAttributes: attributes)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else {
            super.touchesBegan(touches, with: event)
            return
        }
        let location = touch.location(in: self)
        let breakpointAreaWidth: CGFloat = 16
        let foldAreaWidth: CGFloat = 16

        for (item, itemRect) in lineItemRects {
            let hitRect = itemRect.insetBy(dx: -8, dy: -4)
            guard hitRect.contains(location) else { continue }

            // 折叠按钮区域优先（触控优先级固定为折叠控件优先）
            if item.foldControl != nil {
                let foldHitX = breakpointAreaWidth...(breakpointAreaWidth + foldAreaWidth)
                if foldHitX.contains(location.x) {
                    onToggleFold?(item.foldControl!.region.id)
                    return
                }
            }

            // 断点区域命中
            if location.x < breakpointAreaWidth + 4 {
                onToggleBreakpoint?(item.line)
                return
            }
        }

        super.touchesBegan(touches, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let breakpointAreaWidth: CGFloat = 16
        let foldAreaWidth: CGFloat = 16

        for (item, itemRect) in lineItemRects {
            let hitRect = itemRect.insetBy(dx: -8, dy: -4)
            guard hitRect.contains(point) else { continue }

            // 折叠按钮区域
            if item.foldControl != nil {
                let foldHitX = breakpointAreaWidth...(breakpointAreaWidth + foldAreaWidth)
                if foldHitX.contains(point.x) { return true }
            }

            // 断点区域
            if point.x < breakpointAreaWidth + 4 { return true }
        }
        // 其余区域透传文本编辑
        return false
    }

    override var accessibilityElements: [Any]? {
        get {
            var elements: [UIAccessibilityElement] = []
            for (item, itemRect) in lineItemRects {
                // 折叠按钮辅助功能标签
                if let foldControl = item.foldControl {
                    let element = UIAccessibilityElement(accessibilityContainer: self)
                    element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(itemRect, in: self)
                    element.accessibilityLabel = foldControl.isCollapsed ? "展开代码块" : "收起代码块"
                    element.accessibilityTraits = .button
                    elements.append(element)
                }
                // 断点标记辅助功能标签
                if item.hasBreakpoint {
                    let element = UIAccessibilityElement(accessibilityContainer: self)
                    element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(itemRect, in: self)
                    element.accessibilityLabel = "断点，第 \(item.displayLineNumber) 行"
                    element.accessibilityTraits = .button
                    elements.append(element)
                }
            }
            return elements
        }
        set { super.accessibilityElements = newValue }
    }
}

// MARK: - 通知名称

extension Notification.Name {
    static let mobileEditorFindPrevious = Notification.Name("mobileEditorFindPrevious")
    static let mobileEditorFindNext = Notification.Name("mobileEditorFindNext")
}
