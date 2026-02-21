pub(in crate::server::ws) fn domain_from_action(action: &str) -> String {
    if action.starts_with("term_")
        || action == "output"
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
        || action.starts_with("tasks_")
    {
        return "project".to_string();
    }
    if action.starts_with("lsp_") {
        return "lsp".to_string();
    }
    if action.starts_with("client_settings") {
        return "settings".to_string();
    }
    if action.starts_with("ai_") {
        return "ai".to_string();
    }
    if action.starts_with("evo_") {
        return "evolution".to_string();
    }
    if action == "pong" || action == "hello" {
        return "system".to_string();
    }
    "misc".to_string()
}

pub(in crate::server::ws) fn is_event_action(action: &str) -> bool {
    action == "output"
        || action == "exit"
        || action == "file_changed"
        || action == "git_status_changed"
        || action == "remote_term_changed"
        || action == "project_command_output"
        || action == "ai_session_status_update"
        || action == "ai_question_asked"
        || action == "ai_question_cleared"
        || action == "ai_chat_message_updated"
        || action == "ai_chat_part_updated"
        || action == "ai_chat_part_delta"
        || action == "ai_chat_done"
        || action == "ai_chat_error"
        || action.starts_with("evo_")
}
