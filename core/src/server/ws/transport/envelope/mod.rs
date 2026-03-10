use crate::server::protocol::{ServerEnvelopeV6, ServerMessage};

mod mapping;

pub(in crate::server::ws) fn encode_server_message(msg: &ServerMessage) -> Result<Vec<u8>, String> {
    let envelope = to_server_envelope(msg)?;
    rmp_serde::to_vec_named(&envelope).map_err(|e| e.to_string())
}

fn to_server_envelope(msg: &ServerMessage) -> Result<ServerEnvelopeV6, String> {
    let mut value = serde_json::to_value(msg).map_err(|e| e.to_string())?;
    let mut payload = match value {
        serde_json::Value::Object(ref mut map) => map.clone(),
        _ => return Err("Invalid server message payload".to_string()),
    };
    let action = payload
        .remove("type")
        .and_then(|v| v.as_str().map(str::to_string))
        .ok_or_else(|| "Server message missing type".to_string())?;
    let kind = if action == "error" {
        "error".to_string()
    } else if mapping::is_event_action(&action) {
        "event".to_string()
    } else {
        "result".to_string()
    };
    Ok(ServerEnvelopeV6 {
        request_id: crate::server::ws::current_request_id(),
        seq: crate::server::ws::next_server_envelope_seq(),
        domain: mapping::domain_from_action(&action),
        action,
        kind,
        payload: serde_json::Value::Object(payload),
        server_ts: chrono::Utc::now().timestamp_millis() as u64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::protocol::{ServerEnvelopeV6, ServerMessage};

    #[tokio::test]
    async fn encode_server_message_includes_request_id_when_scoped() {
        let bytes = crate::server::ws::with_request_id(Some("req-123".to_string()), async {
            encode_server_message(&ServerMessage::Pong).expect("encode should succeed")
        })
        .await;
        let env: ServerEnvelopeV6 = rmp_serde::from_slice(&bytes).expect("decode envelope");
        assert_eq!(env.request_id.as_deref(), Some("req-123"));
        assert_eq!(env.domain, "system");
        assert_eq!(env.action, "pong");
        assert_eq!(env.kind, "result");
        assert!(env.seq >= 1);
        assert!(env.server_ts > 0);
    }

    #[tokio::test]
    async fn encode_server_message_event_kind_for_output_batch() {
        let bytes = crate::server::ws::with_request_id(None, async {
            encode_server_message(&ServerMessage::OutputBatch {
                items: vec![crate::server::protocol::terminal::TerminalOutputBatchItem {
                    term_id: "t1".to_string(),
                    data: vec![1, 2, 3],
                }],
            })
            .expect("encode should succeed")
        })
        .await;
        let env: ServerEnvelopeV6 = rmp_serde::from_slice(&bytes).expect("decode envelope");
        assert_eq!(env.request_id, None);
        assert_eq!(env.domain, "terminal");
        assert_eq!(env.action, "output_batch");
        assert_eq!(env.kind, "event");
        assert!(env.seq >= 1);
        assert!(env.server_ts > 0);
    }

    #[tokio::test]
    async fn encode_server_message_seq_is_monotonic() {
        let first = crate::server::ws::with_request_id(None, async {
            encode_server_message(&ServerMessage::Pong).expect("encode first")
        })
        .await;
        let second = crate::server::ws::with_request_id(None, async {
            encode_server_message(&ServerMessage::Pong).expect("encode second")
        })
        .await;

        let first_env: ServerEnvelopeV6 = rmp_serde::from_slice(&first).expect("decode first");
        let second_env: ServerEnvelopeV6 = rmp_serde::from_slice(&second).expect("decode second");
        assert!(second_env.seq > first_env.seq);
    }
}
