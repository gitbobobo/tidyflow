use crate::server::context::HandlerContext;
use crate::server::protocol::WorkspaceSidebarStatusInfo;

const TASK_ICON_AI_COMMIT: &str = "sparkles";
const TASK_ICON_AI_MERGE: &str = "cpu";
const TASK_ICON_PROJECT_COMMAND_FALLBACK: &str = "terminal";

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
