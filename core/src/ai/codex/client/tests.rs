
use super::CodexAppServerClient;

#[test]
fn mode_priority_should_keep_default_then_plan_first() {
    let mut names = vec![
        "plan".to_string(),
        "custom".to_string(),
        "default".to_string(),
    ];
    names.sort_by_key(|name| CodexAppServerClient::mode_priority(name));
    assert_eq!(
        names,
        vec![
            "default".to_string(),
            "plan".to_string(),
            "custom".to_string()
        ]
    );
}
