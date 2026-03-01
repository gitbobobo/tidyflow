#if os(macOS)
import SwiftUI

/// 水平方向的可拖拽分割线，用于上下面板布局
struct VerticalSplitDivider: View {
    /// 拖拽偏移回调（正值向下，负值向上）
    var onDrag: (CGFloat) -> Void
    /// 双击回调（可用于折叠/展开）
    var onDoubleTap: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isDragging = false

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
            isHovered = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    isDragging = true
                    onDrag(value.translation.height)
                }
                .onEnded { _ in
                    isDragging = false
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
