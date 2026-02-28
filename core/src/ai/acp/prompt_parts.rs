use crate::ai::codex::manager::AcpContentEncodingMode;
use serde_json::Value;

pub(crate) fn build_prompt_text_part(text: String) -> Value {
    serde_json::json!({
        "type": "text",
        "text": text
    })
}

pub(crate) fn build_prompt_image_part(
    mode: AcpContentEncodingMode,
    mime_type: String,
    data_base64: String,
) -> Value {
    match mode {
        AcpContentEncodingMode::New => build_prompt_image_part_new(mime_type, data_base64),
        AcpContentEncodingMode::Legacy | AcpContentEncodingMode::Unknown => {
            let data_url = format!("data:{};base64,{}", mime_type, data_base64);
            build_prompt_image_part_legacy(mime_type, data_url)
        }
    }
}

pub(crate) fn build_prompt_image_part_new(mime_type: String, data_base64: String) -> Value {
    serde_json::json!({
        "type": "image",
        "mimeType": mime_type,
        "data": data_base64,
    })
}

pub(crate) fn build_prompt_image_part_legacy(mime_type: String, data_url: String) -> Value {
    serde_json::json!({
        "type": "image",
        "mimeType": mime_type,
        "url": data_url,
    })
}

pub(crate) fn build_prompt_audio_part(
    mode: AcpContentEncodingMode,
    mime_type: String,
    data_base64: String,
) -> Value {
    match mode {
        AcpContentEncodingMode::New => build_prompt_audio_part_new(mime_type, data_base64),
        AcpContentEncodingMode::Legacy | AcpContentEncodingMode::Unknown => {
            let data_url = format!("data:{};base64,{}", mime_type, data_base64);
            build_prompt_audio_part_legacy(mime_type, data_url)
        }
    }
}

pub(crate) fn build_prompt_audio_part_new(mime_type: String, data_base64: String) -> Value {
    serde_json::json!({
        "type": "audio",
        "mimeType": mime_type,
        "data": data_base64,
    })
}

pub(crate) fn build_prompt_audio_part_legacy(mime_type: String, data_url: String) -> Value {
    serde_json::json!({
        "type": "audio",
        "mimeType": mime_type,
        "url": data_url,
    })
}

pub(crate) fn build_prompt_resource_text_part(
    uri: String,
    name: String,
    mime_type: String,
    text: String,
) -> Value {
    serde_json::json!({
        "type": "resource",
        "resource": {
            "uri": uri,
            "name": name,
            "mimeType": mime_type,
            "text": text,
        }
    })
}

pub(crate) fn build_prompt_resource_blob_part(
    uri: String,
    name: String,
    mime_type: String,
    blob_base64: String,
) -> Value {
    serde_json::json!({
        "type": "resource",
        "resource": {
            "uri": uri,
            "name": name,
            "mimeType": mime_type,
            "blob": blob_base64,
        }
    })
}

pub(crate) fn build_prompt_resource_link_part(
    mode: AcpContentEncodingMode,
    uri: String,
    name: String,
    mime_type: Option<String>,
) -> Value {
    match mode {
        AcpContentEncodingMode::New => build_prompt_resource_link_part_new(uri, name, mime_type),
        AcpContentEncodingMode::Legacy | AcpContentEncodingMode::Unknown => {
            build_prompt_resource_link_part_legacy(uri, name)
        }
    }
}

pub(crate) fn build_prompt_resource_link_part_new(
    uri: String,
    name: String,
    mime_type: Option<String>,
) -> Value {
    let mut payload = serde_json::json!({
        "type": "resource_link",
        "uri": uri,
        "name": name,
    });
    if let Some(mime_type) = mime_type.filter(|m| !m.trim().is_empty()) {
        payload["mimeType"] = Value::String(mime_type);
    }
    payload
}

pub(crate) fn build_prompt_resource_link_part_legacy(uri: String, name: String) -> Value {
    serde_json::json!({
        "type": "resource_link",
        "resource": {
            "uri": uri,
            "name": name,
        }
    })
}
