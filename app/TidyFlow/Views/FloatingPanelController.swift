import SwiftUI
import AppKit

// MARK: - 不获焦浮动面板（用于显示提交详情）

/// 带鼠标追踪的内容视图，用于检测鼠标进出面板
private class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }
    
    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

/// 使用 NSPanel + nonactivatingPanel 实现的浮动面板，不会抢占焦点
final class FloatingPanelController: NSPanel {
    private var hostingView: TrackingHostingView<AnyView>?
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        
        // 面板配置：浮动、透明背景
        self.isFloatingPanel = true
        self.level = .floating
        // 允许在需要时成为 key（如文字选择），但不会主动抢焦点
        self.becomesKeyOnlyIfNeeded = true
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false // 使用 SwiftUI 阴影
        
        // 继承系统外观（支持暗色模式）
        self.appearance = nil
    }
    
    /// 显示时同步主窗口的外观设置
    func syncAppearance(with window: NSWindow) {
        self.appearance = window.effectiveAppearance
    }
    
    /// 允许成为 key 以支持文字选择，但通过 becomesKeyOnlyIfNeeded 限制只在需要时激活
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    
    /// 更新内容并调整大小
    func updateContent(_ content: AnyView) {
        if hostingView == nil {
            let hosting = TrackingHostingView(rootView: content)
            hosting.onMouseEntered = { [weak self] in self?.onMouseEntered?() }
            hosting.onMouseExited = { [weak self] in self?.onMouseExited?() }
            self.contentView = hosting
            self.hostingView = hosting
        } else {
            hostingView?.rootView = content
        }
        // 自适应大小
        if let hosting = hostingView {
            let size = hosting.fittingSize
            self.setContentSize(size)
        }
    }
    
    /// 显示在指定窗口坐标左侧（windowPoint 是窗口坐标系下的点）
    func showNear(windowPoint: NSPoint, in window: NSWindow) {
        guard let hosting = hostingView else { return }
        
        // 同步外观（支持暗色模式）
        syncAppearance(with: window)
        
        let size = hosting.fittingSize
        self.setContentSize(size)
        
        // 将窗口坐标转换为屏幕坐标
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        // 显示在行的左侧，垂直居中
        let origin = NSPoint(x: screenPoint.x - size.width - 8, y: screenPoint.y - size.height / 2)
        self.setFrameOrigin(origin)
        self.orderFront(nil)
    }
    
    func hidePanel() {
        self.orderOut(nil)
    }
}

/// 全局单例管理提交详情浮动面板
final class CommitDetailPanelManager {
    static let shared = CommitDetailPanelManager()
    
    private var panel: FloatingPanelController?
    /// 鼠标是否在面板内
    private(set) var isMouseInPanel: Bool = false
    /// 隐藏的延迟任务
    private var hideWorkItem: DispatchWorkItem?
    /// 当前显示的 entry id
    private(set) var currentEntryId: String?
    
    /// 面板是否正在显示
    var isVisible: Bool {
        panel?.isVisible == true
    }
    
    private init() {}
    
    func show(entry: GitLogEntry, windowPoint: NSPoint, in window: NSWindow) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        currentEntryId = entry.id
        
        let content = AnyView(
            CommitDetailPanelContent(entry: entry)
        )
        
        if panel == nil {
            panel = FloatingPanelController()
            panel?.onMouseEntered = { [weak self] in
                self?.isMouseInPanel = true
                self?.hideWorkItem?.cancel()
                self?.hideWorkItem = nil
            }
            panel?.onMouseExited = { [weak self] in
                self?.isMouseInPanel = false
                self?.scheduleHide()
            }
        }
        panel?.updateContent(content)
        panel?.showNear(windowPoint: windowPoint, in: window)
    }
    
    /// 请求隐藏（会延迟，给用户时间移入面板）
    func requestHide(entryId: String) {
        // 只处理当前显示的 entry
        guard entryId == currentEntryId else { return }
        scheduleHide()
    }
    
    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isMouseInPanel else { return }
            self.panel?.hidePanel()
            self.currentEntryId = nil
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    
    func forceHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.hidePanel()
        currentEntryId = nil
        isMouseInPanel = false
    }
}

/// 浮动面板内的提交详情内容
struct CommitDetailPanelContent: View {
    let entry: GitLogEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：SHA + 引用标签
            HStack(spacing: 8) {
                // SHA（可复制）
                Text(String(entry.sha.prefix(8)))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .textSelection(.enabled)
                
                // 引用标签
                if !entry.refs.isEmpty {
                    ForEach(entry.refs, id: \.self) { ref in
                        Text(ref)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(refColor(for: ref))
                            .cornerRadius(4)
                    }
                }
                
                Spacer()
            }
            .padding(.bottom, 10)
            
            // 提交消息（支持多行，可选择）
            Text(entry.message)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.bottom, 12)
            
            // 分隔线
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(height: 1)
                .padding(.bottom, 10)
            
            // 作者和时间
            HStack(spacing: 12) {
                // 作者
                HStack(spacing: 4) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(entry.author)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
                
                // 时间
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(entry.relativeDate)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // 完整 SHA（可复制）
            HStack(spacing: 4) {
                Image(systemName: "number")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(entry.sha)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.top, 6)
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
        .shadow(color: Color(NSColor.shadowColor).opacity(0.3), radius: 16, x: 0, y: 8)
    }
    
    /// 根据引用类型返回不同颜色
    private func refColor(for ref: String) -> Color {
        if ref.contains("HEAD") {
            return .accentColor
        } else if ref.hasPrefix("tag:") {
            return .orange
        } else if ref.contains("origin/") {
            return .purple
        } else {
            return .green
        }
    }
}
