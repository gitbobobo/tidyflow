use axum::extract::ws::WebSocket;
use tracing::{info, warn};

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

pub async fn handle_clipboard_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    _ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::ClipboardImageUpload { image_data } => {
            info!("ClipboardImageUpload: {} bytes", image_data.len());
            match handle_clipboard_image_upload(image_data).await {
                Ok(()) => {
                    send_message(
                        socket,
                        &ServerMessage::ClipboardImageSet {
                            ok: true,
                            message: None,
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    warn!("ClipboardImageUpload failed: {}", e);
                    send_message(
                        socket,
                        &ServerMessage::ClipboardImageSet {
                            ok: false,
                            message: Some(e),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }
        _ => Ok(false),
    }
}

/// 将图片数据解码 → 转 JPEG → 通过 osascript 写入 macOS 系统剪贴板
async fn handle_clipboard_image_upload(image_data: &[u8]) -> Result<(), String> {
    use image::ImageReader;
    use std::io::Cursor;

    let reader = ImageReader::new(Cursor::new(image_data))
        .with_guessed_format()
        .map_err(|e| format!("无法识别图片格式: {}", e))?;
    let img = reader
        .decode()
        .map_err(|e| format!("图片解码失败: {}", e))?;

    let mut jpg_buf = Cursor::new(Vec::new());
    img.write_to(&mut jpg_buf, image::ImageFormat::Jpeg)
        .map_err(|e| format!("JPEG 编码失败: {}", e))?;
    let jpg_data = jpg_buf.into_inner();

    let temp_path = std::env::temp_dir().join("tidyflow_clipboard.jpg");
    tokio::fs::write(&temp_path, &jpg_data)
        .await
        .map_err(|e| format!("写入临时文件失败: {}", e))?;

    let script = format!(
        r#"use framework "AppKit"
set imageData to (current application's NSData's dataWithContentsOfFile:"{}")
set image to (current application's NSImage's alloc()'s initWithData:imageData)
set pb to current application's NSPasteboard's generalPasteboard()
pb's clearContents()
pb's writeObjects:{{image}}"#,
        temp_path.display()
    );

    let output = tokio::process::Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .output()
        .await
        .map_err(|e| format!("osascript 执行失败: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("osascript 错误: {}", stderr.trim()));
    }

    let _ = tokio::fs::remove_file(&temp_path).await;

    Ok(())
}
