#if os(macOS)
import SwiftTerm
import SwiftUI
import AppKit

protocol MacTerminalOutputSink: AnyObject {
    func writeOutput(_ bytes: [UInt8])
    func focusTerminal()
    func resetTerminal()
}

struct MacSwiftTermTerminalView: NSViewRepresentable {
    let appState: AppState
    let tabId: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState, tabId: tabId)
    }

    func makeNSView(context: Context) -> TerminalView {
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

        context.coordinator.bind(terminalView: terminalView)
        DispatchQueue.main.async {
            context.coordinator.reportCurrentSizeIfNeeded(from: terminalView)
            _ = terminalView.window?.makeFirstResponder(terminalView)
        }

        return terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.tabId = tabId
        context.coordinator.bind(terminalView: nsView)
        context.coordinator.reportCurrentSizeIfNeeded(from: nsView)
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.unbind(terminalView: nsView)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, MacTerminalOutputSink {
        private weak var appState: AppState?
        private weak var terminalView: TerminalView?
        var tabId: UUID
        private var lastReportedCols: Int = 0
        private var lastReportedRows: Int = 0

        init(appState: AppState, tabId: UUID) {
            self.appState = appState
            self.tabId = tabId
        }

        func bind(terminalView: TerminalView) {
            let shouldRebind = self.terminalView !== terminalView
            self.terminalView = terminalView
            guard shouldRebind else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState?.attachTerminalSink(self, tabId: self.tabId)
            }
        }

        func unbind(terminalView: TerminalView) {
            if self.terminalView === terminalView {
                self.terminalView = nil
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
