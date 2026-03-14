// EvolutionControlSemantics.swift
// TidyFlowShared
//
// 跨平台 Evolution 控制语义：统一 start/stop/resume 能力推导与 pending 超时行为。
// 从 macOS AppState 迁出，双端共享同一套规则。

import Foundation

// MARK: - EvolutionControlAction

/// Evolution 控制操作类型。
public enum EvolutionControlAction: String, Equatable, Sendable {
    case start
    case stop
    case resume
}

// MARK: - EvolutionPendingActionState

/// 待确认的 Evolution 控制操作状态。
/// 在操作发出到服务端确认之间，阻塞其余控制操作（30 秒超时后自动失效）。
public struct EvolutionPendingActionState: Equatable, Sendable {
    public let action: EvolutionControlAction
    public let requestedAt: Date
    public let requestedLoopRoundLimit: Int?

    public init(
        action: EvolutionControlAction,
        requestedAt: Date = Date(),
        requestedLoopRoundLimit: Int? = nil
    ) {
        self.action = action
        self.requestedAt = requestedAt
        self.requestedLoopRoundLimit = requestedLoopRoundLimit
    }

    public func resolvedLoopRoundLimit(fallback: Int) -> Int {
        max(1, requestedLoopRoundLimit ?? fallback)
    }
}

// MARK: - EvolutionControlCapability

/// Evolution 控制能力快照：描述当前时刻可执行的操作与禁用原因。
public struct EvolutionControlCapability: Equatable, Sendable {
    public let canStart: Bool
    public let canStop: Bool
    public let canResume: Bool
    public let isStartPending: Bool
    public let isStopPending: Bool
    public let isResumePending: Bool
    public let startReason: String?
    public let stopReason: String?
    public let resumeReason: String?

    public init(
        canStart: Bool,
        canStop: Bool,
        canResume: Bool,
        isStartPending: Bool,
        isStopPending: Bool,
        isResumePending: Bool,
        startReason: String?,
        stopReason: String?,
        resumeReason: String?
    ) {
        self.canStart = canStart
        self.canStop = canStop
        self.canResume = canResume
        self.isStartPending = isStartPending
        self.isStopPending = isStopPending
        self.isResumePending = isResumePending
        self.startReason = startReason
        self.stopReason = stopReason
        self.resumeReason = resumeReason
    }

    /// 根据工作区就绪状态、当前 Evolution 状态和 pending 操作推导控制能力。
    public static func evaluate(
        workspaceReady: Bool,
        currentStatus: String?,
        pendingAction: EvolutionPendingActionState?
    ) -> EvolutionControlCapability {
        guard workspaceReady else {
            return EvolutionControlCapability(
                canStart: false,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: "请先选择工作空间",
                stopReason: "请先选择工作空间",
                resumeReason: "请先选择工作空间"
            )
        }

        // 待确认操作未过期时阻塞所有控制（超过 30 秒视为已超时，跌回正常状态求值）
        if let pendingAction, Date().timeIntervalSince(pendingAction.requestedAt) <= 30 {
            let pendingReason = "操作进行中，请稍候"
            return EvolutionControlCapability(
                canStart: false,
                canStop: false,
                canResume: false,
                isStartPending: pendingAction.action == .start,
                isStopPending: pendingAction.action == .stop,
                isResumePending: pendingAction.action == .resume,
                startReason: pendingReason,
                stopReason: pendingReason,
                resumeReason: pendingReason
            )
        }

        guard let status = normalizedStatus(currentStatus) else {
            return EvolutionControlCapability(
                canStart: true,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: nil,
                stopReason: "当前无可停止的循环",
                resumeReason: "当前状态不可恢复"
            )
        }

        switch status {
        case "queued", "running":
            return EvolutionControlCapability(
                canStart: false,
                canStop: true,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: "当前循环未结束，无法启动新一轮",
                stopReason: nil,
                resumeReason: "当前状态不可恢复"
            )
        case "interrupted", "stopped":
            return EvolutionControlCapability(
                canStart: false,
                canStop: false,
                canResume: true,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: "当前循环未结束，无法启动新一轮",
                stopReason: "当前无可停止的循环",
                resumeReason: nil
            )
        case "completed", "failed_exhausted", "failed_system":
            return EvolutionControlCapability(
                canStart: true,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: nil,
                stopReason: "当前无可停止的循环",
                resumeReason: "当前状态不可恢复"
            )
        default:
            return EvolutionControlCapability(
                canStart: false,
                canStop: false,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false,
                startReason: "当前状态不可启动",
                stopReason: "当前无可停止的循环",
                resumeReason: "当前状态不可恢复"
            )
        }
    }

    /// 判断是否应清除 pending 操作（超时或状态已收敛到目标）。
    public static func shouldClearPendingAction(
        _ pendingAction: EvolutionPendingActionState,
        currentStatus: String?
    ) -> Bool {
        if Date().timeIntervalSince(pendingAction.requestedAt) > 30 {
            return true
        }
        let normalized = normalizedStatus(currentStatus)
        switch pendingAction.action {
        case .start:
            return normalized != nil
        case .stop:
            guard let normalized else { return false }
            return [
                "interrupted",
                "stopped",
                "completed",
                "failed_exhausted",
                "failed_system",
            ].contains(normalized)
        case .resume:
            guard let normalized else { return false }
            return normalized == "queued" || normalized == "running"
        }
    }

    /// 状态字符串归一化：去空白、小写化，空串返回 nil。
    public static func normalizedStatus(_ status: String?) -> String? {
        guard let status else { return nil }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
