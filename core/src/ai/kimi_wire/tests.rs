use super::agent::KimiWireAgent;
use super::client::{KimiWireClient, KimiWireTransport};
use super::protocol::{
    parse_initialize_result, parse_wire_event, parse_wire_request, KimiWireEvent, KimiWireRequest,
    WireRequestError, WireRpcError,
};
use crate::ai::AiAgent;
use async_trait::async_trait;
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::sync::Arc;
use tokio::sync::{broadcast, Mutex};
use tokio_stream::StreamExt;

struct MockTransport {
    responses: Mutex<VecDeque<Result<Value, WireRequestError>>>,
    requests: Mutex<Vec<(String, Option<Value>)>>,
    sent_responses: Mutex<Vec<(Value, Value)>>,
    events_tx: broadcast::Sender<KimiWireEvent>,
    requests_tx: broadcast::Sender<KimiWireRequest>,
}

impl MockTransport {
    fn new(responses: Vec<Result<Value, WireRequestError>>) -> Self {
        let (events_tx, _) = broadcast::channel(256);
        let (requests_tx, _) = broadcast::channel(256);
        Self {
            responses: Mutex::new(VecDeque::from(responses)),
            requests: Mutex::new(Vec::new()),
            sent_responses: Mutex::new(Vec::new()),
            events_tx,
            requests_tx,
        }
    }

    async fn requests_snapshot(&self) -> Vec<(String, Option<Value>)> {
        self.requests.lock().await.clone()
    }

    async fn sent_responses_snapshot(&self) -> Vec<(Value, Value)> {
        self.sent_responses.lock().await.clone()
    }

    fn send_event(&self, event_type: &str, payload: Value) {
        let _ = self.events_tx.send(KimiWireEvent {
            event_type: event_type.to_string(),
            payload,
        });
    }

    fn send_request(&self, id: Value, request_type: &str, payload: Value) {
        let _ = self.requests_tx.send(KimiWireRequest {
            id,
            request_type: request_type.to_string(),
            payload,
        });
    }
}

#[async_trait]
impl KimiWireTransport for MockTransport {
    async fn ensure_running(&self) -> Result<(), String> {
        Ok(())
    }

    async fn stop(&self) -> Result<(), String> {
        Ok(())
    }

    async fn send_request_with_error(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, WireRequestError> {
        self.requests
            .lock()
            .await
            .push((method.to_string(), params.clone()));
        self.responses
            .lock()
            .await
            .pop_front()
            .unwrap_or_else(|| Err(WireRequestError::Transport("no mock response".to_string())))
    }

    async fn send_notification(&self, method: &str, params: Option<Value>) -> Result<(), String> {
        self.requests
            .lock()
            .await
            .push((method.to_string(), params));
        Ok(())
    }

    async fn send_response(&self, id: Value, result: Value) -> Result<(), String> {
        self.sent_responses.lock().await.push((id, result));
        Ok(())
    }

    fn subscribe_events(&self) -> broadcast::Receiver<KimiWireEvent> {
        self.events_tx.subscribe()
    }

    fn subscribe_requests(&self) -> broadcast::Receiver<KimiWireRequest> {
        self.requests_tx.subscribe()
    }
}

#[tokio::test]
async fn initialize_should_negotiate_from_1_4_to_1_3() {
    let transport = Arc::new(MockTransport::new(vec![
        Err(WireRequestError::Rpc(WireRpcError {
            code: -32602,
            message: "unsupported protocol_version: 1.4".to_string(),
            data: None,
        })),
        Ok(json!({
            "protocol_version": "1.3",
            "slash_commands": [{"name": "clear", "description": "clear context"}],
            "capabilities": {"supports_question": true}
        })),
    ]));
    let client = KimiWireClient::new_with_transport(transport.clone());

    client
        .ensure_initialized()
        .await
        .expect("initialize should succeed");

    let requests = transport.requests_snapshot().await;
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].0, "initialize");
    assert_eq!(
        requests[0]
            .1
            .as_ref()
            .and_then(|v| v.get("protocol_version"))
            .and_then(|v| v.as_str()),
        Some("1.4")
    );
    assert_eq!(
        requests[1]
            .1
            .as_ref()
            .and_then(|v| v.get("protocol_version"))
            .and_then(|v| v.as_str()),
        Some("1.3")
    );

    let snapshot = client.state_snapshot().await;
    assert!(snapshot.initialized);
    assert_eq!(snapshot.protocol_version.as_deref(), Some("1.3"));
    assert!(snapshot.supports_question);
    assert_eq!(snapshot.slash_commands.len(), 1);
}

#[tokio::test]
async fn prompt_should_use_user_input_schema() {
    let transport = Arc::new(MockTransport::new(vec![
        Ok(json!({
            "protocol_version": "1.3",
            "slash_commands": [],
            "capabilities": {"supports_question": true}
        })),
        Ok(json!({"status": "finished"})),
    ]));
    let client = KimiWireClient::new_with_transport(transport.clone());

    client
        .prompt("hello".to_string())
        .await
        .expect("prompt should succeed");

    let requests = transport.requests_snapshot().await;
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[1].0, "prompt");
    assert_eq!(
        requests[1]
            .1
            .as_ref()
            .and_then(|v| v.get("user_input"))
            .and_then(|v| v.as_str()),
        Some("hello")
    );
}

#[test]
fn protocol_parsers_should_parse_initialize_event_and_request() {
    let parsed = parse_initialize_result(&json!({
        "protocol_version": "1.3",
        "slash_commands": [{"name": "clear", "description": "Clear"}],
        "capabilities": {"supports_question": true}
    }));
    assert_eq!(parsed.protocol_version.as_deref(), Some("1.3"));
    assert!(parsed.supports_question);
    assert_eq!(parsed.slash_commands[0].name, "clear");

    let event = parse_wire_event(&json!({
        "type": "ContentPart",
        "payload": {"type": "text", "text": "hello"}
    }))
    .expect("event should parse");
    assert_eq!(event.event_type, "ContentPart");

    let request = parse_wire_request(
        json!("rpc-1"),
        &json!({
            "type": "ApprovalRequest",
            "payload": {"id": "approval-1"}
        }),
    )
    .expect("request should parse");
    assert_eq!(request.request_type, "ApprovalRequest");
    assert_eq!(
        request.payload.get("id").and_then(|v| v.as_str()),
        Some("approval-1")
    );
}

#[tokio::test]
async fn agent_should_isolate_sessions_by_directory() {
    let agent = KimiWireAgent::new();
    let _ = agent
        .create_session("/tmp/project-a", "A")
        .await
        .expect("create session A");
    let _ = agent
        .create_session("/tmp/project-b", "B")
        .await
        .expect("create session B");

    let sessions_a = agent.list_sessions("/tmp/project-a").await.expect("list A");
    let sessions_b = agent.list_sessions("/tmp/project-b").await.expect("list B");

    assert_eq!(sessions_a.len(), 1);
    assert_eq!(sessions_b.len(), 1);
    assert_ne!(sessions_a[0].id, sessions_b[0].id);
}

#[tokio::test]
async fn stream_should_map_wire_events_to_ai_events() {
    let transport = Arc::new(MockTransport::new(vec![
        Ok(json!({
            "protocol_version": "1.3",
            "slash_commands": [{"name": "clear", "description": "clear"}],
            "capabilities": {"supports_question": true}
        })),
        Ok(json!({"status": "finished"})),
    ]));
    let client = KimiWireClient::new_with_transport(transport.clone());

    let agent = KimiWireAgent::new();
    let session = agent
        .create_session("/tmp/kimi-wire-e2e", "test")
        .await
        .expect("create session");
    agent
        .insert_runtime_for_test("/tmp/kimi-wire-e2e", &session.id, client)
        .await;

    let mut stream = agent
        .send_message(
            "/tmp/kimi-wire-e2e",
            &session.id,
            "请执行并总结",
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("send message");

    transport.send_event("TurnBegin", json!({ "user_input": "请执行并总结" }));
    transport.send_event(
        "ContentPart",
        json!({ "type": "think", "think": "我先分析" }),
    );
    transport.send_event("ContentPart", json!({ "type": "text", "text": "好的" }));
    transport.send_event(
        "ToolCall",
        json!({
            "type": "function",
            "id": "tc-1",
            "function": {"name": "Shell", "arguments": "{\"command\":\"pwd\"}"}
        }),
    );
    transport.send_event(
        "ToolCallPart",
        json!({ "arguments_part": "{\"command\":\"pwd\"}" }),
    );
    transport.send_event(
        "ToolResult",
        json!({
            "tool_call_id": "tc-1",
            "return_value": {
                "is_error": false,
                "output": "/tmp/kimi-wire-e2e",
                "message": "ok",
                "display": []
            }
        }),
    );
    transport.send_event(
        "StatusUpdate",
        json!({ "context_usage": 0.12, "token_usage": {"output": 3} }),
    );
    transport.send_event("TurnEnd", json!({}));

    let mut seen_reasoning_delta = false;
    let mut seen_text_delta = false;
    let mut seen_tool_update = false;
    let mut seen_done = false;

    while let Some(item) = stream.next().await {
        let event = item.expect("stream event should be ok");
        match event {
            crate::ai::AiEvent::PartDelta { part_type, .. } if part_type == "reasoning" => {
                seen_reasoning_delta = true;
            }
            crate::ai::AiEvent::PartDelta { part_type, .. } if part_type == "text" => {
                seen_text_delta = true;
            }
            crate::ai::AiEvent::PartUpdated { part, .. } if part.part_type == "tool" => {
                seen_tool_update = true;
            }
            crate::ai::AiEvent::Done { .. } => {
                seen_done = true;
                break;
            }
            _ => {}
        }
    }

    assert!(seen_reasoning_delta);
    assert!(seen_text_delta);
    assert!(seen_tool_update);
    assert!(seen_done);

    let messages = agent
        .list_messages("/tmp/kimi-wire-e2e", &session.id, None)
        .await
        .expect("list messages");
    assert!(messages.len() >= 2);
    let assistant = messages
        .iter()
        .find(|message| message.role == "assistant")
        .expect("assistant message should exist");
    assert!(assistant.parts.iter().any(|part| {
        part.source
            .as_ref()
            .and_then(|v| v.get("vendor"))
            .and_then(|v| v.as_str())
            == Some("kimi-wire")
    }));
}

#[tokio::test]
async fn approval_reply_should_send_wire_approval_response() {
    let transport = Arc::new(MockTransport::new(vec![
        Ok(json!({
            "protocol_version": "1.3",
            "slash_commands": [],
            "capabilities": {"supports_question": true}
        })),
        Ok(json!({"status": "finished"})),
    ]));
    let client = KimiWireClient::new_with_transport(transport.clone());

    let agent = KimiWireAgent::new();
    let session = agent
        .create_session("/tmp/kimi-wire-approval", "approval")
        .await
        .expect("create session");
    agent
        .insert_runtime_for_test("/tmp/kimi-wire-approval", &session.id, client)
        .await;

    let mut stream = agent
        .send_message(
            "/tmp/kimi-wire-approval",
            &session.id,
            "请执行命令",
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("send message");

    transport.send_request(
        json!("rpc-approval-1"),
        "ApprovalRequest",
        json!({
            "id": "approval-1",
            "tool_call_id": "tc-1",
            "sender": "Shell",
            "action": "run command",
            "description": "Run command `pwd`"
        }),
    );

    let mut request_id: Option<String> = None;
    while let Some(item) = stream.next().await {
        let event = item.expect("stream event should be ok");
        if let crate::ai::AiEvent::QuestionAsked { request } = event {
            request_id = Some(request.id);
            break;
        }
    }

    let request_id = request_id.expect("approval question should be emitted");
    agent
        .reply_question(
            "/tmp/kimi-wire-approval",
            &request_id,
            vec![vec!["allow-once".to_string()]],
        )
        .await
        .expect("reply question should succeed");

    let responses = transport.sent_responses_snapshot().await;
    assert_eq!(responses.len(), 1);
    assert_eq!(responses[0].0, json!("rpc-approval-1"));
    assert_eq!(
        responses[0].1.get("request_id").and_then(|v| v.as_str()),
        Some("approval-1")
    );
    assert_eq!(
        responses[0].1.get("response").and_then(|v| v.as_str()),
        Some("approve")
    );

    transport.send_event("TurnEnd", json!({}));
    while let Some(item) = stream.next().await {
        if let crate::ai::AiEvent::Done { .. } = item.expect("stream event should be ok") {
            break;
        }
    }
}
