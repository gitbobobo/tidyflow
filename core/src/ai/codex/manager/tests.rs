use super::{AcpContentEncodingMode, AppServerRequestError, CodexAppServerManager};
use serde_json::json;
use std::fs;
use std::path::Path;
use std::sync::Arc;

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

#[test]
fn resolve_command_for_launch_should_accept_absolute_executable_path() {
    let resolved = CodexAppServerManager::resolve_command_for_launch("/bin/zsh")
        .expect("absolute executable should resolve");
    assert_eq!(resolved, "/bin/zsh");
}

#[test]
fn should_skip_candidate_path_should_filter_vscode_copilot_shim() {
    let shim_path = Path::new(
        "/Users/demo/Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilotCli/copilot",
    );
    assert!(CodexAppServerManager::should_skip_candidate_path(
        "copilot", shim_path
    ));

    let normal_path = Path::new("/opt/homebrew/bin/copilot");
    assert!(!CodexAppServerManager::should_skip_candidate_path(
        "copilot",
        normal_path
    ));
}

#[test]
fn resolve_command_from_override_should_return_none_for_invalid_path() {
    let key = "TIDYFLOW_CODEX_BIN";
    let previous = std::env::var(key).ok();
    std::env::set_var(key, "/definitely/not/an/executable");
    let resolved = CodexAppServerManager::resolve_command_from_override("codex");
    assert!(resolved.is_none());

    if let Some(previous) = previous {
        std::env::set_var(key, previous);
    } else {
        std::env::remove_var(key);
    }
}

#[tokio::test]
async fn drop_should_cleanup_spawned_child_process() {
    let manager = CodexAppServerManager::new(std::env::temp_dir());
    let child = tokio::process::Command::new("/bin/sh")
        .args(["-c", "sleep 30"])
        .kill_on_drop(true)
        .spawn()
        .expect("spawn sleep");
    let pid = child.id().expect("sleep pid");

    {
        let mut process = manager.process.lock().await;
        *process = Some(child);
    }

    drop(manager);

    for _ in 0..40 {
        if !CodexAppServerManager::is_pid_alive(pid) {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }

    panic!(
        "CodexAppServerManager child process should exit after drop, pid={}",
        pid
    );
}

#[tokio::test]
async fn ensure_server_running_should_serialize_concurrent_startup() {
    let temp_dir = tempfile::tempdir().expect("tempdir");
    let script_path = temp_dir.path().join("fake_app_server.py");
    let counter_path = temp_dir.path().join("starts.log");
    fs::write(
        &script_path,
        r#"import json
import sys
import time

counter_path = sys.argv[1]
with open(counter_path, "a", encoding="utf-8") as handle:
    handle.write("started\n")
    handle.flush()

for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        time.sleep(0.2)
        print(json.dumps({"id": message["id"], "result": {"userAgent": "fake"}}), flush=True)
    elif method == "initialized":
        continue
    else:
        print(json.dumps({"id": message["id"], "result": {}}), flush=True)
"#,
    )
    .expect("write fake app-server script");

    let manager = Arc::new(CodexAppServerManager::new_with_command(
        temp_dir.path().to_path_buf(),
        "/usr/bin/python3",
        vec![
            "-u".to_string(),
            script_path.display().to_string(),
            counter_path.display().to_string(),
        ],
        "Fake app-server",
    ));

    let mut tasks = Vec::new();
    for _ in 0..8 {
        let manager = manager.clone();
        tasks.push(tokio::spawn(async move {
            manager.ensure_server_running().await
        }));
    }

    for task in tasks {
        task.await
            .expect("task join")
            .expect("ensure server running");
    }

    let starts = fs::read_to_string(&counter_path).expect("read starts log");
    assert_eq!(
        starts.lines().count(),
        1,
        "concurrent ensure_server_running should only start one child process"
    );

    manager.stop_server().await.expect("stop fake app-server");
}
