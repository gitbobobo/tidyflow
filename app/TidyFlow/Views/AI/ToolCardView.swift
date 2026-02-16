import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 工具调用卡片：展示工具名称与输入/输出（JSON）并支持展开与复制。
struct ToolCardView: View {
    let name: String
    let state: [String: Any]?

    /// 默认显示的输出尾行数
    private static let defaultTailLines = 3

    /// true = 展示完整输出；false = 仅显示输入 + 输出末尾 N 行
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundColor(.secondary)

                // 优先显示输入中的 description，否则显示工具名
                Text(inputDescription ?? name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                if let statusText = statusSummary {
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            // 始终显示输入：优先提取 command 字段直接展示
            if let input = state?["input"] {
                inputSection(value: input)
            }

            // 输出：默认显示末尾 N 行，展开后显示完整内容
            if let output = state?["output"] {
                outputSection(value: output)
            }

            if state?["input"] == nil, state?["output"] == nil, let state {
                section(title: "state", value: state)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    /// 从 input 中提取 description 字段用于头部展示
    private var inputDescription: String? {
        guard let input = state?["input"] as? [String: Any],
              let desc = input["description"] as? String, !desc.isEmpty,
              input["command"] != nil else { return nil }
        return desc
    }

    private var statusSummary: String? {
        // state 的结构可能变化，优先找常见字段
        if let status = state?["status"] as? String, !status.isEmpty {
            return status
        }
        if let type = state?["type"] as? String, !type.isEmpty {
            return type
        }
        return nil
    }

    @ViewBuilder
    private func section(title: String, value: Any) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button("复制") {
                    copyToClipboard(prettyJSONString(value) ?? String(describing: value))
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            }

            Text(prettyJSONString(value) ?? String(describing: value))
                .textSelection(.enabled)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }

    /// 输入区域：若含 command 字段则直接展示命令文本，否则回退为 JSON
    @ViewBuilder
    private func inputSection(value: Any) -> some View {
        let dict = value as? [String: Any]
        let command = dict?["command"] as? String
        let displayText = command ?? prettyJSONString(value) ?? String(describing: value)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("input")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button("复制") {
                    copyToClipboard(displayText)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            }

            Text(displayText)
                .textSelection(.enabled)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }

    /// 输出区域：标题栏含复制 + 展开/折叠文字按钮
    @ViewBuilder
    private func outputSection(value: Any) -> some View {
        let fullText = prettyJSONString(value) ?? String(describing: value)
        let lines = fullText.components(separatedBy: "\n")
        let needsTruncation = lines.count > Self.defaultTailLines
        let tailText = lines.suffix(Self.defaultTailLines).joined(separator: "\n")

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("output")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                if needsTruncation {
                    Button(isExpanded ? "折叠" : "展开") {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                }
                Button("复制") {
                    copyToClipboard(fullText)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            }

            if isExpanded {
                Text(fullText)
                    .textSelection(.enabled)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if needsTruncation {
                    Text("…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                Text(needsTruncation ? tailText : fullText)
                    .textSelection(.enabled)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    private func prettyJSONString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
