use super::action_table::matches_action_domain;

#[test]
fn matches_known_rules() {
    assert!(matches_action_domain("system", "ping"));
    assert!(matches_action_domain("terminal", "term_create"));
    assert!(matches_action_domain("terminal", "input"));
    assert!(matches_action_domain("file", "file_read"));
    assert!(matches_action_domain("git", "cancel_ai_task"));
    assert!(matches_action_domain("settings", "save_client_settings"));
    assert!(matches_action_domain("evolution", "evo_get_snapshot"));
}

#[test]
fn rejects_unknown_rules() {
    assert!(!matches_action_domain("system", "file_list"));
    assert!(!matches_action_domain("project", "lsp_start_workspace"));
    assert!(!matches_action_domain("log", "ping"));
}
