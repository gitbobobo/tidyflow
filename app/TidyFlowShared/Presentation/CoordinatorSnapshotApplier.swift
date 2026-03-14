// CoordinatorSnapshotApplier.swift
// TidyFlowShared
//
// 共享的 Coordinator 快照应用入口：统一双端 `payload -> state -> apply` 合并逻辑。
// 复用 `CoordinatorStateCache` 的变更判定，避免双端各自手写合并规则。

import Foundation

// MARK: - CoordinatorSnapshotApplier

/// 共享的 Coordinator 快照应用器。
/// 把 `CoordinatorWorkspaceSnapshotPayload` 应用到 `CoordinatorStateCache`，
/// 返回统一的变更判定结果，供平台层决定是否发布 UI 更新。
public enum CoordinatorSnapshotApplier {

    /// 将 Coordinator 快照 payload 应用到缓存，返回变更结果。
    /// - Parameters:
    ///   - payload: 来自 WebSocket 的 Coordinator 工作区快照。
    ///   - cache: 共享的 Coordinator 状态缓存。
    /// - Returns: 包含 `changed` 标记的变更结果，平台层据此决定是否触发发布。
    @discardableResult
    public static func apply(
        payload: CoordinatorWorkspaceSnapshotPayload,
        cache: CoordinatorStateCache
    ) -> CoordinatorStateChangeResult {
        let id = payload.workspaceId
        let existing = cache.state(for: id)
        let updated = payload.toWorkspaceCoordinatorState(existing: existing)
        return cache.apply(.updateWorkspace(updated))
    }
}
