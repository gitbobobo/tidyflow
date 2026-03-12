//! 自动生成文件，请勿手改。
//!
//! 来源：`schema/protocol/v9/action_rules.csv`
//! 生成命令：`./scripts/tools/gen_protocol_action_table.sh`

pub const EXACT_RULES: &[(&str, &str)] = &[
    ("system", "ping"),
    ("terminal", "spawn_terminal"),
    ("terminal", "kill_terminal"),
    ("terminal", "input"),
    ("terminal", "resize"),
    ("file", "clipboard_image_upload"),
    ("git", "cancel_ai_task"),
    ("project", "save_template"),
    ("project", "delete_template"),
    ("project", "export_template"),
    ("project", "import_template"),
    ("project", "templates"),
];

pub const PREFIX_RULES: &[(&str, &str)] = &[
    ("terminal", "term_"),
    ("file", "file_"),
    ("file", "watch_"),
    ("git", "git_"),
    ("project", "list_"),
    ("project", "select_"),
    ("project", "import_"),
    ("project", "create_"),
    ("project", "remove_"),
    ("project", "project_"),
    ("project", "workspace_"),
    ("project", "save_project_commands"),
    ("project", "run_project_command"),
    ("project", "cancel_project_command"),
    ("project", "template_"),
    ("ai", "ai_"),
    ("evidence", "evidence_"),
    ("evolution", "evo_"),
    ("git", "git_conflict_"),
    ("health", "health_"),
];

pub const CONTAINS_RULES: &[(&str, &str)] = &[("settings", "client_settings")];

/// 根据规则表判断 action 是否属于给定 domain。
pub fn matches_action_domain(domain: &str, action: &str) -> bool {
    if EXACT_RULES
        .iter()
        .any(|(d, value)| *d == domain && action == *value)
    {
        return true;
    }
    if PREFIX_RULES
        .iter()
        .any(|(d, value)| *d == domain && action.starts_with(*value))
    {
        return true;
    }
    if CONTAINS_RULES
        .iter()
        .any(|(d, value)| *d == domain && action.contains(*value))
    {
        return true;
    }
    false
}
