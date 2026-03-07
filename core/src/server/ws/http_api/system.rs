use std::collections::HashMap;

use axum::{extract::State, Json};
use serde::Serialize;

use super::common::{build_http_handler_context, map_query_error, ApiError};
use crate::server::context::SharedAppState;
use crate::server::protocol::{ServerMessage, WorkspaceInfo, PROTOCOL_VERSION};

#[derive(Debug, Clone, Serialize)]
pub(in crate::server::ws) struct SystemSnapshotResponse {
    #[serde(rename = "type")]
    msg_type: &'static str,
    core_version: String,
    protocol_version: u32,
    workspace_items: Vec<SystemSnapshotWorkspaceItem>,
}

#[derive(Debug, Clone, Serialize)]
pub(in crate::server::ws) struct SystemSnapshotWorkspaceItem {
    project: String,
    workspace: String,
    path: String,
    branch: String,
    workspace_status: String,
    evolution_status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    evolution_cycle_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    failure_reason: Option<String>,
}

#[derive(Debug, Clone)]
struct EvolutionWorkspaceSummary {
    status: String,
    cycle_id: Option<String>,
    title: Option<String>,
    failure_reason: Option<String>,
}

pub(in crate::server::ws) async fn system_snapshot_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
) -> Result<Json<SystemSnapshotResponse>, ApiError> {
    let handler_ctx = build_http_handler_context(&ctx);
    let evo_snapshot =
        crate::server::handlers::evolution::query_evolution_snapshot(None, None, &handler_ctx)
            .await
            .map_err(map_query_error)?;
    let evo_index = evolution_index_from_message(evo_snapshot)?;
    let workspace_items = build_workspace_items(&ctx.app_state, &evo_index).await;

    Ok(Json(SystemSnapshotResponse {
        msg_type: "system_snapshot",
        core_version: env!("CARGO_PKG_VERSION").to_string(),
        protocol_version: PROTOCOL_VERSION,
        workspace_items,
    }))
}

fn evolution_index_from_message(
    msg: ServerMessage,
) -> Result<HashMap<(String, String), EvolutionWorkspaceSummary>, ApiError> {
    let ServerMessage::EvoSnapshot {
        scheduler: _,
        workspace_items,
    } = msg
    else {
        return Err(ApiError::Internal(
            "unexpected evolution snapshot response type".to_string(),
        ));
    };
    Ok(evolution_index_from_items(&workspace_items))
}

fn evolution_index_from_items(
    items: &[crate::server::protocol::EvolutionWorkspaceItem],
) -> HashMap<(String, String), EvolutionWorkspaceSummary> {
    let mut index = HashMap::with_capacity(items.len());
    for item in items {
        let cycle_id = non_empty_opt(Some(item.cycle_id.as_str()));
        let title = if cycle_id.is_some() {
            non_empty_opt(item.title.as_deref())
        } else {
            None
        };
        index.insert(
            (item.project.clone(), item.workspace.clone()),
            EvolutionWorkspaceSummary {
                status: non_empty_opt(Some(item.status.as_str()))
                    .unwrap_or_else(|| "not_started".to_string()),
                cycle_id,
                title,
                failure_reason: summarize_failure_reason(item),
            },
        );
    }
    index
}

async fn build_workspace_items(
    app_state: &SharedAppState,
    evo_index: &HashMap<(String, String), EvolutionWorkspaceSummary>,
) -> Vec<SystemSnapshotWorkspaceItem> {
    let mut items = Vec::new();

    {
        let state = app_state.read().await;
        for project in state.projects.values() {
            let project_name = project.name.clone();
            let default_info = WorkspaceInfo {
                name: "default".to_string(),
                root: project.root_path.to_string_lossy().to_string(),
                branch: project.default_branch.clone(),
                status: "ready".to_string(),
                sidebar_status: Default::default(),
            };
            items.push(build_workspace_item(
                project_name.clone(),
                default_info,
                evo_index,
            ));

            let mut workspaces = project.workspaces.values().collect::<Vec<_>>();
            workspaces.sort_by(|a, b| a.name.cmp(&b.name));
            for ws in workspaces {
                let info = WorkspaceInfo {
                    name: ws.name.clone(),
                    root: ws.worktree_path.to_string_lossy().to_string(),
                    branch: ws.branch.clone(),
                    status: crate::application::project::workspace_status_str(&ws.status),
                    sidebar_status: Default::default(),
                };
                items.push(build_workspace_item(project_name.clone(), info, evo_index));
            }
        }
    }

    items.sort_by(|a, b| {
        (a.project.clone(), a.workspace.clone()).cmp(&(b.project.clone(), b.workspace.clone()))
    });
    items
}

fn build_workspace_item(
    project: String,
    workspace: WorkspaceInfo,
    evo_index: &HashMap<(String, String), EvolutionWorkspaceSummary>,
) -> SystemSnapshotWorkspaceItem {
    let evo = evo_index.get(&(project.clone(), workspace.name.clone()));
    let evolution_status = evo
        .map(|v| v.status.clone())
        .unwrap_or_else(|| "not_started".to_string());
    let evolution_cycle_id = evo.and_then(|v| v.cycle_id.clone());
    let title = evo.and_then(|v| v.title.clone());
    let failure_reason = evo.and_then(|v| v.failure_reason.clone());

    SystemSnapshotWorkspaceItem {
        project,
        workspace: workspace.name,
        path: workspace.root,
        branch: workspace.branch,
        workspace_status: workspace.status,
        evolution_status,
        evolution_cycle_id,
        title,
        failure_reason,
    }
}

fn summarize_failure_reason(
    item: &crate::server::protocol::EvolutionWorkspaceItem,
) -> Option<String> {
    non_empty_opt(item.terminal_error_message.as_deref())
        .or_else(|| non_empty_opt(item.rate_limit_error_message.as_deref()))
        .or_else(|| non_empty_opt(item.terminal_reason_code.as_deref()))
}

fn non_empty_opt(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(|v| v.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::extract::State;
    use chrono::Utc;
    use std::sync::Arc;

    use crate::server::handlers::ai::AIState;
    use crate::server::remote_sub_registry::RemoteSubRegistry;
    use crate::server::terminal_registry::TerminalRegistry;
    use crate::workspace::state::{AppState, Project, Workspace, WorkspaceStatus};

    fn test_item(
        cycle_id: &str,
        title: Option<&str>,
        terminal_reason_code: Option<&str>,
        terminal_error_message: Option<&str>,
        rate_limit_error_message: Option<&str>,
    ) -> crate::server::protocol::EvolutionWorkspaceItem {
        crate::server::protocol::EvolutionWorkspaceItem {
            project: "demo".to_string(),
            workspace: "default".to_string(),
            cycle_id: cycle_id.to_string(),
            title: title.map(|v| v.to_string()),
            status: "running".to_string(),
            current_stage: "direction".to_string(),
            global_loop_round: 1,
            loop_round_limit: 3,
            verify_iteration: 0,
            verify_iteration_limit: 2,
            agents: Vec::new(),
            executions: Vec::new(),
            handoff: None,
            terminal_reason_code: terminal_reason_code.map(|v| v.to_string()),
            terminal_error_message: terminal_error_message.map(|v| v.to_string()),
            rate_limit_error_message: rate_limit_error_message.map(|v| v.to_string()),
        }
    }

    fn make_test_state() -> AppState {
        let mut state = AppState::default();
        state.add_project(Project {
            name: "demo".to_string(),
            root_path: "/tmp/demo".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: Utc::now(),
            workspaces: HashMap::from([(
                "alpha".to_string(),
                Workspace {
                    name: "alpha".to_string(),
                    worktree_path: "/tmp/demo/.worktrees/alpha".into(),
                    branch: "tidy/alpha".to_string(),
                    status: WorkspaceStatus::Ready,
                    created_at: Utc::now(),
                    last_accessed: Utc::now(),
                    setup_result: None,
                },
            )]),
            commands: Vec::new(),
        });
        state
    }

    async fn make_test_context(
        app_state: AppState,
    ) -> crate::server::ws::transport::bootstrap::AppContext {
        let shared_state: crate::server::context::SharedAppState =
            Arc::new(tokio::sync::RwLock::new(app_state));
        let (save_tx, _save_rx) = tokio::sync::mpsc::channel(8);
        let (scrollback_tx, _scrollback_rx) = tokio::sync::mpsc::channel(8);
        let (task_broadcast_tx, _task_broadcast_rx) = tokio::sync::broadcast::channel(8);
        crate::server::ws::transport::bootstrap::AppContext {
            app_state: shared_state,
            save_tx,
            terminal_registry: Arc::new(tokio::sync::Mutex::new(TerminalRegistry::new())),
            scrollback_tx,
            expected_ws_token: Some("required-token".to_string()),
            pairing_registry: Arc::new(tokio::sync::Mutex::new(
                crate::server::ws::pairing::new_pairing_registry(&[]),
            )),
            remote_sub_registry: Arc::new(tokio::sync::Mutex::new(RemoteSubRegistry::new())),
            task_broadcast_tx,
            running_commands: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            running_ai_tasks: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            task_history: Arc::new(tokio::sync::Mutex::new(Vec::new())),
            ai_state: Arc::new(tokio::sync::Mutex::new(AIState::new())),
        }
    }

    #[test]
    fn failure_reason_priority_should_be_terminal_then_rate_limit_then_code() {
        let a = test_item(
            "c1",
            Some("标题"),
            Some("reason_code"),
            Some("terminal_error"),
            Some("rate_limit"),
        );
        assert_eq!(
            summarize_failure_reason(&a),
            Some("terminal_error".to_string())
        );

        let b = test_item(
            "c1",
            Some("标题"),
            Some("reason_code"),
            None,
            Some("rate_limit"),
        );
        assert_eq!(summarize_failure_reason(&b), Some("rate_limit".to_string()));

        let c = test_item("c1", Some("标题"), Some("reason_code"), None, None);
        assert_eq!(
            summarize_failure_reason(&c),
            Some("reason_code".to_string())
        );
    }

    #[test]
    fn title_should_be_none_when_cycle_id_exists_but_title_missing() {
        let items = vec![test_item("cycle-1", None, None, None, None)];
        let idx = evolution_index_from_items(&items);
        let summary = idx
            .get(&("demo".to_string(), "default".to_string()))
            .expect("summary should exist");
        assert_eq!(summary.cycle_id.as_deref(), Some("cycle-1"));
        assert_eq!(summary.title, None);
    }

    #[tokio::test]
    async fn title_should_be_propagated_when_present() {
        let items = vec![test_item("cycle-2", Some("本轮标题"), None, None, None)];
        let idx = evolution_index_from_items(&items);
        let result =
            build_workspace_items(&Arc::new(tokio::sync::RwLock::new(make_test_state())), &idx)
                .await;
        let default_item = result
            .iter()
            .find(|it| it.project == "demo" && it.workspace == "default")
            .expect("default workspace should exist");
        assert_eq!(default_item.evolution_cycle_id.as_deref(), Some("cycle-2"));
        assert_eq!(default_item.title.as_deref(), Some("本轮标题"));
    }

    #[tokio::test]
    async fn workspace_items_should_include_default_and_not_started_when_no_evolution() {
        let state = make_test_state();
        let items =
            build_workspace_items(&Arc::new(tokio::sync::RwLock::new(state)), &HashMap::new())
                .await;
        let default_item = items
            .iter()
            .find(|it| it.project == "demo" && it.workspace == "default")
            .expect("default workspace should exist");
        assert_eq!(default_item.evolution_status, "not_started");
        assert_eq!(default_item.evolution_cycle_id, None);
        assert_eq!(default_item.title, None);
    }

    #[tokio::test]
    async fn workspace_items_should_be_sorted_by_project_and_workspace() {
        let mut state = AppState::default();
        state.add_project(Project {
            name: "zeta".to_string(),
            root_path: "/tmp/zeta".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: Utc::now(),
            workspaces: HashMap::new(),
            commands: Vec::new(),
        });
        state.add_project(Project {
            name: "alpha".to_string(),
            root_path: "/tmp/alpha".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: Utc::now(),
            workspaces: HashMap::new(),
            commands: Vec::new(),
        });
        let items =
            build_workspace_items(&Arc::new(tokio::sync::RwLock::new(state)), &HashMap::new())
                .await;
        let keys = items
            .into_iter()
            .map(|it| format!("{}/{}", it.project, it.workspace))
            .collect::<Vec<_>>();
        assert_eq!(
            keys,
            vec!["alpha/default".to_string(), "zeta/default".to_string()]
        );
    }

    #[tokio::test]
    async fn system_snapshot_should_allow_request_without_token() {
        let ctx = make_test_context(make_test_state()).await;
        let response = system_snapshot_handler(State(ctx))
            .await
            .expect("handler should return response")
            .0;

        assert_eq!(response.msg_type, "system_snapshot");
    }
}
