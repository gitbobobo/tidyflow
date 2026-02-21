use serde_json::{Map, Value};
use tracing::error;

use crate::server::protocol::{ClientEnvelopeV6, ClientMessage};

pub(super) fn probe_client_message_type(data: &[u8]) -> String {
    rmp_serde::from_slice::<ClientEnvelopeV6>(data)
        .map(|env| env.action)
        .unwrap_or_else(|_| "unknown".to_string())
}

pub(super) fn action_matches_domain(domain: &str, action: &str) -> bool {
    crate::server::protocol::action_table::matches_action_domain(domain, action)
}

pub(super) fn decode_and_validate_envelope(data: &[u8]) -> Result<ClientEnvelopeV6, String> {
    let envelope: ClientEnvelopeV6 = rmp_serde::from_slice(data).map_err(|e| {
        error!("Failed to parse client message: {}", e);
        format!("Parse error: {}", e)
    })?;
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
    use serde_json::json;

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
}
