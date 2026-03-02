use crate::ai::acp::client::AcpClient;
use crate::ai::codex::manager::AcpContentEncodingMode;
use crate::ai::{AiAudioPart, AiImagePart};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::ImageReader;
use serde_json::Value;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use tracing::{debug, warn};
use url::Url;

#[derive(Debug, Clone)]
struct ResolvedPromptFileRef {
    original: String,
    path: PathBuf,
    uri: String,
    name: String,
    mime: String,
}

const ACP_IMAGE_BASE64_MAX_BYTES: usize = 64 * 1024;

fn strip_file_ref_location_suffix(file_ref: &str) -> String {
    let trimmed = file_ref.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if let Some((head, tail)) = trimmed.rsplit_once(':') {
        if tail.chars().all(|ch| ch.is_ascii_digit()) {
            if let Some((head2, tail2)) = head.rsplit_once(':') {
                if tail2.chars().all(|ch| ch.is_ascii_digit()) {
                    return head2.to_string();
                }
            }
            return head.to_string();
        }
    }
    trimmed.to_string()
}

fn normalize_attachment_mime(raw: &str) -> String {
    let mime = raw.trim().to_ascii_lowercase();
    if mime.is_empty() {
        "application/octet-stream".to_string()
    } else {
        mime
    }
}

fn mime_from_path(path: &Path) -> String {
    mime_guess::from_path(path)
        .first_or_octet_stream()
        .essence_str()
        .to_string()
}

fn mime_is_text(mime: &str) -> bool {
    let normalized = mime.trim().to_ascii_lowercase();
    normalized.starts_with("text/")
        || normalized.ends_with("+json")
        || normalized.ends_with("+xml")
        || matches!(
            normalized.as_str(),
            "application/json"
                | "application/xml"
                | "application/yaml"
                | "application/x-yaml"
                | "application/toml"
                | "application/javascript"
                | "application/x-javascript"
                | "application/typescript"
                | "application/sql"
        )
}

fn decode_utf8_text(bytes: &[u8]) -> Option<String> {
    if bytes.contains(&0) {
        return None;
    }
    String::from_utf8(bytes.to_vec()).ok()
}

fn resolve_prompt_file_ref(directory: &str, file_ref: &str) -> Option<ResolvedPromptFileRef> {
    let normalized_ref = strip_file_ref_location_suffix(file_ref);
    if normalized_ref.trim().is_empty() {
        return None;
    }

    if let Ok(url) = Url::parse(&normalized_ref) {
        if !url.scheme().eq_ignore_ascii_case("file") {
            return None;
        }
        let path = url.to_file_path().ok()?;
        let uri = Url::from_file_path(&path).ok()?.to_string();
        let name = path
            .file_name()
            .map(|v| v.to_string_lossy().to_string())
            .unwrap_or_else(|| normalized_ref.clone());
        let mime = mime_from_path(&path);
        return Some(ResolvedPromptFileRef {
            original: file_ref.to_string(),
            path,
            uri,
            name,
            mime,
        });
    }

    let input_path = Path::new(&normalized_ref);
    let path = if input_path.is_absolute() {
        input_path.to_path_buf()
    } else {
        PathBuf::from(directory).join(input_path)
    };

    let uri = Url::from_file_path(&path).ok()?.to_string();
    let name = path
        .file_name()
        .map(|v| v.to_string_lossy().to_string())
        .unwrap_or_else(|| normalized_ref.clone());
    let mime = mime_from_path(&path);
    Some(ResolvedPromptFileRef {
        original: file_ref.to_string(),
        path,
        uri,
        name,
        mime,
    })
}

fn build_embedded_resource_part(
    file_ref: &ResolvedPromptFileRef,
    embed_text_limit_bytes: usize,
    embed_blob_limit_bytes: usize,
) -> Result<Option<Value>, String> {
    let metadata = std::fs::metadata(&file_ref.path)
        .map_err(|e| format!("读取文件元数据失败：{} ({})", file_ref.path.display(), e))?;
    let size = metadata.len() as usize;

    let mime = normalize_attachment_mime(&file_ref.mime);
    let declared_text = mime_is_text(&mime);
    if declared_text && size > embed_text_limit_bytes {
        return Ok(None);
    }
    if size > embed_blob_limit_bytes {
        return Ok(None);
    }

    let bytes = std::fs::read(&file_ref.path)
        .map_err(|e| format!("读取文件内容失败：{} ({})", file_ref.path.display(), e))?;
    let is_text = declared_text || decode_utf8_text(&bytes).is_some();
    if is_text {
        if bytes.len() > embed_text_limit_bytes {
            return Ok(None);
        }
        if let Some(text) = decode_utf8_text(&bytes) {
            return Ok(Some(AcpClient::build_prompt_resource_text_part(
                file_ref.uri.clone(),
                file_ref.name.clone(),
                mime,
                text,
            )));
        }
    }

    if bytes.len() > embed_blob_limit_bytes {
        return Ok(None);
    }

    Ok(Some(AcpClient::build_prompt_resource_blob_part(
        file_ref.uri.clone(),
        file_ref.name.clone(),
        mime,
        BASE64.encode(bytes),
    )))
}

fn base64_len(bytes: &[u8]) -> usize {
    bytes.len().div_ceil(3) * 4
}

fn encode_jpeg_with_quality(img: &image::DynamicImage, quality: u8) -> Result<Vec<u8>, String> {
    let mut out = Vec::<u8>::new();
    let mut encoder = JpegEncoder::new_with_quality(&mut out, quality);
    encoder
        .encode_image(img)
        .map_err(|e| format!("JPEG 编码失败：{}", e))?;
    Ok(out)
}

fn ensure_image_base64_under_limit(
    mime: &str,
    data: &[u8],
) -> Result<Option<(String, String)>, String> {
    if base64_len(data) <= ACP_IMAGE_BASE64_MAX_BYTES {
        return Ok(Some((mime.to_string(), BASE64.encode(data))));
    }

    let reader = ImageReader::new(Cursor::new(data))
        .with_guessed_format()
        .map_err(|e| format!("图片格式识别失败：{}", e))?;
    let decoded = reader
        .decode()
        .map_err(|e| format!("图片解码失败：{}", e))?;
    let (orig_w, orig_h) = (decoded.width(), decoded.height());
    if orig_w == 0 || orig_h == 0 {
        return Ok(None);
    }

    let scales = [1.0_f32, 0.85, 0.7, 0.55, 0.4, 0.3, 0.2];
    let qualities = [82_u8, 70, 58, 46, 36, 28];

    for scale in scales {
        let width = ((orig_w as f32 * scale).round() as u32).max(1);
        let height = ((orig_h as f32 * scale).round() as u32).max(1);
        let resized = if width == orig_w && height == orig_h {
            decoded.clone()
        } else {
            decoded.resize(width, height, FilterType::Lanczos3)
        };

        for quality in qualities {
            let jpg = match encode_jpeg_with_quality(&resized, quality) {
                Ok(bytes) => bytes,
                Err(_) => continue,
            };
            if base64_len(&jpg) <= ACP_IMAGE_BASE64_MAX_BYTES {
                return Ok(Some(("image/jpeg".to_string(), BASE64.encode(jpg))));
            }
        }
    }

    Ok(None)
}

pub(crate) fn compose_prompt_parts(
    directory: &str,
    message: &str,
    file_refs: Option<Vec<String>>,
    image_parts: Option<Vec<AiImagePart>>,
    audio_parts: Option<Vec<AiAudioPart>>,
    encoding_mode: AcpContentEncodingMode,
    supports_image: bool,
    supports_audio: bool,
    supports_resource: bool,
    supports_resource_link: bool,
    embed_text_limit_bytes: usize,
    embed_blob_limit_bytes: usize,
) -> Vec<Value> {
    let mut prompt_parts = Vec::<Value>::new();
    let mut fallback_blocks = Vec::<String>::new();
    let mut text_body = message.to_string();

    if let Some(files) = file_refs {
        if !files.is_empty() {
            let mut unresolved = Vec::<String>::new();
            for file_ref in files {
                let Some(resolved) = resolve_prompt_file_ref(directory, &file_ref) else {
                    unresolved.push(file_ref);
                    continue;
                };

                let mut encoded = false;
                if supports_resource {
                    match build_embedded_resource_part(
                        &resolved,
                        embed_text_limit_bytes,
                        embed_blob_limit_bytes,
                    ) {
                        Ok(Some(resource_part)) => {
                            prompt_parts.push(resource_part);
                            encoded = true;
                        }
                        Ok(None) => {
                            debug!(
                                "ACP resource embed exceeded limit, fallback to resource_link: {}",
                                resolved.path.display()
                            );
                        }
                        Err(err) => {
                            warn!(
                                "ACP resource embed failed, fallback to resource_link: path={}, error={}",
                                resolved.path.display(),
                                err
                            );
                        }
                    }
                }
                if !encoded && supports_resource_link {
                    prompt_parts.push(AcpClient::build_prompt_resource_link_part(
                        encoding_mode,
                        resolved.uri.clone(),
                        resolved.name.clone(),
                        Some(resolved.mime.clone()),
                    ));
                    encoded = true;
                }
                if !encoded {
                    unresolved.push(resolved.original);
                }
            }
            if !unresolved.is_empty() {
                fallback_blocks.push(format!("文件引用：\n{}", unresolved.join("\n")));
            }
        }
    }

    if let Some(images) = image_parts {
        if !images.is_empty() {
            if supports_image {
                let mut unresolved_images = Vec::<String>::new();
                for img in images {
                    let mime = normalize_attachment_mime(&img.mime);
                    match ensure_image_base64_under_limit(&mime, &img.data) {
                        Ok(Some((final_mime, encoded))) => {
                            prompt_parts.push(AcpClient::build_prompt_image_part(
                                encoding_mode,
                                final_mime,
                                encoded,
                            ));
                        }
                        Ok(None) => {
                            warn!(
                                "ACP image dropped because base64 exceeds 64KB after optimization: filename={}, mime={}",
                                img.filename, mime
                            );
                            unresolved_images.push(format!("{} ({})", img.filename, img.mime));
                        }
                        Err(err) => {
                            warn!(
                                "ACP image optimization failed, fallback to text block: filename={}, mime={}, error={}",
                                img.filename, mime, err
                            );
                            unresolved_images.push(format!("{} ({})", img.filename, img.mime));
                        }
                    }
                }
                if !unresolved_images.is_empty() {
                    fallback_blocks.push(format!("图片附件：\n{}", unresolved_images.join("\n")));
                }
            } else {
                let names = images
                    .iter()
                    .map(|img| format!("{} ({})", img.filename, img.mime))
                    .collect::<Vec<_>>()
                    .join("\n");
                fallback_blocks.push(format!("图片附件：\n{}", names));
            }
        }
    }

    if let Some(audios) = audio_parts {
        if !audios.is_empty() {
            if supports_audio {
                for audio in audios {
                    let mime = normalize_attachment_mime(&audio.mime);
                    prompt_parts.push(AcpClient::build_prompt_audio_part(
                        encoding_mode,
                        mime,
                        BASE64.encode(audio.data),
                    ));
                }
            } else {
                let names = audios
                    .iter()
                    .map(|audio| format!("{} ({})", audio.filename, audio.mime))
                    .collect::<Vec<_>>()
                    .join("\n");
                fallback_blocks.push(format!("音频附件：\n{}", names));
            }
        }
    }

    if !fallback_blocks.is_empty() {
        if !text_body.trim().is_empty() {
            text_body.push_str("\n\n");
        }
        text_body.push_str(&fallback_blocks.join("\n\n"));
    }

    if !text_body.trim().is_empty() || prompt_parts.is_empty() {
        prompt_parts.insert(0, AcpClient::build_prompt_text_part(text_body));
    }
    prompt_parts
}
