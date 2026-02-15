use axum::extract::ws::WebSocket;
use std::path::PathBuf;
use tracing::{debug, info, warn};

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, RemoteSubscriberDetail, ServerMessage};
use crate::server::ws::{
    ack_terminal_output, send_message, subscribe_terminal, unsubscribe_terminal,
};

/// 处理终端相关的客户端消息
pub async fn handle_terminal_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        // v0/v1.1: Terminal data plane with optional term_id
        ClientMessage::Input { data, term_id } => {
            debug!(
                "Input received: term_id={:?}, data_len={}",
                term_id,
                data.len()
            );

            let mut reg = ctx.terminal_registry.lock().await;
            let resolved_id = reg.resolve_term_id(term_id.as_deref());
            debug!(
                "Resolved term_id: {:?}, available_terms: {:?}",
                resolved_id,
                reg.term_ids()
            );

            if let Some(id) = resolved_id {
                debug!("Writing input to PTY: term_id={}", id);
                reg.write_input(&id, data)
                    .map_err(|e| format!("Write error: {}", e))?;
                debug!("Input written successfully");
            } else if term_id.is_some() {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "term_not_found".to_string(),
                        message: format!("Terminal '{}' not found", term_id.as_ref().unwrap()),
                    },
                )
                .await?;
            } else {
                debug!("No term_id provided and no default terminal");
            }
            Ok(true)
        }

        ClientMessage::Resize {
            cols,
            rows,
            term_id,
        } => {
            let reg = ctx.terminal_registry.lock().await;
            let resolved_id = reg.resolve_term_id(term_id.as_deref());

            if let Some(id) = resolved_id {
                reg.resize(&id, *cols, *rows)
                    .map_err(|e| format!("Resize error: {}", e))?;
            }
            Ok(true)
        }

        ClientMessage::SpawnTerminal { cwd } => {
            let cwd_path = PathBuf::from(&cwd);
            if !cwd_path.exists() {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "invalid_path".to_string(),
                        message: format!("Path '{}' does not exist", cwd),
                    },
                )
                .await?;
                return Ok(true);
            }

            let (session_id, shell_name) = {
                let mut reg = ctx.terminal_registry.lock().await;
                reg.spawn(
                    Some(cwd_path.clone()),
                    None,
                    None,
                    ctx.scrollback_tx.clone(),
                    None,
                    None,
                    None,
                    None,
                )
                .map_err(|e| format!("Spawn error: {}", e))?
            };

            // 自动订阅新创建的终端
            subscribe_terminal(
                &session_id,
                &ctx.terminal_registry,
                &ctx.subscribed_terms,
                &ctx.agg_tx,
            )
            .await;

            // 远程连接：注册远程订阅
            if ctx.conn_meta.is_remote {
                let mut rsub = ctx.remote_sub_registry.lock().await;
                rsub.subscribe(
                    &session_id,
                    ctx.conn_meta.remote_subscriber_id(),
                    ctx.conn_meta.device_name.as_deref().unwrap_or("Unknown"),
                );
            }

            info!(
                cwd = %cwd,
                term_id = %session_id,
                "Terminal spawned with custom cwd"
            );

            send_message(
                socket,
                &ServerMessage::TerminalSpawned {
                    session_id,
                    shell: shell_name,
                    cwd: cwd.clone(),
                },
            )
            .await?;
            Ok(true)
        }

        ClientMessage::KillTerminal => {
            // 关闭默认终端
            let term_id = {
                let reg = ctx.terminal_registry.lock().await;
                reg.resolve_term_id(None)
            };

            if let Some(id) = term_id {
                unsubscribe_terminal(&id, &ctx.subscribed_terms).await;
                // 清理远程订阅
                {
                    let mut rsub = ctx.remote_sub_registry.lock().await;
                    rsub.unsubscribe_term(&id);
                }
                let mut reg = ctx.terminal_registry.lock().await;
                reg.close(&id);
                drop(reg);

                info!(term_id = %id, "Terminal killed by client request");
                send_message(socket, &ServerMessage::TerminalKilled { session_id: id }).await?;
            }
            Ok(true)
        }

        // v1.2: Multi-workspace extension
        ClientMessage::TermCreate {
            project,
            workspace,
            cols,
            rows,
            name,
            icon,
        } => {
            info!(
                project = %project,
                workspace = %workspace,
                "TermCreate request received"
            );

            match crate::server::context::resolve_workspace(&ctx.app_state, project, workspace)
                .await
            {
                Ok(ws_ctx) => {
                    let (term_id, shell_name) = {
                        let mut reg = ctx.terminal_registry.lock().await;
                        reg.spawn(
                            Some(ws_ctx.root_path.clone()),
                            Some(project.clone()),
                            Some(workspace.clone()),
                            ctx.scrollback_tx.clone(),
                            *cols,
                            *rows,
                            name.clone(),
                            icon.clone(),
                        )
                        .map_err(|e| format!("Spawn error: {}", e))?
                    };

                    // 自动订阅新创建的终端
                    subscribe_terminal(
                        &term_id,
                        &ctx.terminal_registry,
                        &ctx.subscribed_terms,
                        &ctx.agg_tx,
                    )
                    .await;

                    // 远程连接：注册远程订阅
                    if ctx.conn_meta.is_remote {
                        let subscriber_id = ctx.conn_meta.remote_subscriber_id();
                        info!(
                            term_id = %term_id,
                            subscriber_id = %subscriber_id,
                            device_name = ?ctx.conn_meta.device_name,
                            "Registering remote subscription for new terminal"
                        );
                        let mut rsub = ctx.remote_sub_registry.lock().await;
                        rsub.subscribe(
                            &term_id,
                            subscriber_id,
                            ctx.conn_meta.device_name.as_deref().unwrap_or("Unknown"),
                        );
                    } else {
                        debug!(
                            term_id = %term_id,
                            conn_id = %ctx.conn_meta.conn_id,
                            "Local connection created terminal, skipping remote subscription"
                        );
                    }

                    info!(
                        project = %project,
                        workspace = %workspace,
                        term_id = %term_id,
                        "New terminal created in workspace"
                    );

                    send_message(
                        socket,
                        &ServerMessage::TermCreated {
                            term_id,
                            project: project.clone(),
                            workspace: workspace.clone(),
                            cwd: ws_ctx.root_path.to_string_lossy().to_string(),
                            shell: shell_name,
                            name: name.clone(),
                            icon: icon.clone(),
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                }
            }
            Ok(true)
        }

        ClientMessage::TermList => {
            let reg = ctx.terminal_registry.lock().await;
            let mut items = reg.list();
            drop(reg);

            // 填充远程订阅者信息
            let rsub = ctx.remote_sub_registry.lock().await;
            for item in &mut items {
                let subs = rsub.get_subscribers(&item.term_id);
                item.remote_subscribers = subs
                    .into_iter()
                    .map(|s| RemoteSubscriberDetail {
                        device_name: s.device_name,
                        conn_id: s.conn_id,
                    })
                    .collect();
            }
            drop(rsub);

            // 远程连接只返回自己订阅的终端，避免影响其他设备
            if ctx.conn_meta.is_remote {
                let my_subscriber_id = ctx.conn_meta.remote_subscriber_id();
                items.retain(|item| {
                    item.remote_subscribers
                        .iter()
                        .any(|s| s.conn_id == my_subscriber_id)
                });
            }

            let remote_count: usize = items.iter().map(|i| i.remote_subscribers.len()).sum();
            info!(
                total_terminals = items.len(),
                remote_subscriber_count = remote_count,
                conn_id = %ctx.conn_meta.conn_id,
                is_remote = ctx.conn_meta.is_remote,
                "TermList response: {} terminals, {} remote subscribers",
                items.len(),
                remote_count
            );

            send_message(socket, &ServerMessage::TermList { items }).await?;
            Ok(true)
        }

        ClientMessage::TermClose { term_id } => {
            unsubscribe_terminal(term_id, &ctx.subscribed_terms).await;
            // 清理该终端的所有远程订阅
            {
                let mut rsub = ctx.remote_sub_registry.lock().await;
                rsub.unsubscribe_term(term_id);
            }
            let closed = {
                let mut reg = ctx.terminal_registry.lock().await;
                reg.close(term_id)
            };

            if closed {
                info!(term_id = %term_id, "Terminal closed by client request");
                send_message(
                    socket,
                    &ServerMessage::TermClosed {
                        term_id: term_id.clone(),
                    },
                )
                .await?;
            } else {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "term_not_found".to_string(),
                        message: format!("Terminal '{}' not found", term_id),
                    },
                )
                .await?;
            }
            Ok(true)
        }

        ClientMessage::TermFocus { term_id } => {
            tracing::debug!(
                term_id = %term_id,
                "Client focused terminal"
            );
            Ok(true)
        }

        // v1.27: Terminal persistence — 重连附着
        ClientMessage::TermAttach { term_id } => {
            info!(term_id = %term_id, "TermAttach request received");

            let reg = ctx.terminal_registry.lock().await;
            if let Some((project, workspace, cwd, shell, name, icon)) = reg.get_info(term_id) {
                let scrollback = reg.get_scrollback(term_id).unwrap_or_default();
                drop(reg);

                // 订阅终端输出
                subscribe_terminal(
                    term_id,
                    &ctx.terminal_registry,
                    &ctx.subscribed_terms,
                    &ctx.agg_tx,
                )
                .await;

                // 远程连接：注册远程订阅
                if ctx.conn_meta.is_remote {
                    let mut rsub = ctx.remote_sub_registry.lock().await;
                    rsub.subscribe(
                        term_id,
                        ctx.conn_meta.remote_subscriber_id(),
                        ctx.conn_meta.device_name.as_deref().unwrap_or("Unknown"),
                    );
                }

                send_message(
                    socket,
                    &ServerMessage::TermAttached {
                        term_id: term_id.clone(),
                        project,
                        workspace,
                        cwd,
                        shell,
                        scrollback,
                        name,
                        icon,
                    },
                )
                .await?;
            } else {
                drop(reg);
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "term_not_found".to_string(),
                        message: format!("Terminal '{}' not found (may have exited)", term_id),
                    },
                )
                .await?;
            }
            Ok(true)
        }

        // v1.38: Terminal detach — 仅取消本连接的输出订阅，不关闭 PTY
        ClientMessage::TermDetach { term_id } => {
            info!(term_id = %term_id, "TermDetach request received");
            unsubscribe_terminal(term_id, &ctx.subscribed_terms).await;
            Ok(true)
        }

        // v1.28: Terminal output flow control ACK
        ClientMessage::TermOutputAck { term_id, bytes } => {
            ack_terminal_output(term_id, *bytes, &ctx.subscribed_terms).await;
            Ok(true)
        }

        // v1.39: iOS 剪贴板图片上传 → 转 JPG → 写入 macOS 系统剪贴板
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

        // Not a terminal message
        _ => Ok(false),
    }
}

/// 将图片数据解码 → 转 JPEG → 通过 osascript 写入 macOS 系统剪贴板
async fn handle_clipboard_image_upload(image_data: &[u8]) -> Result<(), String> {
    use image::ImageReader;
    use std::io::Cursor;

    // 1. 解码输入图片
    let reader = ImageReader::new(Cursor::new(image_data))
        .with_guessed_format()
        .map_err(|e| format!("无法识别图片格式: {}", e))?;
    let img = reader
        .decode()
        .map_err(|e| format!("图片解码失败: {}", e))?;

    // 2. 编码为 JPEG（质量 85）
    let mut jpg_buf = Cursor::new(Vec::new());
    img.write_to(&mut jpg_buf, image::ImageFormat::Jpeg)
        .map_err(|e| format!("JPEG 编码失败: {}", e))?;
    let jpg_data = jpg_buf.into_inner();

    // 3. 写入临时文件
    let temp_path = std::env::temp_dir().join("tidyflow_clipboard.jpg");
    tokio::fs::write(&temp_path, &jpg_data)
        .await
        .map_err(|e| format!("写入临时文件失败: {}", e))?;

    // 4. 通过 osascript 设置 macOS 系统剪贴板
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

    // 5. 清理临时文件（忽略错误）
    let _ = tokio::fs::remove_file(&temp_path).await;

    Ok(())
}
