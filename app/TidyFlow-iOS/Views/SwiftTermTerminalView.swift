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
    let onKey: (String) -> Void
    let onCtrlArmedChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeUIView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator

        // SwiftTerm 的 TerminalView 在部分版本中是 UIScrollView 子类/或内部依赖滚动。
        // 禁用系统自动 inset 与交互式收起键盘，避免在滚动 scrollback 时出现“页面上下抖动”。
        terminalView.contentInsetAdjustmentBehavior = .never
        terminalView.keyboardDismissMode = .none
        terminalView.scrollsToTop = false
        // 终端滚动更像编辑器：关闭回弹可显著降低“拉到底部/顶部时”的抖动感
        terminalView.bounces = false
        terminalView.alwaysBounceVertical = false

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
        context.coordinator.reportCurrentSizeIfNeeded(from: uiView)
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.unbind(terminalView: uiView)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, MobileTerminalOutputSink {
        private weak var appState: MobileAppState?
        private weak var terminalView: TerminalView?
        private var contentOffsetObserver: NSKeyValueObservation?
        private var lastReportedCols: Int = 0
        private var lastReportedRows: Int = 0
        private var lastIsAtBottom: Bool?

        init(appState: MobileAppState) {
            self.appState = appState
        }

        func bind(terminalView: TerminalView) {
            let shouldRebind = self.terminalView !== terminalView
            self.terminalView = terminalView
            guard shouldRebind else { return }

            // 监听用户滚动位置：离开底部时暂停“自动跟随输出”，避免 TUI 持续刷新导致滚动抖动/被抢回底部。
            contentOffsetObserver?.invalidate()
            contentOffsetObserver = terminalView.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
                guard let self else { return }
                self.reportScrollStateIfNeeded(from: view)
            }
            reportScrollStateIfNeeded(from: terminalView)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState?.attachTerminalSink(self)
            }
        }

        func unbind(terminalView: TerminalView) {
            if self.terminalView === terminalView {
                self.terminalView = nil
            }

            contentOffsetObserver?.invalidate()
            contentOffsetObserver = nil

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

        private func reportScrollStateIfNeeded(from terminalView: TerminalView) {
            // SwiftTerm(iOS) 通过 UIScrollView 的 contentOffset 实现 scrollback：
            // 新输出会触发内部 updateScroller() 把 contentOffset 拉回底部，因此需要“用户离开底部即锁定输出”。
            let maxOffsetY = max(0, terminalView.contentSize.height - terminalView.bounds.height)
            let distanceToBottom = maxOffsetY - terminalView.contentOffset.y
            // 允许一点浮动，避免临界区频繁抖动
            let isAtBottom = maxOffsetY <= 0 || distanceToBottom <= 2
            // 只在状态变化时触发（减少主线程消息风暴）
            if let last = lastIsAtBottom, last == isAtBottom {
                // 仍需要在“用户交互结束”时让上层有机会解锁，所以继续往下走
            } else {
                lastIsAtBottom = isAtBottom
            }

            let isUserInteracting = terminalView.isTracking || terminalView.isDragging || terminalView.isDecelerating
            Task { @MainActor [weak self] in
                self?.appState?.terminalViewDidUpdateScrollState(
                    isAtBottom: isAtBottom,
                    isUserInteracting: isUserInteracting
                )
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
            // 兼容：macOS 版本的 SwiftTerm 会通过 yDisp -> scrollPosition 回调。
            // iOS 端真实滚动以 contentOffset 为准（已由 KVO 监听），这里作为兜底同步一次“是否在底部”。
            reportScrollStateIfNeeded(from: source)
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
