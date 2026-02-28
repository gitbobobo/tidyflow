use crate::ai::shared::audio_fallback::append_audio_fallback_text as shared_append_audio_fallback_text;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static IMAGE_FILE_SEQ: AtomicU64 = AtomicU64::new(0);

fn safe_file_stem(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    let trimmed = out.trim_matches('_');
    if trimmed.is_empty() {
        "image".to_string()
    } else {
        trimmed.to_string()
    }
}

pub(crate) fn infer_image_extension(filename: &str, mime: &str) -> &'static str {
    if let Some(ext) = Path::new(filename).extension().and_then(|s| s.to_str()) {
        if !ext.is_empty() && ext.len() <= 8 && ext.chars().all(|c| c.is_ascii_alphanumeric()) {
            match ext.to_ascii_lowercase().as_str() {
                "jpeg" | "jpg" => return "jpg",
                "png" => return "png",
                "webp" => return "webp",
                "gif" => return "gif",
                "heic" => return "heic",
                "heif" => return "heif",
                _ => {}
            }
        }
    }

    match mime {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "image/heic" => "heic",
        "image/heif" => "heif",
        _ => "bin",
    }
}

pub(crate) fn image_part_url_for_opencode(image: &crate::ai::AiImagePart) -> String {
    // 优先落临时文件并传 file://，避免工具链对超长 data URL 解析失败。
    let ext = {
        let inferred = infer_image_extension(&image.filename, &image.mime);
        if inferred.is_empty() {
            "bin"
        } else {
            inferred
        }
    };
    let stem = Path::new(&image.filename)
        .file_stem()
        .and_then(|s| s.to_str())
        .map(safe_file_stem)
        .unwrap_or_else(|| "image".to_string());
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    let seq = IMAGE_FILE_SEQ.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join("tidyflow-ai-images");
    let file_name = format!("{}-{}-{}.{}", stem, ts, seq, ext);
    let path = dir.join(file_name);

    if std::fs::create_dir_all(&dir).is_ok() && std::fs::write(&path, &image.data).is_ok() {
        if let Ok(url) = reqwest::Url::from_file_path(&path) {
            return url.to_string();
        }
    }

    // 兜底：保持旧行为，避免文件写入失败时消息直接丢失。
    let encoded = BASE64.encode(&image.data);
    format!("data:{};base64,{}", image.mime, encoded)
}

pub(crate) fn append_audio_fallback_text(
    message: &str,
    audio_parts: Option<&[crate::ai::AiAudioPart]>,
) -> String {
    shared_append_audio_fallback_text(message, audio_parts)
}
