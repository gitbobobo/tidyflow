use super::action_table::matches_action_domain;
use super::action_table::{CONTAINS_RULES, EXACT_RULES, PREFIX_RULES};

#[test]
fn matches_known_rules() {
    assert!(matches_action_domain("system", "ping"));
    assert!(matches_action_domain("terminal", "term_create"));
    assert!(matches_action_domain("terminal", "input"));
    assert!(matches_action_domain("file", "file_read"));
    assert!(matches_action_domain("git", "cancel_ai_task"));
    assert!(matches_action_domain("settings", "save_client_settings"));
    assert!(matches_action_domain("evidence", "evidence_get_snapshot"));
    assert!(matches_action_domain("evolution", "evo_get_snapshot"));
}

#[test]
fn rejects_unknown_rules() {
    assert!(!matches_action_domain("system", "file_list"));
    assert!(!matches_action_domain("project", "unknown_action"));
    assert!(!matches_action_domain("log", "ping"));
}

#[test]
fn exact_rules_cover_known_terminal_actions() {
    assert!(matches_action_domain("terminal", "spawn_terminal"));
    assert!(matches_action_domain("terminal", "kill_terminal"));
    assert!(matches_action_domain("terminal", "input"));
    assert!(matches_action_domain("terminal", "resize"));
}

#[test]
fn prefix_rules_cover_known_domains() {
    assert!(matches_action_domain("terminal", "term_list"));
    assert!(matches_action_domain("file", "file_list"));
    assert!(matches_action_domain("git", "git_status"));
    assert!(matches_action_domain("project", "list_projects"));
    assert!(matches_action_domain("ai", "ai_start_session"));
}

#[test]
fn contains_rules_cover_client_settings_messages() {
    assert!(matches_action_domain("settings", "client_settings_get"));
    assert!(matches_action_domain("settings", "client_settings_result"));
}

#[test]
fn generated_rule_tables_are_not_empty() {
    assert!(!EXACT_RULES.is_empty());
    assert!(!PREFIX_RULES.is_empty());
    assert!(!CONTAINS_RULES.is_empty());
}
