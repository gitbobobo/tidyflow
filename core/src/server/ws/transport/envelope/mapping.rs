pub(in crate::server::ws) fn domain_from_action(action: &str) -> String {
    if action.starts_with("term_")
        || action == "output_batch"
        || action == "exit"
        || action == "terminal_spawned"
        || action == "terminal_killed"
        || action == "remote_term_changed"
    {
        return "terminal".to_string();
    }
    if action.starts_with("file_") || action.starts_with("watch_") {
        return "file".to_string();
    }
    if action.starts_with("git_") {
        return "git".to_string();
    }
    if action.starts_with("project_")
        || action.starts_with("workspace_")
        || action == "projects"
        || action == "workspaces"
        || action == "templates"
        || action.starts_with("tasks_")
        || action.starts_with("template_")
    {
        return "project".to_string();
    }
    if action.starts_with("client_settings") {
        return "settings".to_string();
    }
    if action.starts_with("ai_") {
        return "ai".to_string();
    }
    if action.starts_with("evidence_") {
        return "evidence".to_string();
    }
    if action.starts_with("evo_") {
        return "evolution".to_string();
    }
    if action == "pong" || action == "hello" {
        return "system".to_string();
    }
    // v1.41: 系统健康诊断域
    if action.starts_with("health_") {
        return "health".to_string();
    }
    // v1.46: Coordinator 域（工作区级 AI 聚合状态快照）
    if action == "coordinator_snapshot" {
        return "coordinator".to_string();
    }
    "misc".to_string()
}

/// 判断 action 是否为服务端主动推送的事件（`kind = "event"`）。
///
/// 用于包络层自动设置 `kind` 字段；新增流式事件 action 时，必须同步在此注册。
/// 多工作区约束：所有流式事件 action 对应的 payload **必须**携带 `project`/`workspace` 字段，
/// 客户端通过这两个字段将事件路由到正确的缓存桶，不允许依赖全局单例工作区状态。
pub(in crate::server::ws) fn is_event_action(action: &str) -> bool {
    // 终端 / 文件 / Git 事件
    action == "output_batch"
        || action == "exit"
        || action == "file_changed"
        || action == "git_status_changed"
        || action == "remote_term_changed"
        // 项目 / 工作区 / 任务事件
        || action == "projects"
        || action == "workspaces"
        || action == "client_settings_result"
        || action == "tasks_snapshot"
        || action == "project_command_output"
        // AI 流式推送事件（多工作区键：project + workspace + session_id）
        || action == "ai_session_status_update"
        || action == "ai_session_subscribe_ack"
        || action == "ai_session_started"
        || action == "ai_question_asked"
        || action == "ai_question_cleared"
        || action == "ai_chat_done"
        || action == "ai_chat_pending"
        || action == "ai_chat_error"
        || action == "ai_session_messages_update"
        // Evolution 流式推送事件（多工作区键：project + workspace + cycle_id）
        || action.starts_with("evo_")
        // 系统健康推送事件（v1.41）
        || action == "health_snapshot"
        || action == "health_repair_result"
        // Coordinator 状态快照事件（v1.46：工作区级实时 AI 展示状态聚合）
        || action == "coordinator_snapshot"
}
