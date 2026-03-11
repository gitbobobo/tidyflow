use super::AcpClient;
use crate::ai::acp::transport::AcpTransport;
use crate::ai::codex_manager::{
    AcpAuthMethod, AcpContentEncodingMode, AcpInitializationState, AppServerRequestError,
    CodexNotification, CodexServerRequest, JsonRpcError,
};
use async_trait::async_trait;
use serde_json::{json, Value};
use std::collections::{HashSet, VecDeque};
use std::sync::Arc;
use tokio::sync::{broadcast, Mutex};

struct MockTransport {
    responses: Mutex<VecDeque<Result<Value, AppServerRequestError>>>,
    requests: Mutex<Vec<(String, Option<Value>)>>,
    init_state: Mutex<Option<AcpInitializationState>>,
    notifications_tx: broadcast::Sender<CodexNotification>,
    requests_tx: broadcast::Sender<CodexServerRequest>,
}

impl MockTransport {
    fn new(
        responses: Vec<Result<Value, AppServerRequestError>>,
        init_state: Option<AcpInitializationState>,
    ) -> Self {
        let (notifications_tx, _) = broadcast::channel(16);
        let (requests_tx, _) = broadcast::channel(16);
        Self {
            responses: Mutex::new(VecDeque::from(responses)),
            requests: Mutex::new(Vec::new()),
            init_state: Mutex::new(init_state),
            notifications_tx,
            requests_tx,
        }
    }

    async fn request_methods(&self) -> Vec<String> {
        self.requests
            .lock()
            .await
            .iter()
            .map(|(method, _)| method.clone())
            .collect()
    }

    async fn state_snapshot(&self) -> Option<AcpInitializationState> {
        self.init_state.lock().await.clone()
    }

    async fn first_request_params(&self, method: &str) -> Option<Value> {
        self.requests
            .lock()
            .await
            .iter()
            .find(|(m, _)| m == method)
            .and_then(|(_, params)| params.clone())
    }
}

#[async_trait]
impl AcpTransport for MockTransport {
    async fn ensure_server_running(&self) -> Result<(), String> {
        Ok(())
    }

    async fn send_request_with_error(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, AppServerRequestError> {
        self.requests
            .lock()
            .await
            .push((method.to_string(), params.clone()));
        self.responses
            .lock()
            .await
            .pop_front()
            .unwrap_or_else(|| Ok(json!({})))
    }

    async fn send_notification(&self, _method: &str, _params: Option<Value>) -> Result<(), String> {
        Ok(())
    }

    async fn send_response(&self, _id: Value, _result: Value) -> Result<(), String> {
        Ok(())
    }

    fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification> {
        self.notifications_tx.subscribe()
    }

    fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest> {
        self.requests_tx.subscribe()
    }

    async fn acp_initialization_state(&self) -> Option<AcpInitializationState> {
        self.init_state.lock().await.clone()
    }

    async fn set_acp_authenticated(&self, authenticated: bool) {
        if let Some(state) = self.init_state.lock().await.as_mut() {
            state.authenticated = authenticated;
        }
    }
}

#[test]
fn parse_session_summary_should_accept_file_url_and_epoch_millis() {
    let payload = json!({
        "sessionId": "ses_1",
        "title": "Kimi Chat",
        "cwdUri": "file:///tmp/demo",
        "updatedAt": 1_706_000_000_123i64
    });

    let session = AcpClient::parse_session_summary(payload).expect("session should parse");
    assert_eq!(session.id, "ses_1");
    assert_eq!(session.title, "Kimi Chat");
    assert_eq!(session.cwd, "/tmp/demo");
    assert_eq!(session.updated_at_ms, 1_706_000_000_123i64);
}

#[test]
fn parse_session_summary_should_accept_nested_directory_and_rfc3339_time() {
    let payload = json!({
        "id": "ses_2",
        "directory": { "path": "/Users/test/workspace" },
        "time": { "updated": "2026-02-27T11:00:00Z" }
    });

    let session = AcpClient::parse_session_summary(payload).expect("session should parse");
    assert_eq!(session.id, "ses_2");
    assert_eq!(session.title, "New Chat");
    assert_eq!(session.cwd, "/Users/test/workspace");
    assert_eq!(session.updated_at_ms, 1_772_190_000_000i64);
}

#[test]
fn parse_timestamp_millis_should_treat_seconds_as_epoch_seconds() {
    let millis = AcpClient::parse_timestamp_millis(&json!(1_706_000_000i64))
        .expect("timestamp should parse");
    assert_eq!(millis, 1_706_000_000_000i64);
}

#[test]
fn normalize_cwd_for_request_should_keep_absolute_path() {
    let cwd = AcpClient::normalize_cwd_for_request("/tmp/workspace")
        .expect("absolute path should normalize");
    assert_eq!(cwd, "/tmp/workspace");
}

#[test]
fn normalize_cwd_for_request_should_convert_file_uri_to_absolute_path() {
    let cwd = AcpClient::normalize_cwd_for_request("file:///tmp/workspace")
        .expect("file uri should normalize");
    assert_eq!(cwd, "/tmp/workspace");
}

#[test]
fn normalize_cwd_for_request_should_reject_relative_path() {
    let err = AcpClient::normalize_cwd_for_request("relative/path")
        .expect_err("relative path should fail");
    assert!(err.contains("绝对路径"));
}

#[tokio::test]
async fn session_new_should_send_absolute_path_cwd() {
    let transport = Arc::new(MockTransport::new(
        vec![Ok(json!({"sessionId": "session-1"}))],
        None,
    ));
    let client = AcpClient::new_with_transport(transport.clone());
    let _ = client
        .session_new("/tmp/workspace")
        .await
        .expect("session/new should succeed");

    let params = transport
        .first_request_params("session/new")
        .await
        .expect("session/new params should exist");
    assert_eq!(
        params.get("cwd").and_then(|v| v.as_str()),
        Some("/tmp/workspace")
    );
    assert_eq!(
        params
            .get("mcpServers")
            .and_then(|v| v.as_array())
            .map(|arr| arr.len()),
        Some(0)
    );
}

#[tokio::test]
async fn session_load_should_send_absolute_path_cwd() {
    let transport = Arc::new(MockTransport::new(vec![Ok(json!({}))], None));
    let client = AcpClient::new_with_transport(transport.clone());
    let _ = client
        .session_load("/tmp/workspace", "session-1")
        .await
        .expect("session/load should succeed");

    let params = transport
        .first_request_params("session/load")
        .await
        .expect("session/load params should exist");
    assert_eq!(
        params.get("cwd").and_then(|v| v.as_str()),
        Some("/tmp/workspace")
    );
    assert_eq!(
        params.get("sessionId").and_then(|v| v.as_str()),
        Some("session-1")
    );
}

#[tokio::test]
async fn session_set_mode_should_send_mode_id() {
    let transport = Arc::new(MockTransport::new(vec![Ok(json!({}))], None));
    let client = AcpClient::new_with_transport(transport.clone());
    client
        .session_set_mode("session-1", "code")
        .await
        .expect("session/set_mode should succeed");

    let params = transport
        .first_request_params("session/set_mode")
        .await
        .expect("session/set_mode params should exist");
    assert_eq!(
        params.get("sessionId").and_then(|v| v.as_str()),
        Some("session-1")
    );
    assert_eq!(params.get("modeId").and_then(|v| v.as_str()), Some("code"));
}

#[tokio::test]
async fn session_set_config_option_should_send_option_id_and_value() {
    let transport = Arc::new(MockTransport::new(vec![Ok(json!({}))], None));
    let client = AcpClient::new_with_transport(transport.clone());
    client
        .session_set_config_option(
            "session-1",
            "model_variant",
            json!({
                "id": "high"
            }),
        )
        .await
        .expect("session/set_config_option should succeed");

    let params = transport
        .first_request_params("session/set_config_option")
        .await
        .expect("session/set_config_option params should exist");
    assert_eq!(
        params.get("sessionId").and_then(|v| v.as_str()),
        Some("session-1")
    );
    assert_eq!(
        params.get("optionId").and_then(|v| v.as_str()),
        Some("model_variant")
    );
    assert_eq!(
        params
            .get("value")
            .and_then(|v| v.get("id"))
            .and_then(|v| v.as_str()),
        Some("high")
    );
}

#[tokio::test]
async fn terminal_create_should_send_session_and_tool_call_id() {
    let transport = Arc::new(MockTransport::new(
        vec![Ok(json!({
            "terminalId": "term-1"
        }))],
        None,
    ));
    let client = AcpClient::new_with_transport(transport.clone());
    let terminal_id = client
        .terminal_create("session-1", "call-1")
        .await
        .expect("terminal/create should succeed");
    assert_eq!(terminal_id, "term-1");

    let params = transport
        .first_request_params("terminal/create")
        .await
        .expect("terminal/create params should exist");
    assert_eq!(
        params.get("sessionId").and_then(|v| v.as_str()),
        Some("session-1")
    );
    assert_eq!(
        params.get("toolCallId").and_then(|v| v.as_str()),
        Some("call-1")
    );
}

#[tokio::test]
async fn terminal_create_should_accept_id_alias_in_response() {
    let transport = Arc::new(MockTransport::new(
        vec![Ok(json!({ "id": "term-2" }))],
        None,
    ));
    let client = AcpClient::new_with_transport(transport);
    let terminal_id = client
        .terminal_create("session-2", "call-2")
        .await
        .expect("terminal/create should accept id fallback");
    assert_eq!(terminal_id, "term-2");
}

#[tokio::test]
async fn terminal_create_should_fail_when_response_missing_terminal_id() {
    let transport = Arc::new(MockTransport::new(vec![Ok(json!({}))], None));
    let client = AcpClient::new_with_transport(transport);
    let err = client
        .terminal_create("session-3", "call-3")
        .await
        .expect_err("terminal/create should fail when terminal id missing");
    assert!(err.contains("terminalId"));
}

#[tokio::test]
async fn terminal_release_should_send_terminal_id() {
    let transport = Arc::new(MockTransport::new(vec![Ok(json!({}))], None));
    let client = AcpClient::new_with_transport(transport.clone());
    client
        .terminal_release("term-9")
        .await
        .expect("terminal/release should succeed");

    let params = transport
        .first_request_params("terminal/release")
        .await
        .expect("terminal/release params should exist");
    assert_eq!(
        params.get("terminalId").and_then(|v| v.as_str()),
        Some("term-9")
    );
}

#[test]
fn parse_session_metadata_should_parse_grouped_config_options() {
    let payload = json!({
        "configOptions": [
            {
                "optionId": "mode",
                "category": "mode",
                "name": "模式",
                "currentValue": "code",
                "options": [
                    {
                        "label": "常用",
                        "options": [
                            {
                                "value": "code",
                                "label": "代码"
                            },
                            {
                                "value": {
                                    "id": "plan"
                                },
                                "label": "规划"
                            }
                        ]
                    }
                ]
            }
        ],
        "selectedConfigOptions": {
            "mode": "code"
        }
    });

    let metadata = AcpClient::parse_session_metadata(&payload);
    assert_eq!(metadata.config_options.len(), 1);
    let mode = &metadata.config_options[0];
    assert_eq!(mode.option_id, "mode");
    assert_eq!(mode.category.as_deref(), Some("mode"));
    assert_eq!(mode.current_value, Some(json!("code")));
    assert_eq!(mode.option_groups.len(), 1);
    assert_eq!(mode.option_groups[0].label, "常用");
    assert_eq!(mode.option_groups[0].options.len(), 2);
    assert_eq!(
        mode.option_groups[0].options[1]
            .value
            .get("id")
            .and_then(|v| v.as_str()),
        Some("plan")
    );
    assert_eq!(metadata.config_values.get("mode"), Some(&json!("code")));
}

#[tokio::test]
async fn auth_required_should_authenticate_then_retry_original_request_once() {
    let state = AcpInitializationState {
        negotiated_protocol_version: Some(1),
        auth_methods: vec![AcpAuthMethod {
            id: "oauth".to_string(),
            name: None,
            description: None,
        }],
        ..Default::default()
    };
    let transport = Arc::new(MockTransport::new(
        vec![
            Err(AppServerRequestError::Rpc(JsonRpcError {
                code: -32000,
                message: "Authentication required".to_string(),
                data: None,
            })),
            Ok(json!({"ok": true})),
            Ok(json!({"sessionId": "session-1"})),
        ],
        Some(state),
    ));
    let client = AcpClient::new_with_transport(transport.clone());

    let (session_id, _) = client
        .session_new("/tmp/workspace")
        .await
        .expect("session/new should succeed after authentication");
    assert_eq!(session_id, "session-1");
    assert_eq!(
        transport.request_methods().await,
        vec!["session/new", "authenticate", "session/new"]
    );
    assert!(transport
        .state_snapshot()
        .await
        .map(|state| state.authenticated)
        .unwrap_or(false));
}

#[tokio::test]
async fn auth_required_after_retry_should_fail_without_infinite_loop() {
    let state = AcpInitializationState {
        negotiated_protocol_version: Some(1),
        auth_methods: vec![AcpAuthMethod {
            id: "oauth".to_string(),
            name: None,
            description: None,
        }],
        ..Default::default()
    };
    let transport = Arc::new(MockTransport::new(
        vec![
            Err(AppServerRequestError::Rpc(JsonRpcError {
                code: -32000,
                message: "Authentication required".to_string(),
                data: None,
            })),
            Ok(json!({"ok": true})),
            Err(AppServerRequestError::Rpc(JsonRpcError {
                code: -32000,
                message: "Authentication required".to_string(),
                data: None,
            })),
        ],
        Some(state),
    ));
    let client = AcpClient::new_with_transport(transport.clone());

    let err = client
        .session_new("/tmp/workspace")
        .await
        .expect_err("second auth_required should stop retry loop");
    assert!(err.contains("停止重试"));
    assert_eq!(
        transport.request_methods().await,
        vec!["session/new", "authenticate", "session/new"]
    );
}

#[tokio::test]
async fn auth_required_without_auth_methods_should_return_diagnostic_error() {
    let state = AcpInitializationState {
        negotiated_protocol_version: Some(1),
        auth_methods: Vec::new(),
        ..Default::default()
    };
    let transport = Arc::new(MockTransport::new(
        vec![Err(AppServerRequestError::Rpc(JsonRpcError {
            code: -32000,
            message: "Authentication required".to_string(),
            data: None,
        }))],
        Some(state),
    ));
    let client = AcpClient::new_with_transport(transport);

    let err = client
        .session_new("/tmp/workspace")
        .await
        .expect_err("missing auth methods should fail");
    assert!(err.contains("authMethods"));
}

#[tokio::test]
async fn supports_content_type_should_follow_prompt_capabilities() {
    let mut state = AcpInitializationState {
        negotiated_protocol_version: Some(1),
        ..Default::default()
    };
    state.prompt_capabilities.content_types = HashSet::from([
        "text".to_string(),
        "image".to_string(),
        "resource_link".to_string(),
    ]);
    let transport = Arc::new(MockTransport::new(vec![], Some(state)));
    let client = AcpClient::new_with_transport(transport);

    assert!(client.supports_content_type("text").await);
    assert!(client.supports_content_type("image").await);
    assert!(client.supports_content_type("resource_link").await);
    assert!(!client.supports_content_type("audio").await);
}

#[tokio::test]
async fn supports_content_type_should_default_to_text_when_missing_capabilities() {
    let state = AcpInitializationState {
        negotiated_protocol_version: Some(1),
        ..Default::default()
    };
    let transport = Arc::new(MockTransport::new(vec![], Some(state)));
    let client = AcpClient::new_with_transport(transport);

    assert!(client.supports_content_type("text").await);
    assert!(client.supports_content_type("resource_link").await);
    assert!(!client.supports_content_type("image").await);
}

#[tokio::test]
async fn prompt_encoding_mode_should_follow_initialization_state() {
    let mut state = AcpInitializationState {
        negotiated_protocol_version: Some(1),
        ..Default::default()
    };
    state.prompt_capabilities.encoding_mode = AcpContentEncodingMode::New;
    let transport = Arc::new(MockTransport::new(vec![], Some(state)));
    let client = AcpClient::new_with_transport(transport);

    assert_eq!(
        client.prompt_encoding_mode().await,
        AcpContentEncodingMode::New
    );
}

#[test]
fn prompt_image_audio_builder_should_follow_encoding_mode() {
    let new_image = AcpClient::build_prompt_image_part(
        AcpContentEncodingMode::New,
        "image/png".to_string(),
        "AQID".to_string(),
    );
    assert_eq!(
        new_image.get("type").and_then(|v| v.as_str()),
        Some("image")
    );
    assert_eq!(new_image.get("data").and_then(|v| v.as_str()), Some("AQID"));
    assert!(new_image.get("url").is_none());

    let legacy_image = AcpClient::build_prompt_image_part(
        AcpContentEncodingMode::Legacy,
        "image/png".to_string(),
        "AQID".to_string(),
    );
    assert!(legacy_image
        .get("url")
        .and_then(|v| v.as_str())
        .is_some_and(|v| v.starts_with("data:image/png;base64,AQID")));
    assert!(legacy_image.get("data").is_none());

    let new_audio = AcpClient::build_prompt_audio_part(
        AcpContentEncodingMode::New,
        "audio/wav".to_string(),
        "BAUG".to_string(),
    );
    assert_eq!(
        new_audio.get("type").and_then(|v| v.as_str()),
        Some("audio")
    );
    assert_eq!(new_audio.get("data").and_then(|v| v.as_str()), Some("BAUG"));
    assert!(new_audio.get("url").is_none());

    let legacy_audio = AcpClient::build_prompt_audio_part(
        AcpContentEncodingMode::Legacy,
        "audio/wav".to_string(),
        "BAUG".to_string(),
    );
    assert!(legacy_audio
        .get("url")
        .and_then(|v| v.as_str())
        .is_some_and(|v| v.starts_with("data:audio/wav;base64,BAUG")));
    assert!(legacy_audio.get("data").is_none());
}

#[test]
fn prompt_resource_link_builder_should_support_new_and_legacy_shapes() {
    let new_part = AcpClient::build_prompt_resource_link_part(
        AcpContentEncodingMode::New,
        "file:///tmp/a.txt".to_string(),
        "a.txt".to_string(),
        Some("text/plain".to_string()),
    );
    assert_eq!(
        new_part.get("uri").and_then(|v| v.as_str()),
        Some("file:///tmp/a.txt")
    );
    assert_eq!(new_part.get("name").and_then(|v| v.as_str()), Some("a.txt"));
    assert_eq!(
        new_part.get("mimeType").and_then(|v| v.as_str()),
        Some("text/plain")
    );
    assert!(new_part.get("resource").is_none());

    let legacy_part = AcpClient::build_prompt_resource_link_part(
        AcpContentEncodingMode::Legacy,
        "file:///tmp/b.txt".to_string(),
        "b.txt".to_string(),
        None,
    );
    assert_eq!(
        legacy_part
            .get("resource")
            .and_then(|v| v.get("uri"))
            .and_then(|v| v.as_str()),
        Some("file:///tmp/b.txt")
    );
    assert_eq!(
        legacy_part
            .get("resource")
            .and_then(|v| v.get("name"))
            .and_then(|v| v.as_str()),
        Some("b.txt")
    );
}
