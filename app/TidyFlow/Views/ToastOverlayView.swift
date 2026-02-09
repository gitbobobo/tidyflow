import SwiftUI

// MARK: - Toast 覆盖层

/// 右下角 Toast 通知覆盖层，不拦截下层交互
struct ToastOverlayView: View {
    @ObservedObject var toastManager: ToastManager

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer()
            ForEach(toastManager.toasts) { toast in
                ToastItemView(toast: toast) {
                    toastManager.dismiss(toast.id)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .padding(.bottom, 12)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(true) // Toast 本身可交互
    }
}

// MARK: - 单条 Toast 视图

struct ToastItemView: View {
    let toast: ToastNotification
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            // 状态图标
            Image(systemName: toast.resultStatus.iconName)
                .font(.system(size: 16))
                .foregroundColor(toast.resultStatus.iconColor)

            VStack(alignment: .leading, spacing: 2) {
                // 工作空间标识
                Text(toast.workspaceLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // 任务标题 + 状态
                HStack(spacing: 4) {
                    Image(systemName: toast.taskType.iconName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(toast.taskTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("—")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(toast.resultStatus.toastStatusText)
                        .font(.system(size: 12))
                        .foregroundColor(toast.resultStatus.iconColor)
                }
            }

            Spacer(minLength: 4)

            // 关闭按钮
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusBorderColor, lineWidth: 1)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }

    /// 左侧边框颜色根据状态变化
    private var statusBorderColor: Color {
        switch toast.resultStatus {
        case .success: return .green.opacity(0.3)
        case .failed: return .red.opacity(0.3)
        case .unknown: return .orange.opacity(0.3)
        }
    }
}

// MARK: - TaskResultStatus Toast 扩展

extension TaskResultStatus {
    /// Toast 中显示的状态文本
    var toastStatusText: String {
        switch self {
        case .success: return "toast.status.success".localized
        case .failed: return "toast.status.failed".localized
        case .unknown: return "toast.status.unknown".localized
        }
    }
}
