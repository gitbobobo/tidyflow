use tokio::sync::Mutex;

use crate::server::watcher::WorkspaceWatcher;

pub(in crate::server::ws::dispatch) type DispatchWatcher = std::sync::Arc<Mutex<WorkspaceWatcher>>;

// ============================================================================
// 多工作区流式事件隔离约束（v7）
//
// 以下约束适用于所有通过 WS dispatch 路由的流式事件，与 HTTP snapshot 结果共享
// 同一套 (project, workspace) 边界语义。
//
// 1. 所有流式事件 payload **必须**携带 `project` 和 `workspace` 字段作为归属键。
//    - AI 相关事件额外携带 `session_id`（条件必须）。
//    - Evolution 相关事件额外携带 `cycle_id`（条件必须）。
//
// 2. Dispatch 层不感知当前激活工作区；路由决策仅依据 domain/action，
//    不允许在 dispatch 层用全局单例工作区过滤事件。
//
// 3. 客户端（macOS / iOS）负责在应用层通过 (project, workspace) 二元组
//    将事件路由到正确的缓存桶，不得让来自其他工作区的事件覆盖当前激活状态。
//
// 4. 对于需要按工作区过滤的增量消息（如 evo_workspace_status、ai_session_messages_update），
//    Core 在推送时已通过 conn_id → 订阅关系筛选目标连接；
//    客户端仍应额外校验 project/workspace，防止重播/并发订阅时的串台。
// ============================================================================
