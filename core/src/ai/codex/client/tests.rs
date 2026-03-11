use super::CodexAppServerClient;
use serde_json::json;

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

#[test]
fn parse_model_list_response_extracts_reasoning_effort_metadata() {
    let response = json!({
        "data": [
            {
                "id": "gpt-5-codex",
                "model": "gpt-5-codex",
                "displayName": "GPT-5 Codex",
                "description": "适合代码任务",
                "supportedReasoningEfforts": [
                    { "reasoningEffort": "low", "description": "更快" },
                    { "reasoningEffort": "high", "description": "更深入" }
                ],
                "defaultReasoningEffort": "high",
                "inputModalities": ["text", "image"],
                "isDefault": true
            }
        ]
    });

    let models =
        CodexAppServerClient::parse_model_list_response(&response).expect("parse should succeed");
    assert_eq!(models.len(), 1);
    let model = &models[0];
    assert_eq!(model.id, "gpt-5-codex");
    assert_eq!(model.description.as_deref(), Some("适合代码任务"));
    assert_eq!(
        model
            .supported_reasoning_efforts
            .iter()
            .map(|item| item.value.as_str())
            .collect::<Vec<_>>(),
        vec!["low", "high"]
    );
    assert_eq!(model.default_reasoning_effort.as_deref(), Some("high"));
    assert_eq!(model.input_modalities, vec!["text", "image"]);
    assert!(model.is_default);
}

#[test]
fn apply_turn_start_overrides_sends_top_level_effort_without_collaboration_mode() {
    let mut params = json!({
        "threadId": "thread-1",
        "input": []
    });

    CodexAppServerClient::apply_turn_start_overrides(
        &mut params,
        Some("gpt-5-codex".to_string()),
        None,
        Some("high".to_string()),
        None,
    );

    assert_eq!(
        params.get("model").and_then(|v| v.as_str()),
        Some("gpt-5-codex")
    );
    assert_eq!(params.get("effort").and_then(|v| v.as_str()), Some("high"));
    assert!(params.get("modelProvider").is_none());
    assert!(params.get("collaborationMode").is_none());
}

#[test]
fn apply_turn_start_overrides_keeps_collaboration_mode_but_omits_reasoning_effort_from_settings() {
    let mut params = json!({
        "threadId": "thread-1",
        "input": []
    });

    CodexAppServerClient::apply_turn_start_overrides(
        &mut params,
        None,
        Some("plan".to_string()),
        Some("medium".to_string()),
        Some("gpt-5-codex".to_string()),
    );

    assert_eq!(
        params.get("model").and_then(|v| v.as_str()),
        Some("gpt-5-codex")
    );
    assert_eq!(
        params.get("effort").and_then(|v| v.as_str()),
        Some("medium")
    );
    assert_eq!(
        params
            .pointer("/collaborationMode/settings/model")
            .and_then(|v| v.as_str()),
        Some("gpt-5-codex")
    );
    assert!(params
        .pointer("/collaborationMode/settings/reasoning_effort")
        .is_none());
}
