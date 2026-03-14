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

struct EditorTextViewWrapper: UIViewRepresentable {
    @ObservedObject var appState: MobileAppState
    let documentKey: EditorDocumentKey
    let globalWorkspaceKey: String
    let path: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
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

        // 设置键盘辅助栏
        let accessory = EditorInputAccessoryView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        accessory.onSave = { [weak textView] in
            guard textView != nil else { return }
            DispatchQueue.main.async {
                self.appState.saveDocument(documentKey: self.documentKey)
            }
        }
        accessory.onUndo = { [weak textView] in
            textView?.undoManager?.undo()
        }
        accessory.onRedo = { [weak textView] in
            textView?.undoManager?.redo()
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
        textView.inputAccessoryView = accessory
        context.coordinator.accessoryView = accessory

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard let session = appState.getEditorDocument(globalWorkspaceKey: globalWorkspaceKey, path: path),
              session.loadStatus == .ready else { return }

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
            // 文本变化后重新应用高亮
            context.coordinator.applySyntaxHighlighting(to: textView, filePath: path)
        } else {
            // 文本未变，检查主题变化
            context.coordinator.applyHighlightingIfThemeChanged(to: textView, filePath: path)
        }

        // 更新辅助栏的撤销/重做状态
        context.coordinator.accessoryView?.canUndo = textView.undoManager?.canUndo ?? false
        context.coordinator.accessoryView?.canRedo = textView.undoManager?.canRedo ?? false
    }

    class Coordinator: NSObject, UITextViewDelegate {
        let parent: EditorTextViewWrapper
        weak var accessoryView: EditorInputAccessoryView?
        private let highlighter = EditorSyntaxHighlighter()
        /// 上次应用的高亮快照指纹
        private var lastAppliedFingerprint: Int?
        /// 上次应用的主题
        private var lastAppliedTheme: EditorSyntaxTheme?
        /// 标记当前是否正在程序性地更新属性（防止循环写回）
        var isApplyingHighlight = false

        init(parent: EditorTextViewWrapper) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlight else { return }
            parent.appState.updateEditorDocumentContent(
                globalWorkspaceKey: parent.globalWorkspaceKey,
                path: parent.path,
                content: textView.text
            )

            // 更新辅助栏撤销/重做状态
            accessoryView?.canUndo = textView.undoManager?.canUndo ?? false
            accessoryView?.canRedo = textView.undoManager?.canRedo ?? false

            // 用户输入后重新应用高亮
            applySyntaxHighlighting(to: textView, filePath: parent.path)
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
    }
}

// MARK: - 通知名称

extension Notification.Name {
    static let mobileEditorFindPrevious = Notification.Name("mobileEditorFindPrevious")
    static let mobileEditorFindNext = Notification.Name("mobileEditorFindNext")
}
