import SwiftUI
import TidyFlowShared

// MARK: - 跨端只读 Diff 行视图（macOS + iOS 共享语义）
// 此文件同时包含在 macOS 目标和 iOS 目标的编译源中，避免双端重复维护 Diff 行样式与语义。
// 调用方：
//   macOS — TabContentHostView.swift（NativeDiffContentView）
//   iOS   — WorkspaceDiffView.swift

/// 单行 Diff 渲染视图，复用 TidyFlowShared 的 DiffLine 模型。
/// `onNavigate` 仅在有导航目标（编辑器跳转等）时使用；iOS 只读场景传 nil 即可。
struct DiffLineRowView: View {
    let line: DiffLine
    var onNavigate: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(line.oldLineNumber.map { String($0) } ?? "")
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 11, design: .monospaced))
            Text(line.newLineNumber.map { String($0) } ?? "")
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 11, design: .monospaced))
            Text(linePrefix)
                .foregroundColor(prefixColor)
                .font(.system(size: 11, design: .monospaced))
            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(lineBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            if line.isNavigable, let onNavigate {
                onNavigate()
            }
        }
    }

    private var linePrefix: String {
        switch line.kind {
        case .add: return "+"
        case .del: return "-"
        case .context: return " "
        case .hunk: return "@@"
        case .header: return " "
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .add: return .green
        case .del: return .red
        case .hunk: return .blue
        default: return .secondary
        }
    }

    private var lineBackground: Color {
        switch line.kind {
        case .add: return Color.green.opacity(0.10)
        case .del: return Color.red.opacity(0.10)
        case .hunk: return Color.blue.opacity(0.08)
        default: return Color.clear
        }
    }
}
