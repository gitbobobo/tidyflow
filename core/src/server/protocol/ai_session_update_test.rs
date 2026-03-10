use super::ai::{AiSessionCacheOpInfo, MessageInfo, PartInfo};
use super::ServerMessage;

#[test]
fn ai_session_messages_update_ops_mode_codec_roundtrip() {
    let message = ServerMessage::AISessionMessagesUpdate {
        project_name: "p".to_string(),
        workspace_name: "w".to_string(),
        ai_tool: "codex".to_string(),
        session_id: "s1".to_string(),
        from_revision: 6,
        to_revision: 7,
        is_streaming: true,
        selection_hint: None,
        messages: None,
        ops: Some(vec![AiSessionCacheOpInfo::PartDelta {
            message_id: "m1".to_string(),
            part_id: "p1".to_string(),
            part_type: "text".to_string(),
            field: "text".to_string(),
            delta: "hello".to_string(),
        }]),
    };

    let encoded = rmp_serde::to_vec_named(&message).expect("encode ai_session_messages_update");
    let decoded: ServerMessage =
        rmp_serde::from_slice(&encoded).expect("decode ai_session_messages_update");

    match decoded {
        ServerMessage::AISessionMessagesUpdate {
            from_revision,
            to_revision,
            is_streaming,
            messages,
            ops,
            ..
        } => {
            assert_eq!(from_revision, 6);
            assert_eq!(to_revision, 7);
            assert!(is_streaming);
            assert!(messages.is_none());
            let ops = ops.expect("ops should exist");
            assert_eq!(ops.len(), 1);
            match &ops[0] {
                AiSessionCacheOpInfo::PartDelta { delta, .. } => assert_eq!(delta, "hello"),
                other => panic!("unexpected op variant: {:?}", other),
            }
        }
        other => panic!("unexpected message variant: {:?}", other),
    }
}

#[test]
fn ai_session_messages_update_messages_mode_codec_roundtrip() {
    let message = ServerMessage::AISessionMessagesUpdate {
        project_name: "p".to_string(),
        workspace_name: "w".to_string(),
        ai_tool: "codex".to_string(),
        session_id: "s2".to_string(),
        from_revision: 10,
        to_revision: 11,
        is_streaming: false,
        selection_hint: None,
        messages: Some(vec![MessageInfo {
            id: "m1".to_string(),
            role: "assistant".to_string(),
            created_at: None,
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts: vec![PartInfo {
                id: "p1".to_string(),
                part_type: "text".to_string(),
                text: Some("snapshot".to_string()),
                mime: None,
                filename: None,
                url: None,
                synthetic: None,
                ignored: None,
                source: None,
                tool_name: None,
                tool_call_id: None,
                tool_kind: None,
                tool_view: None,
            }],
        }]),
        ops: None,
    };

    let encoded = rmp_serde::to_vec_named(&message).expect("encode ai_session_messages_update");
    let decoded: ServerMessage =
        rmp_serde::from_slice(&encoded).expect("decode ai_session_messages_update");

    match decoded {
        ServerMessage::AISessionMessagesUpdate {
            from_revision,
            to_revision,
            is_streaming,
            messages,
            ops,
            ..
        } => {
            assert_eq!(from_revision, 10);
            assert_eq!(to_revision, 11);
            assert!(!is_streaming);
            assert!(ops.is_none());
            let messages = messages.expect("messages should exist");
            assert_eq!(messages.len(), 1);
            assert_eq!(messages[0].parts.len(), 1);
            assert_eq!(messages[0].parts[0].text.as_deref(), Some("snapshot"));
        }
        other => panic!("unexpected message variant: {:?}", other),
    }
}
