
use super::{AcpContentEncodingMode, AppServerRequestError, CodexAppServerManager};
use serde_json::json;

#[test]
fn acp_initialize_payload_should_match_schema_fields() {
    let payload = CodexAppServerManager::build_acp_initialize_params(1);
    assert_eq!(
        payload.get("protocolVersion").and_then(|v| v.as_u64()),
        Some(1)
    );
    assert!(payload.get("clientCapabilities").is_some());
    assert!(payload.get("clientInfo").is_some());
    assert!(payload.get("capabilities").is_none());
    assert!(
        payload
            .get("clientCapabilities")
            .and_then(|v| v.get("fs"))
            .and_then(|v| v.get("readTextFile"))
            .and_then(|v| v.as_bool())
            == Some(false)
    );
    assert!(
        payload
            .get("clientCapabilities")
            .and_then(|v| v.get("fs"))
            .and_then(|v| v.get("writeTextFile"))
            .and_then(|v| v.as_bool())
            == Some(false)
    );
    assert!(
        payload
            .get("clientCapabilities")
            .and_then(|v| v.get("terminal"))
            .and_then(|v| v.as_bool())
            == Some(false)
    );
}

#[test]
fn legacy_initialize_payload_should_keep_existing_contract() {
    let payload = CodexAppServerManager::build_legacy_initialize_params();
    assert!(payload.get("clientInfo").is_some());
    assert_eq!(
        payload
            .get("capabilities")
            .and_then(|v| v.get("experimentalApi"))
            .and_then(|v| v.as_bool()),
        Some(true)
    );
}

#[test]
fn parse_acp_initialize_response_should_extract_capabilities_and_auth_methods() {
    let response = json!({
        "protocolVersion": 1,
        "agentCapabilities": {
            "loadSession": true,
            "session": {
                "resume": false
            }
        },
        "sessionCapabilities": {
            "setConfigOption": true
        },
        "promptCapabilities": {
            "contentTypes": ["text", "image", "resource_link"]
        },
        "authMethods": [
            {
                "id": "oauth",
                "name": "OAuth",
                "description": "Sign in with browser"
            },
            {
                "id": "device-code"
            }
        ]
    });
    let state = CodexAppServerManager::parse_acp_initialize_result(&response, 1)
        .expect("parse initialize response should succeed");
    assert_eq!(state.negotiated_protocol_version, Some(1));
    assert!(state.agent_capabilities.load_session);
    assert!(state.agent_capabilities.set_config_option);
    assert!(state.prompt_capabilities.content_types.contains("text"));
    assert!(state.prompt_capabilities.content_types.contains("image"));
    assert!(state
        .prompt_capabilities
        .content_types
        .contains("resource_link"));
    assert_eq!(
        state.prompt_capabilities.encoding_mode,
        AcpContentEncodingMode::Legacy
    );
    assert_eq!(state.auth_methods.len(), 2);
    assert_eq!(state.auth_methods[0].id, "oauth");
    assert_eq!(state.auth_methods[1].id, "device-code");
}

#[test]
fn parse_acp_initialize_response_should_parse_new_prompt_capabilities() {
    let response = json!({
        "protocolVersion": 1,
        "agentCapabilities": {
            "promptCapabilities": {
                "image": true,
                "audio": true,
                "embeddedContext": true
            }
        }
    });
    let state = CodexAppServerManager::parse_acp_initialize_result(&response, 1)
        .expect("parse initialize response should succeed");
    assert_eq!(
        state.prompt_capabilities.encoding_mode,
        AcpContentEncodingMode::New
    );
    assert!(state.prompt_capabilities.content_types.contains("text"));
    assert!(state
        .prompt_capabilities
        .content_types
        .contains("resource_link"));
    assert!(state.prompt_capabilities.content_types.contains("image"));
    assert!(state.prompt_capabilities.content_types.contains("audio"));
    assert!(state.prompt_capabilities.content_types.contains("resource"));
}

#[test]
fn parse_acp_initialize_response_should_default_prompt_content_types_to_baseline() {
    let response = json!({
        "protocolVersion": 1
    });
    let state = CodexAppServerManager::parse_acp_initialize_result(&response, 1)
        .expect("parse initialize response should succeed");
    assert_eq!(
        state.prompt_capabilities.encoding_mode,
        AcpContentEncodingMode::Unknown
    );
    assert_eq!(state.prompt_capabilities.content_types.len(), 2);
    assert!(state.prompt_capabilities.content_types.contains("text"));
    assert!(state
        .prompt_capabilities
        .content_types
        .contains("resource_link"));
}

#[test]
fn parse_acp_initialize_response_should_prefer_new_encoding_mode_when_both_present() {
    let response = json!({
        "protocolVersion": 1,
        "promptCapabilities": {
            "contentTypes": ["text", "image"]
        },
        "agentCapabilities": {
            "promptCapabilities": {
                "audio": false,
                "embeddedContext": true
            }
        }
    });
    let state = CodexAppServerManager::parse_acp_initialize_result(&response, 1)
        .expect("parse initialize response should succeed");
    assert_eq!(
        state.prompt_capabilities.encoding_mode,
        AcpContentEncodingMode::New
    );
    assert!(state.prompt_capabilities.content_types.contains("text"));
    assert!(state
        .prompt_capabilities
        .content_types
        .contains("resource_link"));
    assert!(state.prompt_capabilities.content_types.contains("image"));
    assert!(state.prompt_capabilities.content_types.contains("resource"));
    assert!(!state.prompt_capabilities.content_types.contains("audio"));
}

#[test]
fn parse_acp_initialize_response_should_fail_for_unsupported_version() {
    let response = json!({
        "protocolVersion": 2
    });
    let err = CodexAppServerManager::parse_acp_initialize_result(&response, 1)
        .expect_err("version mismatch should fail");
    assert!(err.contains("mismatch"));
}

#[test]
fn parse_rpc_error_should_keep_auth_required_code() {
    let error = json!({
        "code": -32000,
        "message": "Authentication required",
        "data": {
            "hint": "please authenticate"
        }
    });
    let parsed = CodexAppServerManager::parse_rpc_error(&error).expect("rpc error should parse");
    assert_eq!(parsed.code, -32000);
    assert_eq!(parsed.message, "Authentication required");
    assert_eq!(
        AppServerRequestError::Rpc(parsed).to_user_string(),
        "App-server error (code -32000): Authentication required"
    );
}
