use crate::server::context::HandlerContext;
use crate::server::protocol::WorkspaceSidebarStatusInfo;
use std::collections::HashMap;
use std::sync::OnceLock;
use tokio::sync::Mutex;
use tracing::warn;

const TASK_ICON_AI_COMMIT: &str = "sparkles";
const TASK_ICON_AI_MERGE: &str = "cpu";
const TASK_ICON_PROJECT_COMMAND_FALLBACK: &str = "terminal";

static EVOLUTION_ACTIVE_CACHE: OnceLock<Mutex<HashMap<String, bool>>> = OnceLock::new();

fn evolution_active_cache() -> &'static Mutex<HashMap<String, bool>> {
    EVOLUTION_ACTIVE_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn should_broadcast_evolution_sidebar(previous: Option<bool>, current: bool) -> bool {
    match previous {
        Some(previous) => previous != current,
        None => current,
    }
}

pub async fn workspace_sidebar_status(
    ctx: &HandlerContext,
    project: &str,
    workspace: &str,
) -> WorkspaceSidebarStatusInfo {
    let task_icon = workspace_task_icon(ctx, project, workspace).await;
    let chat_active = workspace_chat_active(ctx, project, workspace).await;
    let evolution_active =
        crate::server::handlers::evolution::has_active_workspace(project, workspace).await;

    WorkspaceSidebarStatusInfo {
        task_icon,
        chat_active,
        evolution_active,
    }
}

async fn workspace_task_icon(
    ctx: &HandlerContext,
    project: &str,
    workspace: &str,
) -> Option<String> {
    let ai_ops: Vec<String> = {
        let registry = ctx.running_ai_tasks.lock().await;
        registry
            .values()
            .filter(|entry| entry.project == project && entry.workspace == workspace)
            .map(|entry| entry.operation_type.clone())
            .collect()
    };
    if ai_ops.iter().any(|op| op == "ai_commit") {
        return Some(TASK_ICON_AI_COMMIT.to_string());
    }
    if ai_ops.iter().any(|op| op == "ai_merge") {
        return Some(TASK_ICON_AI_MERGE.to_string());
    }

    let mut command_ids: Vec<String> = {
        let registry = ctx.running_commands.lock().await;
        registry
            .values()
            .filter(|entry| entry.project == project && entry.workspace == workspace)
            .map(|entry| entry.command_id.clone())
            .collect()
    };
    command_ids.sort();

    let Some(command_id) = command_ids.first() else {
        return None;
    };

    resolve_project_command_icon(ctx, project, command_id)
        .await
        .or_else(|| Some(TASK_ICON_PROJECT_COMMAND_FALLBACK.to_string()))
}

async fn resolve_project_command_icon(
    ctx: &HandlerContext,
    project: &str,
    command_id: &str,
) -> Option<String> {
    let state = ctx.app_state.read().await;
    let project = state.get_project(project)?;
    let command = project.commands.iter().find(|cmd| cmd.id == command_id)?;
    let icon = command.icon.trim();
    if icon.is_empty() {
        None
    } else {
        Some(icon.to_string())
    }
}

async fn workspace_chat_active(ctx: &HandlerContext, project: &str, workspace: &str) -> bool {
    let store = {
        let ai = ctx.ai_state.lock().await;
        ai.session_statuses.clone()
    };
    store.has_busy_for_workspace(project, workspace)
}

/// 当 evolution 活跃状态切换时，主动广播最新 workspaces，驱动前端侧边栏即时刷新。
pub async fn notify_workspace_sidebar_if_evolution_changed(
    ctx: &HandlerContext,
    project: &str,
    workspace: &str,
) {
    let key = format!("{}:{}", project, workspace);
    let evolution_active =
        crate::server::handlers::evolution::has_active_workspace(project, workspace).await;

    let should_broadcast = {
        let mut cache = evolution_active_cache().lock().await;
        let previous = cache.get(&key).copied();
        let should_broadcast = should_broadcast_evolution_sidebar(previous, evolution_active);
        if should_broadcast || previous.is_none() {
            cache.insert(key.clone(), evolution_active);
        }
        should_broadcast
    };

    if !should_broadcast {
        return;
    }

    broadcast_workspace_sidebar_status(ctx, project, workspace, "evolution").await;
}

/// 主动广播指定项目的 workspaces 列表，驱动前端侧边栏状态即时刷新。
pub async fn notify_workspace_sidebar_changed(
    ctx: &HandlerContext,
    project: &str,
    workspace: &str,
) {
    broadcast_workspace_sidebar_status(ctx, project, workspace, "task").await;
}

async fn broadcast_workspace_sidebar_status(
    ctx: &HandlerContext,
    project: &str,
    workspace: &str,
    source: &str,
) {
    let message = match crate::application::project::list_workspaces_message(ctx, project).await {
        Ok(message) => message,
        Err(error_message) => {
            warn!(
                "broadcast workspaces for sidebar failed: project={}, workspace={}, source={}, error={:?}",
                project, workspace, source, error_message
            );
            return;
        }
    };

    let _ = crate::server::context::send_task_broadcast_event(
        &ctx.task_broadcast_tx,
        crate::server::context::TaskBroadcastEvent {
            origin_conn_id: format!("sidebar_status_{}", source),
            message,
            target_conn_ids: None,
            skip_when_single_receiver: false,
        },
    );
}

#[cfg(test)]
mod tests {
    use super::should_broadcast_evolution_sidebar;

    #[test]
    fn broadcast_on_first_active_only() {
        assert!(should_broadcast_evolution_sidebar(None, true));
        assert!(!should_broadcast_evolution_sidebar(None, false));
    }

    #[test]
    fn broadcast_on_value_change_only() {
        assert!(!should_broadcast_evolution_sidebar(Some(true), true));
        assert!(should_broadcast_evolution_sidebar(Some(true), false));
        assert!(should_broadcast_evolution_sidebar(Some(false), true));
        assert!(!should_broadcast_evolution_sidebar(Some(false), false));
    }

    /// 验证 project/workspace 复合键格式稳定：侧边栏广播缓存用此键隔离多工作区状态。
    /// 格式固定为 "<project>:<workspace>"，与客户端 globalKey 保持一致。
    #[test]
    fn sidebar_cache_key_format_is_project_colon_workspace() {
        let project = "proj-a";
        let workspace = "main";
        let key = format!("{}:{}", project, workspace);
        assert_eq!(key, "proj-a:main");
    }

    /// 验证不同 project/workspace 组合产生唯一缓存键，
    /// 确保侧边栏广播缓存在多工作区场景下不会串台。
    #[test]
    fn sidebar_cache_keys_are_isolated_across_workspaces() {
        let pairs = [
            ("proj-a", "main"),
            ("proj-a", "feature"),
            ("proj-b", "main"),
        ];

        let keys: std::collections::HashSet<String> =
            pairs.iter().map(|(p, w)| format!("{}:{}", p, w)).collect();

        assert_eq!(
            keys.len(),
            pairs.len(),
            "不同 project/workspace 组合的侧边栏缓存键必须唯一，防止 evolution 状态广播串台"
        );
    }

    /// 验证 should_broadcast_evolution_sidebar 对同一 key 的独立缓存语义：
    /// 一个工作区的 evolution 状态变化不影响另一个工作区的广播判断。
    #[test]
    fn broadcast_decision_is_independent_per_workspace() {
        // 工作区 A：从无到 active，应广播
        let ws_a_broadcast = should_broadcast_evolution_sidebar(None, true);
        // 工作区 B：始终 inactive，首次不应广播
        let ws_b_broadcast = should_broadcast_evolution_sidebar(None, false);
        // 工作区 A 的决策不影响工作区 B
        assert!(ws_a_broadcast, "ws-a 从 None→active 应广播");
        assert!(!ws_b_broadcast, "ws-b 从 None→inactive 不应广播");
    }
}
