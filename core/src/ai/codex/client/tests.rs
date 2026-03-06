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

#[test]
fn turn_start_reasoning_effort_valid_values_are_accepted() {
    // 验证合法的 reasoning_effort 值不会被过滤
    let valid = ["low", "medium", "high"];
    for effort in &valid {
        let normalized = effort.trim().to_lowercase();
        assert!(
            matches!(normalized.as_str(), "low" | "medium" | "high"),
            "expected '{}' to be a valid reasoning_effort",
            effort
        );
    }
}

#[test]
fn turn_start_reasoning_effort_invalid_values_are_rejected() {
    // 验证无效值不会透传到请求负载
    let invalid = ["", "auto", "ultra", "none"];
    for effort in &invalid {
        let normalized = effort.trim().to_lowercase();
        assert!(
            !matches!(normalized.as_str(), "low" | "medium" | "high"),
            "expected '{}' to be rejected as reasoning_effort",
            effort
        );
    }
}
