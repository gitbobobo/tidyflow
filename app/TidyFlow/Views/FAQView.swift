import SwiftUI

// MARK: - 数据模型

/// FAQ 内容块
enum FAQBlock {
    /// 普通文字段落
    case text(String)
    /// 可复制的命令
    case command(String)
}

/// FAQ 条目
struct FAQItem: Identifiable {
    let id = UUID()
    let titleKey: String
    let blocks: [FAQBlock]
}

/// FAQ 静态数据源
enum FAQData {
    static let items: [FAQItem] = []
}

// MARK: - 可复制命令行视图

/// 带复制按钮的命令块
struct CopyableCommandView: View {
    let command: String

    var body: some View {
        Text(command)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.black.opacity(0.25))
        .cornerRadius(6)
    }
}

// MARK: - FAQ 视图

/// 可点击整行展开/折叠的 FAQ 条目视图
struct FAQItemView: View {
    let item: FAQItem
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行：整行可点击
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(item.titleKey.localized)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(
                        Array(item.blocks.enumerated()),
                        id: \.offset
                    ) { _, block in
                        switch block {
                        case .text(let key):
                            Text(key.localized)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        case .command(let cmd):
                            CopyableCommandView(command: cmd)
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
    }
}

struct FAQView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(FAQData.items) { item in
                    FAQItemView(item: item)
                }
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

// MARK: - 帮助菜单命令

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("help.faq".localized) {
                openWindow(id: "faq")
            }
        }
    }
}
