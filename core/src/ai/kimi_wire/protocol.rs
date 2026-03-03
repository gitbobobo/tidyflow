use crate::ai::AiSlashCommand;
use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub struct WireRpcError {
    pub code: i64,
    pub message: String,
    pub data: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WireRequestError {
    Rpc(WireRpcError),
    Transport(String),
    MalformedResponse(String),
}

impl WireRequestError {
    pub fn to_user_string(&self) -> String {
        match self {
            Self::Rpc(err) => format!("Wire RPC error (code {}): {}", err.code, err.message),
            Self::Transport(message) | Self::MalformedResponse(message) => message.clone(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct KimiWireEvent {
    pub event_type: String,
    pub payload: Value,
}

#[derive(Debug, Clone)]
pub struct KimiWireRequest {
    pub id: Value,
    pub request_type: String,
    pub payload: Value,
}

#[derive(Debug, Clone, Default)]
pub struct KimiWireInitializeResult {
    pub protocol_version: Option<String>,
    pub slash_commands: Vec<AiSlashCommand>,
    pub supports_question: bool,
}

fn normalize_non_empty_string(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|it| !it.is_empty())
        .map(|it| it.to_string())
}

pub fn parse_rpc_error(value: &Value) -> Option<WireRpcError> {
    let code = value.get("code")?.as_i64()?;
    let message = value
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown error")
        .to_string();
    let data = value.get("data").cloned();
    Some(WireRpcError {
        code,
        message,
        data,
    })
}

pub fn is_unsupported_protocol_version(error: &WireRpcError) -> bool {
    if error.code != -32602 {
        return false;
    }

    let message = error.message.to_ascii_lowercase();
    if message.contains("unsupported protocol_version")
        || message.contains("unsupported protocol version")
    {
        return true;
    }

    let Some(data) = error.data.as_ref() else {
        return false;
    };
    let data_text = data.to_string().to_ascii_lowercase();
    data_text.contains("unsupported protocol_version")
        || data_text.contains("unsupported protocol version")
}

pub fn parse_initialize_result(value: &Value) -> KimiWireInitializeResult {
    let protocol_version =
        normalize_non_empty_string(value.get("protocol_version").and_then(|v| v.as_str()));

    let supports_question = value
        .get("capabilities")
        .and_then(|v| v.get("supports_question"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    let slash_commands = value
        .get("slash_commands")
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let name =
                        normalize_non_empty_string(item.get("name").and_then(|v| v.as_str()))?;
                    let description = item
                        .get("description")
                        .and_then(|v| v.as_str())
                        .map(|v| v.trim().to_string())
                        .unwrap_or_default();
                    Some(AiSlashCommand {
                        name,
                        description,
                        action: "agent".to_string(),
                        input_hint: None,
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    KimiWireInitializeResult {
        protocol_version,
        slash_commands,
        supports_question,
    }
}

pub fn parse_wire_event(params: &Value) -> Option<KimiWireEvent> {
    let event_type = normalize_non_empty_string(params.get("type").and_then(|v| v.as_str()))?;
    let payload = params.get("payload").cloned().unwrap_or(Value::Null);
    Some(KimiWireEvent {
        event_type,
        payload,
    })
}

pub fn parse_wire_request(id: Value, params: &Value) -> Option<KimiWireRequest> {
    let request_type = normalize_non_empty_string(params.get("type").and_then(|v| v.as_str()))?;
    let payload = params.get("payload").cloned().unwrap_or(Value::Null);
    Some(KimiWireRequest {
        id,
        request_type,
        payload,
    })
}
