#if os(macOS)
import SwiftUI

/// 水平方向的可拖拽分割线，用于上下面板布局
struct VerticalSplitDivider: View {
    /// 是否允许拖拽调节（禁用时仅展示分割线，不响应拖拽/调整光标）
    var isResizable: Bool = true
    /// 拖拽偏移回调（正值向下，负值向上）
    var onDrag: (CGFloat) -> Void
    /// 拖拽结束回调
    var onDragEnd: (() -> Void)? = nil
    /// 双击回调（可用于折叠/展开）
    var onDoubleTap: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isDragging = false
    @State private var didPushResizeCursor = false

    /// 分割线热区高度
    private let hitAreaHeight: CGFloat = 8
    /// 可见线条高度
    private let lineHeight: CGFloat = 1

    var body: some View {
        ZStack {
            // 可见分割线
            Rectangle()
                .fill(isDragging || isHovered ? Color.accentColor : Color(NSColor.separatorColor))
                .frame(height: lineHeight)

            // 扩大热区
            Color.clear
                .frame(height: hitAreaHeight)
                .contentShape(Rectangle())
        }
        .frame(height: hitAreaHeight)
        .onHover { hovering in
            guard isResizable else {
                isHovered = false
                if didPushResizeCursor {
                    NSCursor.pop()
                    didPushResizeCursor = false
                }
                return
            }
            isHovered = hovering
            if hovering, !didPushResizeCursor {
                NSCursor.resizeUpDown.push()
                didPushResizeCursor = true
            } else if !hovering, didPushResizeCursor {
                NSCursor.pop()
                didPushResizeCursor = false
            }
        }
        .onChange(of: isResizable) { _, newValue in
            guard !newValue else { return }
            isHovered = false
            isDragging = false
            if didPushResizeCursor {
                NSCursor.pop()
                didPushResizeCursor = false
            }
        }
        .onDisappear {
            if didPushResizeCursor {
                NSCursor.pop()
                didPushResizeCursor = false
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard isResizable else { return }
                    isDragging = true
                    onDrag(value.translation.height)
                }
                .onEnded { _ in
                    guard isResizable else { return }
                    isDragging = false
                    onDragEnd?()
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onDoubleTap?()
            }
        )
    }
}
#endif
