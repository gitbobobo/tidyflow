import CoreGraphics

enum AIChatComposerLayoutSemantics {
    /// 消息列表底部为浮层输入区预留的额外空白，避免最后一条消息紧贴输入卡片。
    static let messageBottomClearance: CGFloat = 24

    /// “回到底部”按钮相对输入浮层顶部的额外安全间距，避免视觉上贴边或被遮挡。
    static let jumpToBottomClearance: CGFloat = 24
}
