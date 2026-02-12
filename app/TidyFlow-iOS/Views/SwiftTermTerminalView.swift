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

            // 远程终端场景下，CPR 应答（ESC[row;colR）经网络往返后到达 shell 时已超时，
            // zle 把 ESC[ 当作不完整按键序列消费，剩余 "3R"/"3RR" 被当命令执行。
            // 直接丢弃——CSI digits(;digits)* R 格式仅用于 CPR，不会误伤正常输入。
            if isCPRResponse(bytes) {
                return
            }

            if Thread.isMainThread {
                appState?.sendTerminalInputBytes(bytes)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.appState?.sendTerminalInputBytes(bytes)
                }
            }
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // 第二阶段再接入链接打开能力
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            // 第二阶段再接入 OSC52 剪贴板能力
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        // MARK: - CPR 抑制

        /// 检测 CSI digits(;digits)* R 格式的 CPR (Cursor Position Report) 应答。
        /// 该格式仅用于终端自动应答，不会出现在用户手动输入中。
        private func isCPRResponse(_ bytes: [UInt8]) -> Bool {
            guard !bytes.isEmpty else { return false }

            var i = 0

            // CSI 引导符（7-bit ESC[ 或 8-bit 0x9b）
            if bytes.count >= 2, bytes[0] == 0x1b, bytes[1] == 0x5b {
                i = 2
            } else if bytes[0] == 0x9b {
                i = 1
            } else {
                return false
            }

            // 可选 '?' 前缀（DEC-specific CPR: ESC[?row;col;pageR）
            if i < bytes.count, bytes[i] == 0x3f {
                i += 1
            }

            // 至少一组数字
            var sawDigit = false
            while i < bytes.count {
                let b = bytes[i]
                if b >= 0x30 && b <= 0x39 {
                    sawDigit = true
                    i += 1
                } else if b == 0x3b { // ';'
                    i += 1
                } else {
                    break
                }
            }
            guard sawDigit else { return false }

            // 末尾必须是 'R' 且无多余字节
            return i == bytes.count - 1 && bytes[i] == 0x52
        }

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
