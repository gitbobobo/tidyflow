import SwiftUI
import Textual

/// 聊天消息 Markdown 渲染器：使用 Textual 的 StructuredText 做文档级渲染。
struct MarkdownTextView: View {
    let text: String
    var baseFontSize: CGFloat = 13
    var textColor: Color = .primary

    var body: some View {
        StructuredText(markdown: text)
            .font(.system(size: baseFontSize))
            .foregroundStyle(textColor)
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
