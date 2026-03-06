#if os(macOS)
import SwiftTerm
import SwiftUI
import AppKit

extension Notification.Name {
    static let terminalSearchRequested = Notification.Name("terminalSearchRequested")
}

protocol MacTerminalOutputSink: AnyObject {
    func writeOutput(_ bytes: [UInt8])
    func focusTerminal()
    func resetTerminal()
}

// MARK: - 终端搜索引擎（可独立测试的纯逻辑层）

/// 单条搜索匹配结果
struct TerminalSearchMatch: Equatable {
    let row: Int        // 行索引（相对于搜索时的 buffer 快照，0 = 第一行）
    let startCol: Int   // 匹配起始列（含）
    let endCol: Int     // 匹配结束列（不含）
}

/// 纯值类型搜索引擎，持有搜索状态并在提供的文本上执行搜索
struct TerminalSearchEngine {
    private(set) var query: String = ""
    private(set) var caseSensitive: Bool = false
    private(set) var useRegex: Bool = false
    private(set) var results: [TerminalSearchMatch] = []
    private(set) var currentMatchIndex: Int = -1

    var matchCount: Int { results.count }

    /// 当前高亮的匹配项；nil 表示无结果
    var currentMatch: TerminalSearchMatch? {
        guard currentMatchIndex >= 0, currentMatchIndex < results.count else { return nil }
        return results[currentMatchIndex]
    }

    /// 在给定的行文本数组中执行搜索，更新结果列表并将索引指向第一个匹配。
    /// - Parameters:
    ///   - lines: 每个元素对应终端缓冲区的一行文本
    ///   - query: 搜索词
    ///   - caseSensitive: 是否大小写敏感
    ///   - useRegex: 是否使用正则表达式
    mutating func search(in lines: [String], query: String, caseSensitive: Bool, useRegex: Bool) {
        self.query = query
        self.caseSensitive = caseSensitive
        self.useRegex = useRegex
        results = []
        currentMatchIndex = -1

        guard !query.isEmpty else { return }

        var matches: [TerminalSearchMatch] = []
        for (rowIndex, line) in lines.enumerated() {
            let found = findMatches(in: line, row: rowIndex, query: query,
                                    caseSensitive: caseSensitive, useRegex: useRegex)
            matches.append(contentsOf: found)
        }
        results = matches
        if !results.isEmpty { currentMatchIndex = 0 }
    }

    /// 跳转到下一个匹配结果（循环导航）
    mutating func next() {
        guard !results.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % results.count
    }

    /// 跳转到上一个匹配结果（循环导航）
    mutating func previous() {
        guard !results.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + results.count) % results.count
    }

    /// 清空搜索状态
    mutating func clear() {
        query = ""
        results = []
        currentMatchIndex = -1
    }

    // MARK: Private helpers

    private func findMatches(in line: String, row: Int, query: String,
                             caseSensitive: Bool, useRegex: Bool) -> [TerminalSearchMatch] {
        var matches: [TerminalSearchMatch] = []
        if useRegex {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: query, options: options) else { return [] }
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            for result in regex.matches(in: line, options: [], range: range) {
                let startCol = result.range.location
                let endCol = result.range.location + result.range.length
                if startCol < endCol {
                    matches.append(TerminalSearchMatch(row: row, startCol: startCol, endCol: endCol))
                }
            }
        } else {
            let compareOptions: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            var searchRange = line.startIndex..<line.endIndex
            while let found = line.range(of: query, options: compareOptions, range: searchRange) {
                let startCol = line.distance(from: line.startIndex, to: found.lowerBound)
                let endCol = line.distance(from: line.startIndex, to: found.upperBound)
                matches.append(TerminalSearchMatch(row: row, startCol: startCol, endCol: endCol))
                searchRange = found.upperBound..<line.endIndex
            }
        }
        return matches
    }
}

// MARK: - 搜索高亮叠加层

/// 绘制单个搜索匹配高亮矩形的叠加视图
final class SearchHighlightOverlayView: NSView {
    /// 当前高亮矩形（nil 表示不显示）
    var highlightRect: CGRect? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let rect = highlightRect, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 使用半透明橙色作为搜索匹配高亮色
        ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.35).cgColor)
        ctx.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addRect(rect)
        ctx.drawPath(using: .fillStroke)
    }
}

// MARK: - 终端搜索 UI 状态（可观察对象，桥接搜索栏与 Coordinator）

/// 终端搜索栏的可观察状态，由 TerminalContentView 持有并传给 MacSwiftTermTerminalView
final class TerminalSearchState: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var query: String = ""
    @Published var caseSensitive: Bool = false
    @Published var useRegex: Bool = false
    @Published var matchCount: Int = 0
    @Published var currentMatchIndex: Int = -1

    /// 由 Coordinator.setupSearchCallbacks() 注入的回调
    var onSearch: ((String, Bool, Bool) -> Void)?
    var onNextMatch: (() -> Void)?
    var onPreviousMatch: (() -> Void)?
    var onClear: (() -> Void)?

    /// 显示搜索栏
    func show() {
        isVisible = true
    }

    /// 关闭搜索栏，重置状态并通知 Coordinator 清除高亮和归还焦点
    func close() {
        isVisible = false
        query = ""
        matchCount = 0
        currentMatchIndex = -1
        onClear?()
    }

    /// 以当前参数触发搜索
    func triggerSearch() {
        onSearch?(query, caseSensitive, useRegex)
    }

    func triggerNextMatch() { onNextMatch?() }
    func triggerPreviousMatch() { onPreviousMatch?() }
}

// MARK: - 终端搜索栏视图

/// 悬浮在终端视图顶部的搜索条；包含输入框、大小写/正则选项、匹配计数与上下导航按钮
struct TerminalSearchBarView: View {
    @ObservedObject var searchState: TerminalSearchState
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            // 搜索输入框
            TextField("搜索", text: $searchState.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(minWidth: 150)
                .focused($textFieldFocused)
                .onSubmit {
                    if searchState.matchCount > 0 {
                        searchState.triggerNextMatch()
                    } else {
                        searchState.triggerSearch()
                    }
                }
                .onChange(of: searchState.query) { _ in
                    guard searchState.isVisible else { return }
                    searchState.triggerSearch()
                }

            // 大小写敏感切换（Aa）
            Button(action: {
                searchState.caseSensitive.toggle()
                searchState.triggerSearch()
            }) {
                Text("Aa")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(searchState.caseSensitive ? .white : .secondary)
                    .frame(width: 24, height: 18)
                    .background(searchState.caseSensitive ? Color.accentColor.opacity(0.85) : Color.clear)
                    .cornerRadius(3)
            }
            .buttonStyle(.plain)
            .help("大小写敏感")

            // 正则表达式切换（.*）
            Button(action: {
                searchState.useRegex.toggle()
                searchState.triggerSearch()
            }) {
                Text(".*")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(searchState.useRegex ? .white : .secondary)
                    .frame(width: 24, height: 18)
                    .background(searchState.useRegex ? Color.accentColor.opacity(0.85) : Color.clear)
                    .cornerRadius(3)
            }
            .buttonStyle(.plain)
            .help("正则表达式")

            Divider().frame(height: 14)

            // 匹配计数
            Group {
                if searchState.matchCount > 0 {
                    Text("\(searchState.currentMatchIndex + 1)/\(searchState.matchCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 38)
                } else if !searchState.query.isEmpty {
                    Text("无结果")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 38)
                } else {
                    Color.clear.frame(width: 38)
                }
            }

            // 上一个结果
            Button(action: { searchState.triggerPreviousMatch() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(searchState.matchCount == 0)
            .help("上一个")

            // 下一个结果
            Button(action: { searchState.triggerNextMatch() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(searchState.matchCount == 0)
            .help("下一个")

            Divider().frame(height: 14)

            // 关闭搜索框
            Button(action: { searchState.close() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.96))
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
        .onAppear {
            textFieldFocused = true
        }
    }
}

// MARK: - 终端容器视图（TerminalView + 搜索高亮叠加层）

/// 将 TerminalView 与搜索高亮叠加层包装在一起的容器
final class TerminalSearchContainerView: NSView {
    let terminalView: TerminalView
    let highlightOverlay: SearchHighlightOverlayView

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        self.highlightOverlay = SearchHighlightOverlayView()
        super.init(frame: .zero)
        highlightOverlay.isHidden = true
        highlightOverlay.wantsLayer = true
        highlightOverlay.layer?.zPosition = 100
        // overlay 不拦截鼠标事件
        highlightOverlay.alphaValue = 1.0
        addSubview(terminalView)
        addSubview(highlightOverlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
        highlightOverlay.frame = bounds
    }

    /// 更新高亮矩形；传入 nil 则隐藏叠加层
    func updateHighlight(_ rect: CGRect?) {
        if let rect {
            highlightOverlay.highlightRect = rect
            highlightOverlay.isHidden = false
        } else {
            highlightOverlay.highlightRect = nil
            highlightOverlay.isHidden = true
        }
    }
}

struct MacSwiftTermTerminalView: NSViewRepresentable {
    let appState: AppState
    let tabId: UUID
    /// 搜索状态，由 TerminalContentView 持有并通过此属性传入，供 Coordinator 绑定回调
    let searchState: TerminalSearchState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState, tabId: tabId, searchState: searchState)
    }

    func makeNSView(context: Context) -> TerminalSearchContainerView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator

        let terminalFontSize: CGFloat = 13
        if let nerdFont = NSFont(name: "MesloLGS NF", size: terminalFontSize) {
            terminalView.font = nerdFont
        } else {
            terminalView.font = .monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
        }
        terminalView.nativeBackgroundColor = NSColor(
            red: 30 / 255,
            green: 30 / 255,
            blue: 30 / 255,
            alpha: 1
        )
        terminalView.nativeForegroundColor = NSColor(
            red: 212 / 255,
            green: 212 / 255,
            blue: 212 / 255,
            alpha: 1
        )
        terminalView.caretColor = NSColor(
            red: 174 / 255,
            green: 175 / 255,
            blue: 173 / 255,
            alpha: 1
        )
        terminalView.optionAsMetaKey = true
        terminalView.notifyUpdateChanges = false

        let container = TerminalSearchContainerView(terminalView: terminalView)
        context.coordinator.bind(terminalView: terminalView, container: container)
        DispatchQueue.main.async {
            context.coordinator.reportCurrentSizeIfNeeded(from: terminalView)
            _ = terminalView.window?.makeFirstResponder(terminalView)
        }

        return container
    }

    func updateNSView(_ nsView: TerminalSearchContainerView, context: Context) {
        context.coordinator.tabId = tabId
        context.coordinator.bind(terminalView: nsView.terminalView, container: nsView)
        context.coordinator.reportCurrentSizeIfNeeded(from: nsView.terminalView)
    }

    static func dismantleNSView(_ nsView: TerminalSearchContainerView, coordinator: Coordinator) {
        coordinator.unbind(terminalView: nsView.terminalView)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, MacTerminalOutputSink {
        private weak var appState: AppState?
        private weak var terminalView: TerminalView?
        private weak var containerView: TerminalSearchContainerView?
        var tabId: UUID
        private var lastReportedCols: Int = 0
        private var lastReportedRows: Int = 0

        // MARK: - 终端搜索状态

        private var searchEngine = TerminalSearchEngine()
        /// 搜索 UI 状态对象；Coordinator 通过它向 SwiftUI 层反向推送匹配计数等信息
        private let searchState: TerminalSearchState

        /// 当前搜索词（只读，外部通过 performSearch 更新）
        var searchQuery: String { searchEngine.query }
        /// 大小写敏感开关
        var caseSensitive: Bool { searchEngine.caseSensitive }
        /// 正则表达式开关
        var useRegex: Bool { searchEngine.useRegex }
        /// 匹配结果总数
        var matchCount: Int { searchEngine.matchCount }
        /// 当前匹配索引（0-based，-1 表示无结果）
        var currentMatchIndex: Int { searchEngine.currentMatchIndex }

        init(appState: AppState, tabId: UUID, searchState: TerminalSearchState) {
            self.appState = appState
            self.tabId = tabId
            self.searchState = searchState
            super.init()
            setupSearchCallbacks()
        }

        func bind(terminalView: TerminalView, container: TerminalSearchContainerView? = nil) {
            let shouldRebind = self.terminalView !== terminalView
            self.terminalView = terminalView
            if let container { self.containerView = container }
            guard shouldRebind else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState?.attachTerminalSink(self, tabId: self.tabId)
            }
        }

        func unbind(terminalView: TerminalView) {
            if self.terminalView === terminalView {
                self.terminalView = nil
                self.containerView = nil
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState?.detachTerminalSink(self, tabId: self.tabId)
            }
        }

        func reportCurrentSizeIfNeeded(from terminalView: TerminalView) {
            let cols = terminalView.getTerminal().cols
            let rows = terminalView.getTerminal().rows
            guard cols > 0, rows > 0 else { return }
            guard cols != lastReportedCols || rows != lastReportedRows else { return }

            lastReportedCols = cols
            lastReportedRows = rows
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState?.terminalViewDidResize(tabId: self.tabId, cols: cols, rows: rows)
            }
        }

        // MARK: - 终端搜索 API

        /// 向 searchState 注入回调，供 SwiftUI 搜索栏按钮直接调用
        private func setupSearchCallbacks() {
            searchState.onSearch = { [weak self] query, caseSensitive, useRegex in
                self?.performSearch(query: query, caseSensitive: caseSensitive, useRegex: useRegex)
            }
            searchState.onNextMatch = { [weak self] in self?.navigateNextMatch() }
            searchState.onPreviousMatch = { [weak self] in self?.navigatePreviousMatch() }
            searchState.onClear = { [weak self] in self?.clearSearch() }
        }

        /// 在当前可见终端行中执行搜索，并高亮第一个匹配结果。
        /// - Parameters:
        ///   - query: 搜索词（空字符串会清空结果）
        ///   - caseSensitive: 是否大小写敏感
        ///   - useRegex: 是否使用正则表达式
        func performSearch(query: String, caseSensitive: Bool, useRegex: Bool) {
            guard let tv = terminalView else { return }
            let lines = extractVisibleLines(from: tv)
            searchEngine.search(in: lines, query: query, caseSensitive: caseSensitive, useRegex: useRegex)
            highlightCurrentMatch()
            searchState.matchCount = searchEngine.matchCount
            searchState.currentMatchIndex = searchEngine.currentMatchIndex
        }

        /// 跳转到下一个搜索匹配结果（循环导航）
        func navigateNextMatch() {
            searchEngine.next()
            highlightCurrentMatch()
            searchState.currentMatchIndex = searchEngine.currentMatchIndex
        }

        /// 跳转到上一个搜索匹配结果（循环导航）
        func navigatePreviousMatch() {
            searchEngine.previous()
            highlightCurrentMatch()
            searchState.currentMatchIndex = searchEngine.currentMatchIndex
        }

        /// 关闭搜索、清除高亮并将焦点归还给终端
        func clearSearch() {
            searchEngine.clear()
            containerView?.updateHighlight(nil)
            focusTerminal()
            searchState.matchCount = 0
            searchState.currentMatchIndex = -1
        }

        // MARK: - 私有搜索辅助方法

        /// 从 TerminalView 提取当前可见行的文本
        private func extractVisibleLines(from tv: TerminalView) -> [String] {
            let terminal = tv.getTerminal()
            let rows = terminal.rows
            let cols = terminal.cols
            var lines: [String] = []
            for row in 0..<rows {
                var line = ""
                for col in 0..<cols {
                    if let ch = terminal.getCharacter(col: col, row: row) {
                        line.append(ch == "\0" ? " " : ch)
                    } else {
                        line.append(" ")
                    }
                }
                lines.append(line.trimmingCharacters(in: .init(charactersIn: " ")))
            }
            return lines
        }

        /// 根据当前搜索匹配更新高亮叠加层，并滚动到匹配行
        private func highlightCurrentMatch() {
            guard let match = searchEngine.currentMatch,
                  let tv = terminalView,
                  let container = containerView else {
                containerView?.updateHighlight(nil)
                return
            }
            let terminal = tv.getTerminal()
            let rows = max(terminal.rows, 1)
            let cols = max(terminal.cols, 1)
            let viewBounds = tv.bounds
            let cellWidth = viewBounds.width / CGFloat(cols)
            let cellHeight = viewBounds.height / CGFloat(rows)

            let matchLen = match.endCol - match.startCol
            // 坐标系：AppKit 原点在左下角，SwiftTerm row 0 = 顶部可见行
            let x = CGFloat(match.startCol) * cellWidth
            let yFromBottom = viewBounds.height - CGFloat(match.row + 1) * cellHeight
            let width = CGFloat(max(matchLen, 1)) * cellWidth
            let highlightRect = CGRect(x: x, y: yFromBottom, width: width, height: cellHeight)
            container.updateHighlight(highlightRect)
        }

        // MARK: - MacTerminalOutputSink

        func writeOutput(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            terminalView?.feed(byteArray: bytes[...])
        }

        func focusTerminal() {
            guard let terminalView else { return }
            _ = terminalView.window?.makeFirstResponder(terminalView)
        }

        func resetTerminal() {
            let seq: [UInt8] = [
                0x1b, 0x5b, 0x30, 0x6d,
                0x1b, 0x5b, 0x33, 0x4a,
                0x1b, 0x5b, 0x32, 0x4a,
                0x1b, 0x5b, 0x48
            ]
            terminalView?.feed(byteArray: seq[...])
        }

        // MARK: - TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            lastReportedCols = newCols
            lastReportedRows = newRows
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState?.terminalViewDidResize(tabId: self.tabId, cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            if Thread.isMainThread {
                appState?.sendTerminalInputBytes(tabId: tabId, bytes)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.appState?.sendTerminalInputBytes(tabId: self.tabId, bytes)
                }
            }
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            let pb = NSPasteboard.general
            pb.clearContents()
            if let text = String(data: content, encoding: .utf8) {
                pb.setString(text, forType: .string)
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
#endif
