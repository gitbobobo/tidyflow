use serde::Deserialize;
use serde_json::{Map, Number, Value};
use tracing::error;

use crate::server::protocol::{ClientEnvelopeV6, ClientMessage};

#[derive(Debug, Clone, Deserialize)]
struct DecodedEnvelopeV6 {
    request_id: String,
    domain: String,
    action: String,
    #[serde(default)]
    payload: MsgpackCompatValue,
    #[serde(default)]
    client_ts: u64,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(untagged)]
enum MsgpackCompatValue {
    #[default]
    Null,
    Bool(bool),
    I64(i64),
    U64(u64),
    F64(f64),
    String(String),
    Bytes(#[serde(with = "serde_bytes")] Vec<u8>),
    Array(Vec<MsgpackCompatValue>),
    Object(std::collections::BTreeMap<String, MsgpackCompatValue>),
}

impl MsgpackCompatValue {
    fn into_json(self) -> Value {
        match self {
            MsgpackCompatValue::Null => Value::Null,
            MsgpackCompatValue::Bool(v) => Value::Bool(v),
            MsgpackCompatValue::I64(v) => Value::Number(Number::from(v)),
            MsgpackCompatValue::U64(v) => Value::Number(Number::from(v)),
            MsgpackCompatValue::F64(v) => Number::from_f64(v)
                .map(Value::Number)
                .unwrap_or(Value::Null),
            MsgpackCompatValue::String(v) => Value::String(v),
            MsgpackCompatValue::Bytes(v) => Value::Array(
                v.into_iter()
                    .map(|b| Value::Number(Number::from(b)))
                    .collect(),
            ),
            MsgpackCompatValue::Array(items) => Value::Array(
                items
                    .into_iter()
                    .map(MsgpackCompatValue::into_json)
                    .collect(),
            ),
            MsgpackCompatValue::Object(map) => {
                let mut out = Map::with_capacity(map.len());
                for (k, v) in map {
                    out.insert(k, v.into_json());
                }
                Value::Object(out)
            }
        }
    }
}

pub(super) fn probe_client_message_type(data: &[u8]) -> String {
    rmp_serde::from_slice::<DecodedEnvelopeV6>(data)
        .map(|env| env.action)
        .unwrap_or_else(|_| "unknown".to_string())
}

pub(super) fn action_matches_domain(domain: &str, action: &str) -> bool {
    crate::server::protocol::action_table::matches_action_domain(domain, action)
}

pub(super) fn decode_and_validate_envelope(data: &[u8]) -> Result<ClientEnvelopeV6, String> {
    let decoded: DecodedEnvelopeV6 = rmp_serde::from_slice(data).map_err(|e| {
        error!("Failed to parse client message: {}", e);
        format!("Parse error: {}", e)
    })?;
    let envelope = ClientEnvelopeV6 {
        request_id: decoded.request_id,
        domain: decoded.domain,
        action: decoded.action,
        payload: decoded.payload.into_json(),
        client_ts: decoded.client_ts,
    };
    validate_client_envelope(&envelope)?;
    Ok(envelope)
}

fn validate_client_envelope(envelope: &ClientEnvelopeV6) -> Result<(), String> {
    if envelope.request_id.trim().is_empty() {
        return Err("Invalid envelope: empty request_id".to_string());
    }
    if envelope.domain.trim().is_empty() || envelope.action.trim().is_empty() {
        return Err("Invalid envelope: empty domain/action".to_string());
    }
    if envelope.client_ts == 0 {
        return Err("Invalid envelope: client_ts is required".to_string());
    }
    Ok(())
}

pub(super) fn envelope_payload_to_client_message(
    envelope: &ClientEnvelopeV6,
) -> Result<ClientMessage, String> {
    let mut payload = match &envelope.payload {
        Value::Object(map) => map.clone(),
        Value::Null => Map::new(),
        _ => {
            return Err("Invalid payload: expected object".to_string());
        }
    };
    payload.insert("type".to_string(), Value::String(envelope.action.clone()));
    serde_json::from_value(Value::Object(payload)).map_err(|e| format!("Parse error: {}", e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Serialize;
    use serde_json::json;
    use std::collections::BTreeMap;

    #[test]
    fn envelope_payload_to_client_message_parses_ping() {
        let env = ClientEnvelopeV6 {
            request_id: "req-1".to_string(),
            domain: "system".to_string(),
            action: "ping".to_string(),
            payload: json!({}),
            client_ts: 0,
        };
        let msg = envelope_payload_to_client_message(&env).expect("should parse");
        assert!(matches!(msg, ClientMessage::Ping));
    }

    #[test]
    fn envelope_payload_to_client_message_rejects_non_object_payload() {
        let env = ClientEnvelopeV6 {
            request_id: "req-2".to_string(),
            domain: "system".to_string(),
            action: "ping".to_string(),
            payload: json!(["invalid"]),
            client_ts: 0,
        };
        let err = envelope_payload_to_client_message(&env).expect_err("should fail");
        assert!(err.contains("expected object"));
    }

    #[test]
    fn validate_client_envelope_rejects_empty_request_id() {
        let env = ClientEnvelopeV6 {
            request_id: "   ".to_string(),
            domain: "system".to_string(),
            action: "ping".to_string(),
            payload: json!({}),
            client_ts: 1,
        };
        let err = validate_client_envelope(&env).expect_err("should reject");
        assert!(err.contains("empty request_id"));
    }

    #[test]
    fn validate_client_envelope_rejects_missing_client_ts() {
        let env = ClientEnvelopeV6 {
            request_id: "req-1".to_string(),
            domain: "system".to_string(),
            action: "ping".to_string(),
            payload: json!({}),
            client_ts: 0,
        };
        let err = validate_client_envelope(&env).expect_err("should reject");
        assert!(err.contains("client_ts"));
    }

    #[derive(Serialize)]
    struct TestEnvelope<'a, P>
    where
        P: Serialize,
    {
        request_id: &'a str,
        domain: &'a str,
        action: &'a str,
        payload: P,
        client_ts: u64,
    }

    #[derive(Serialize)]
    struct TestAiChatSendPayload<'a> {
        project_name: &'a str,
        workspace_name: &'a str,
        ai_tool: &'a str,
        session_id: &'a str,
        message: &'a str,
        image_parts: Vec<TestImagePart<'a>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        audio_parts: Option<Vec<TestAudioPart<'a>>>,
    }

    #[derive(Serialize)]
    struct TestAiChatCommandPayload<'a> {
        project_name: &'a str,
        workspace_name: &'a str,
        ai_tool: &'a str,
        session_id: &'a str,
        command: &'a str,
        arguments: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        audio_parts: Option<Vec<TestAudioPart<'a>>>,
    }

    #[derive(Serialize)]
    struct TestImagePart<'a> {
        filename: &'a str,
        mime: &'a str,
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    }

    #[derive(Serialize)]
    struct TestAudioPart<'a> {
        filename: &'a str,
        mime: &'a str,
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    }

    #[test]
    fn decode_envelope_accepts_msgpack_bin_payload() {
        let raw = TestEnvelope {
            request_id: "req-img",
            domain: "ai",
            action: "ai_chat_send",
            payload: TestAiChatSendPayload {
                project_name: "p",
                workspace_name: "w",
                ai_tool: "opencode",
                session_id: "s1",
                message: "hello",
                image_parts: vec![TestImagePart {
                    filename: "a.png",
                    mime: "image/png",
                    data: vec![0, 1, 2, 255],
                }],
                audio_parts: Some(vec![TestAudioPart {
                    filename: "b.wav",
                    mime: "audio/wav",
                    data: vec![7, 8, 9],
                }]),
            },
            client_ts: 1,
        };

        let bytes = rmp_serde::to_vec_named(&raw).expect("encode test envelope");
        let env = decode_and_validate_envelope(&bytes).expect("decode envelope");
        let msg = envelope_payload_to_client_message(&env).expect("decode client message");

        match msg {
            ClientMessage::AIChatSend {
                image_parts,
                audio_parts,
                ..
            } => {
                let parts = image_parts.expect("image parts should exist");
                assert_eq!(parts.len(), 1);
                assert_eq!(parts[0].filename, "a.png");
                assert_eq!(parts[0].mime, "image/png");
                assert_eq!(parts[0].data, vec![0, 1, 2, 255]);
                let audios = audio_parts.expect("audio parts should exist");
                assert_eq!(audios.len(), 1);
                assert_eq!(audios[0].filename, "b.wav");
                assert_eq!(audios[0].mime, "audio/wav");
                assert_eq!(audios[0].data, vec![7, 8, 9]);
            }
            other => panic!("unexpected message: {:?}", other),
        }
    }

    #[test]
    fn decode_envelope_should_keep_backward_compat_when_audio_parts_missing() {
        let raw = TestEnvelope {
            request_id: "req-img-no-audio",
            domain: "ai",
            action: "ai_chat_send",
            payload: TestAiChatSendPayload {
                project_name: "p",
                workspace_name: "w",
                ai_tool: "opencode",
                session_id: "s2",
                message: "hello",
                image_parts: vec![TestImagePart {
                    filename: "a.png",
                    mime: "image/png",
                    data: vec![1, 2],
                }],
                audio_parts: None,
            },
            client_ts: 1,
        };

        let bytes = rmp_serde::to_vec_named(&raw).expect("encode test envelope");
        let env = decode_and_validate_envelope(&bytes).expect("decode envelope");
        let msg = envelope_payload_to_client_message(&env).expect("decode client message");

        match msg {
            ClientMessage::AIChatSend { audio_parts, .. } => {
                assert!(audio_parts.is_none());
            }
            other => panic!("unexpected message: {:?}", other),
        }
    }

    #[test]
    fn decode_envelope_should_decode_command_audio_parts() {
        let raw = TestEnvelope {
            request_id: "req-cmd-audio",
            domain: "ai",
            action: "ai_chat_command",
            payload: TestAiChatCommandPayload {
                project_name: "p",
                workspace_name: "w",
                ai_tool: "opencode",
                session_id: "s3",
                command: "build",
                arguments: "--release",
                audio_parts: Some(vec![TestAudioPart {
                    filename: "voice.m4a",
                    mime: "audio/m4a",
                    data: vec![9, 8, 7],
                }]),
            },
            client_ts: 1,
        };

        let bytes = rmp_serde::to_vec_named(&raw).expect("encode test envelope");
        let env = decode_and_validate_envelope(&bytes).expect("decode envelope");
        let msg = envelope_payload_to_client_message(&env).expect("decode client message");

        match msg {
            ClientMessage::AIChatCommand { audio_parts, .. } => {
                let audios = audio_parts.expect("audio parts should exist");
                assert_eq!(audios.len(), 1);
                assert_eq!(audios[0].filename, "voice.m4a");
                assert_eq!(audios[0].mime, "audio/m4a");
                assert_eq!(audios[0].data, vec![9, 8, 7]);
            }
            other => panic!("unexpected message: {:?}", other),
        }
    }

    #[test]
    fn msgpack_compat_value_bytes_to_json_array() {
        let mut map = BTreeMap::new();
        map.insert("data".to_string(), MsgpackCompatValue::Bytes(vec![1, 2, 3]));
        let value = MsgpackCompatValue::Object(map).into_json();
        let got = value
            .get("data")
            .and_then(|v| v.as_array())
            .expect("data as array");
        assert_eq!(got.len(), 3);
        assert_eq!(got[0].as_u64(), Some(1));
        assert_eq!(got[1].as_u64(), Some(2));
        assert_eq!(got[2].as_u64(), Some(3));
    }
}
