#if os(iOS)
import SwiftTerm
import SwiftUI
import UIKit
import Foundation

private let mobileTerminalBackgroundColor = UIColor(
    red: 30 / 255,
    green: 30 / 255,
    blue: 30 / 255,
    alpha: 1
)

private let mobileTerminalForegroundColor = UIColor(
    red: 212 / 255,
    green: 212 / 255,
    blue: 212 / 255,
    alpha: 1
)

private let mobileTerminalCaretColor = UIColor(
    red: 174 / 255,
    green: 175 / 255,
    blue: 173 / 255,
    alpha: 1
)

/// 原生 SwiftTerm 终端容器
struct SwiftTermTerminalView: UIViewRepresentable {
    let appState: MobileAppState
    /// 顶部安全区高度（通常包含状态栏 + 导航栏高度）。用于给终端滚动内容留出默认起始间距，
    /// 同时仍允许用户滚动把内容推入安全区（因为终端本体会 ignoresSafeArea(.top)）。
    let topSafeAreaInset: CGFloat
    let onKey: (String) -> Void
    let onCtrlArmedChanged: (Bool) -> Void
    let onPaste: () -> Void

    /// SwiftTerm(iOS) 的 TerminalView 内部会直接用 `contentOffset` 计算可见行，并在 updateScroller() 中强制重置 contentOffset。
    /// 为了实现“首屏避开顶部安全区，但允许用户把内容滑进安全区”，这里采用：
    /// 1) 设置 `contentInset.top = topPadding`，允许 top 位置为 `-topPadding`
    /// 2) 在内容高度不足一屏且用户未主动把内容滑到 0 的情况下，把 SwiftTerm 强制重置到 0 的 offset 再纠正为 `-topPadding`
    private final class SafeAreaPaddedTerminalView: TerminalView {
        /// 来自 SwiftUI 侧的提示值（在某些布局下可能为 0）
        var requestedTopPadding: CGFloat = 0 {
            didSet { updateTopPaddingIfNeeded() }
        }

        private var appliedTopPadding: CGFloat = 0
        private var isAdjustingOffset: Bool = false
        private var sawUserDrag: Bool = false
        private var userDismissedTopPadding: Bool = false

        override var contentOffset: CGPoint {
            didSet {
                guard !isAdjustingOffset else { return }

                let interacting = isTracking || isDragging || isDecelerating
                if interacting {
                    sawUserDrag = true
                } else if sawUserDrag {
                    // 用户一次拖拽结束后，如果停在接近 0 的位置，视为“用户主动把内容滑进安全区”，后续不再自动纠正回 -topPadding。
                    if isContentNonScrollable() && contentOffset.y >= -0.5 {
                        userDismissedTopPadding = true
                    }
                    sawUserDrag = false
                }

                enforceInitialTopPaddingIfNeeded()
            }
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            updateTopPaddingIfNeeded()
            enforceInitialTopPaddingIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateTopPaddingIfNeeded()
            enforceInitialTopPaddingIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 布局变化时（首次挂载、旋转、导航栏变化）安全区可能刷新，这里做一次兜底更新。
            updateTopPaddingIfNeeded()
            enforceInitialTopPaddingIfNeeded()
        }

        private func updateTopPaddingIfNeeded() {
            // UIKit 的 safeAreaInsets 在 view 挂到 window 后才可靠；这里取两者较大值。
            let newPadding = max(0, max(requestedTopPadding, safeAreaInsets.top))
            guard abs(newPadding - appliedTopPadding) > 0.5 else {
                // padding 未变化时也需要确保 inset 正确（避免外部把 inset 清掉）
                applyInsets(topPadding: appliedTopPadding)
                return
            }

            appliedTopPadding = newPadding

            // 允许 topPadding 生效，即使内容高度不足一屏也能停在 -topPadding。
            alwaysBounceVertical = true

            applyInsets(topPadding: newPadding)
        }

        private func applyInsets(topPadding: CGFloat) {
            // 让 UIScrollView 允许最小 offset 到 -topPadding（SwiftTerm 绘制仍基于 contentOffset/bounds）
            if abs(contentInset.top - topPadding) > 0.5 {
                contentInset.top = topPadding
            }

            var indicatorInsets = verticalScrollIndicatorInsets
            if abs(indicatorInsets.top - topPadding) > 0.5 {
                indicatorInsets.top = topPadding
                verticalScrollIndicatorInsets = indicatorInsets
            }
        }

        private func isContentNonScrollable() -> Bool {
            // contentSize/bounds 在终端刚挂载时可能为 0，这里做一个保守判定
            guard bounds.height > 1 else { return true }
            return contentSize.height <= bounds.height + 1
        }

        private func enforceInitialTopPaddingIfNeeded() {
            guard appliedTopPadding > 0 else { return }
            guard !userDismissedTopPadding else { return }
            guard !(isTracking || isDragging || isDecelerating) else { return }
            guard isContentNonScrollable() else { return }

            // 仅在 SwiftTerm 把 offset 强制归零(=0) 或接近 0 时，把它纠正到 -topPadding。
            // 这样首屏会下移；但用户拖拽并停在 0 后会被标记为 dismissed，不再自动纠正。
            if contentOffset.y >= -0.5 {
                isAdjustingOffset = true
                setContentOffset(CGPoint(x: contentOffset.x, y: -appliedTopPadding), animated: false)
                isAdjustingOffset = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeUIView(context: Context) -> TerminalView {
        let terminalView = SafeAreaPaddedTerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator
        terminalView.requestedTopPadding = topSafeAreaInset

        // SwiftTerm 的 TerminalView 在部分版本中是 UIScrollView 子类/或内部依赖滚动。
        // 禁用系统自动 inset 与交互式收起键盘，避免在滚动 scrollback 时出现“页面上下抖动”。
        terminalView.contentInsetAdjustmentBehavior = .never
        terminalView.keyboardDismissMode = .none
        terminalView.scrollsToTop = false
        // 终端滚动更像编辑器：关闭回弹可显著降低“拉到底部/顶部时”的抖动感
        terminalView.bounces = false
        // 注意：这里必须为 true，否则在内容不足一屏时 topPadding(-contentInset.top) 可能无法生效
        terminalView.alwaysBounceVertical = true

        // 与原 xterm.js 保持一致的基础视觉配置
        // 使用 MesloLGS NF 以支持 Powerline/Nerd Font 字形，回退到系统等宽字体
        let terminalFontSize: CGFloat = 14
        if let nerdFont = UIFont(name: "MesloLGS NF", size: terminalFontSize) {
            terminalView.font = nerdFont
        } else {
            terminalView.font = .monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
        }
        terminalView.nativeBackgroundColor = mobileTerminalBackgroundColor
        terminalView.nativeForegroundColor = mobileTerminalForegroundColor
        terminalView.caretColor = mobileTerminalCaretColor
        terminalView.optionAsMetaKey = true
        terminalView.notifyUpdateChanges = false

        // 输入体验配置（减少 iOS 智能输入对终端的干扰）
        terminalView.autocapitalizationType = .none
        terminalView.autocorrectionType = .no
        terminalView.spellCheckingType = .no
        terminalView.smartQuotesType = .no
        terminalView.smartDashesType = .no
        terminalView.smartInsertDeleteType = .no

        // 复用现有终端工具栏
        let accessory = TerminalInputAccessoryView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        accessory.onKey = onKey
        accessory.onCtrlArmedChanged = onCtrlArmedChanged
        accessory.onPaste = onPaste
        terminalView.inputAccessoryView = accessory

        context.coordinator.bind(terminalView: terminalView)

        // 首帧后主动上报一次尺寸并尝试聚焦
        DispatchQueue.main.async {
            context.coordinator.reportCurrentSizeIfNeeded(from: terminalView)
            _ = terminalView.becomeFirstResponder()
        }

        return terminalView
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.bind(terminalView: uiView)
        if let padded = uiView as? SafeAreaPaddedTerminalView {
            padded.requestedTopPadding = topSafeAreaInset
        }
        context.coordinator.reportCurrentSizeIfNeeded(from: uiView)
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.unbind(terminalView: uiView)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, MobileTerminalOutputSink {
        private weak var appState: MobileAppState?
        private weak var terminalView: TerminalView?
        private var lastReportedCols: Int = 0
        private var lastReportedRows: Int = 0

        init(appState: MobileAppState) {
            self.appState = appState
        }

        func bind(terminalView: TerminalView) {
            let shouldRebind = self.terminalView !== terminalView
            self.terminalView = terminalView
            guard shouldRebind else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState?.attachTerminalSink(self)
            }
        }

        func unbind(terminalView: TerminalView) {
            if self.terminalView === terminalView {
                self.terminalView = nil
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState?.detachTerminalSink(self)
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
                self?.appState?.terminalViewDidResize(cols: cols, rows: rows)
            }
        }

        // MARK: - MobileTerminalOutputSink

        func writeOutput(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            terminalView?.feed(byteArray: bytes[...])
        }

        func focusTerminal() {
            _ = terminalView?.becomeFirstResponder()
        }

        func resetTerminal() {
            // 使用 ANSI 序列清空屏幕与滚动回放，并重置样式。
            // 说明：SwiftUI 可能复用同一个 TerminalView，若不清空会导致切换终端时内容“混在一起”。
            let seq: [UInt8] = [
                0x1b, 0x5b, 0x30, 0x6d, // ESC[0m reset attributes
                0x1b, 0x5b, 0x33, 0x4a, // ESC[3J clear scrollback (xterm compatible)
                0x1b, 0x5b, 0x32, 0x4a, // ESC[2J clear screen
                0x1b, 0x5b, 0x48       // ESC[H  home cursor
            ]
            terminalView?.feed(byteArray: seq[...])
        }

        // MARK: - TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            lastReportedCols = newCols
            lastReportedRows = newRows
            Task { @MainActor [weak self] in
                self?.appState?.terminalViewDidResize(cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            var bytes = Array(data)
            bytes = normalizeC1IntroducersTo7BitIfNeeded(bytes)

            // CPR 应答（ESC[row;colR）不再丢弃：
            // C1→7-bit 规范化已修复 zle 误解析问题（0x9b 被 shell 当垃圾字节），
            // 而 TUI 应用（如 helix/lazygit）依赖 CPR 获取光标位置，丢弃会导致功能异常。
            // xterm.js 时代同样经过网络往返但无此问题，佐证根因是 C1 编码而非延迟。

            if Thread.isMainThread {
                appState?.sendTerminalInputBytes(bytes)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.appState?.sendTerminalInputBytes(bytes)
                }
            }
        }

        func scrolled(source: TerminalView, position: Double) {
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // 第二阶段再接入链接打开能力
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            // 第二阶段再接入 OSC52 剪贴板能力
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        // MARK: - C1 规范化

        private func normalizeC1IntroducersTo7BitIfNeeded(_ bytes: [UInt8]) -> [UInt8] {
            // 关键兼容：有些 shell/程序不接受 8-bit C1 的 CSI(0x9b)，会把后续 "row;colR" 当普通输入，
            // 表现为输入行里出现 "3R;3RR;..." 并被当作命令执行。
            //
            // 只在“消息开头是 C1 引导符”时做转换，避免误伤 UTF-8 多字节字符（其内部可能出现 0x9b 等续字节）。
            guard let first = bytes.first else { return bytes }

            switch first {
            case 0x9b: // CSI
                return [0x1b, 0x5b] + bytes.dropFirst()
            case 0x9d: // OSC
                return [0x1b, 0x5d] + bytes.dropFirst()
            case 0x90: // DCS
                return [0x1b, 0x50] + bytes.dropFirst()
            case 0x9c: // ST
                return [0x1b, 0x5c] + bytes.dropFirst()
            default:
                return bytes
            }
        }

    }
}
#endif
