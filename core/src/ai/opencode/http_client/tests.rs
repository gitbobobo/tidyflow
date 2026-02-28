use super::*;

#[test]
fn test_client_new() {
    let client = OpenCodeClient::new("http://localhost:8080");
    assert_eq!(client.base_url, "http://localhost:8080");
}

#[test]
fn test_session_response_serialization() {
    let json = r#"{"id":"ses_123","title":"Test Session","directory":"/tmp/x","time":{"created":1700000000000,"updated":1700000001234}}"#;
    let session: SessionResponse = serde_json::from_str(json).unwrap();
    assert_eq!(session.id, "ses_123");
    assert_eq!(session.title, "Test Session");
    assert_eq!(session.directory.as_deref(), Some("/tmp/x"));
    assert_eq!(session.effective_updated_at(), 1700000001234);
}

#[test]
fn test_session_response_deserialization() {
    let session = SessionResponse {
        id: "ses_abc".to_string(),
        title: "My Session".to_string(),
        directory: None,
        time: None,
        updated_at: 1234567890,
        extra: std::collections::HashMap::new(),
    };
    let json = serde_json::to_string(&session).unwrap();
    assert!(json.contains("\"id\":\"ses_abc\""));
    assert!(json.contains("\"title\":\"My Session\""));
}

#[test]
fn test_create_session_request() {
    let request = CreateSessionRequest {
        title: "New Session".to_string(),
    };
    let json = serde_json::to_string(&request).unwrap();
    assert!(json.contains("\"title\":\"New Session\""));
}

#[test]
fn test_prompt_async_body() {
    let body = serde_json::json!({
        "parts": [
            { "type": "text", "text": "Hello" },
            { "type": "file", "url": "file:///src/main.rs", "filename": "src/main.rs", "mime": "text/plain" },
        ]
    });
    let json = serde_json::to_string(&body).unwrap();
    assert!(json.contains("\"parts\""));
    assert!(json.contains("\"type\":\"text\""));
    assert!(json.contains("\"type\":\"file\""));
}

#[test]
fn test_opencode_model_payload_shape() {
    let model = crate::ai::AiModelSelection {
        provider_id: "openrouter".to_string(),
        model_id: "glm-5".to_string(),
    };
    let payload = OpenCodeClient::opencode_model_payload(&model);
    assert!(payload.is_object());
    assert_eq!(payload["providerID"], "openrouter");
    assert_eq!(payload["modelID"], "glm-5");
}

#[test]
fn test_bus_event_message_part_updated() {
    let json = r#"{"type":"message.part.updated","properties":{"part":{"id":"p1","sessionID":"s1","messageID":"m1","type":"text","text":"Hello World"},"delta":"Hello World"}}"#;
    let event: BusEvent = serde_json::from_str(json).unwrap();
    assert_eq!(event.event_type, "message.part.updated");
    let part = event.properties.get("part").unwrap();
    assert_eq!(part.get("type").unwrap().as_str().unwrap(), "text");
    assert_eq!(
        event.properties.get("delta").unwrap().as_str().unwrap(),
        "Hello World"
    );
}

#[test]
fn test_part_envelope_file_fields() {
    let json = r#"{
            "id":"p_file_1",
            "type":"file",
            "mime":"image/png",
            "filename":"image.png",
            "url":"data:image/png;base64,AAA"
        }"#;
    let part: crate::ai::opencode::protocol::PartEnvelope = serde_json::from_str(json).unwrap();
    assert_eq!(part.part_type, "file");
    assert_eq!(part.mime.as_deref(), Some("image/png"));
    assert_eq!(part.filename.as_deref(), Some("image.png"));
    assert_eq!(part.url.as_deref(), Some("data:image/png;base64,AAA"));
}

#[test]
fn test_bus_event_session_status() {
    let json = r#"{"type":"session.status","properties":{"ses_123":{"type":"idle"}}}"#;
    let event: BusEvent = serde_json::from_str(json).unwrap();
    assert_eq!(event.event_type, "session.status");
    let status = event.properties.get("ses_123").unwrap();
    assert_eq!(status.get("type").unwrap().as_str().unwrap(), "idle");
}

#[test]
fn test_bus_event_heartbeat() {
    let json = r#"{"type":"server.heartbeat","properties":{}}"#;
    let event: BusEvent = serde_json::from_str(json).unwrap();
    assert_eq!(event.event_type, "server.heartbeat");
}

#[test]
fn test_infer_image_extension() {
    assert_eq!(
        crate::ai::opencode::attachment::infer_image_extension("photo.jpeg", "image/png"),
        "jpg"
    );
    assert_eq!(
        crate::ai::opencode::attachment::infer_image_extension("photo.png", "image/jpeg"),
        "png"
    );
    assert_eq!(
        crate::ai::opencode::attachment::infer_image_extension("photo", "image/webp"),
        "webp"
    );
    assert_eq!(
        crate::ai::opencode::attachment::infer_image_extension(
            "photo.unknown",
            "application/octet-stream"
        ),
        "bin"
    );
}

#[test]
fn test_image_part_url_for_opencode_prefers_file_url() {
    let image = crate::ai::AiImagePart {
        filename: "clipboard_test.jpg".to_string(),
        mime: "image/jpeg".to_string(),
        data: vec![0xFF, 0xD8, 0xFF, 0xD9],
    };

    let url = crate::ai::opencode::attachment::image_part_url_for_opencode(&image);
    assert!(url.starts_with("file://") || url.starts_with("data:image/jpeg;base64,"));
}

#[test]
fn test_session_list_response() {
    let json = r#"{"sessions":[{"id":"s1","title":"Session 1","directory":"/a","time":{"created":1,"updated":1000}},{"id":"s2","title":"Session 2","directory":"/b","time":{"created":2,"updated":2000}}]}"#;
    let list: SessionListResponse = serde_json::from_str(json).unwrap();
    assert_eq!(list.sessions.len(), 2);
    assert_eq!(list.sessions[0].id, "s1");
    assert_eq!(list.sessions[1].title, "Session 2");
    assert_eq!(list.sessions[1].effective_updated_at(), 2000);
}

#[test]
fn test_error_display() {
    let err = OpenCodeError::ServerError {
        status: 500,
        message: "Internal Server Error".to_string(),
    };
    assert_eq!(err.to_string(), "Server error: 500 - Internal Server Error");

    let json_err =
        OpenCodeError::JsonError(serde_json::from_str::<serde_json::Value>("invalid").unwrap_err());
    assert!(json_err.to_string().contains("JSON error"));
}
