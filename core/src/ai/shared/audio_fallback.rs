use crate::ai::AiAudioPart;

pub fn append_audio_fallback_text(message: &str, audio_parts: Option<&[AiAudioPart]>) -> String {
    let Some(parts) = audio_parts else {
        return message.to_string();
    };
    if parts.is_empty() {
        return message.to_string();
    }

    let summary = parts
        .iter()
        .map(|part| format!("{} ({}, {}B)", part.filename, part.mime, part.data.len()))
        .collect::<Vec<_>>()
        .join("\n");

    if message.trim().is_empty() {
        format!(
            "音频附件（当前后端不支持音频直传，已降级为文本摘要）：\n{}",
            summary
        )
    } else {
        format!(
            "{}\n\n音频附件（当前后端不支持音频直传，已降级为文本摘要）：\n{}",
            message, summary
        )
    }
}
