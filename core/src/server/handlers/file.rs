use axum::extract::ws::WebSocket;
use std::path::PathBuf;

use crate::server::file_api::{self, FileApiError};
use crate::server::file_index;
use crate::server::protocol::{ClientMessage, FileEntryInfo, ServerMessage};
use crate::server::ws::{send_message, SharedAppState};
use crate::workspace::state::Project;

/// 获取工作空间的根路径，支持 "default" 虚拟工作空间
/// 如果 workspace 是 "default"，返回项目根目录
fn get_workspace_root(project: &Project, workspace: &str) -> Option<PathBuf> {
    if workspace == "default" {
        Some(project.root_path.clone())
    } else {
        project
            .get_workspace(workspace)
            .map(|w| w.worktree_path.clone())
    }
}

/// Convert FileApiError to error response tuple
fn file_error_to_response(e: &FileApiError) -> (String, String) {
    match e {
        FileApiError::PathEscape => ("path_escape".to_string(), e.to_string()),
        FileApiError::PathTooLong => ("path_too_long".to_string(), e.to_string()),
        FileApiError::FileNotFound => ("file_not_found".to_string(), e.to_string()),
        FileApiError::FileTooLarge => ("file_too_large".to_string(), e.to_string()),
        FileApiError::InvalidUtf8 => ("invalid_utf8".to_string(), e.to_string()),
        FileApiError::IoError(_) => ("io_error".to_string(), e.to_string()),
        FileApiError::TargetExists => ("target_exists".to_string(), e.to_string()),
        FileApiError::InvalidName(_) => ("invalid_name".to_string(), e.to_string()),
        FileApiError::TrashError(_) => ("trash_error".to_string(), e.to_string()),
        FileApiError::MoveIntoSelf => ("move_into_self".to_string(), e.to_string()),
    }
}

/// 处理文件相关的客户端消息
pub async fn handle_file_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        // v1.3: File operations
        ClientMessage::FileList {
            project,
            workspace,
            path,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);

                        let path_str = if path.is_empty() {
                            ".".to_string()
                        } else {
                            path.clone()
                        };
                        match file_api::list_files(&root, &path_str) {
                            Ok(entries) => {
                                let items: Vec<FileEntryInfo> = entries
                                    .into_iter()
                                    .map(|e| FileEntryInfo {
                                        name: e.name,
                                        is_dir: e.is_dir,
                                        size: e.size,
                                        is_ignored: e.is_ignored,
                                        is_symlink: e.is_symlink,
                                    })
                                    .collect();
                                send_message(
                                    socket,
                                    &ServerMessage::FileListResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        path: path_str,
                                        items,
                                    },
                                )
                                .await?;
                            }
                            Err(e) => {
                                let (code, message) = file_error_to_response(&e);
                                send_message(socket, &ServerMessage::Error { code, message })
                                    .await?;
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            },
                        )
                        .await?;
                    }
                },
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        ClientMessage::FileRead {
            project,
            workspace,
            path,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);

                        match file_api::read_file(&root, path) {
                            Ok((content, size)) => {
                                send_message(
                                    socket,
                                    &ServerMessage::FileReadResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        path: path.clone(),
                                        content: content.into_bytes(),
                                        size,
                                    },
                                )
                                .await?;
                            }
                            Err(FileApiError::InvalidUtf8) => {
                                // 非 UTF-8 文件（如图片），回退到二进制读取
                                match file_api::read_file_binary(&root, path) {
                                    Ok((content, size)) => {
                                        send_message(
                                            socket,
                                            &ServerMessage::FileReadResult {
                                                project: project.clone(),
                                                workspace: workspace.clone(),
                                                path: path.clone(),
                                                content,
                                                size,
                                            },
                                        )
                                        .await?;
                                    }
                                    Err(e) => {
                                        let (code, message) = file_error_to_response(&e);
                                        send_message(socket, &ServerMessage::Error { code, message })
                                            .await?;
                                    }
                                }
                            }
                            Err(e) => {
                                let (code, message) = file_error_to_response(&e);
                                send_message(socket, &ServerMessage::Error { code, message })
                                    .await?;
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            },
                        )
                        .await?;
                    }
                },
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        ClientMessage::FileWrite {
            project,
            workspace,
            path,
            content,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => {
                    match get_workspace_root(p, workspace) {
                        Some(root) => {
                            drop(state);

                            // Decode UTF-8 content
                            match String::from_utf8(content.clone()) {
                                Ok(content_str) => {
                                    match file_api::write_file(&root, path, &content_str) {
                                        Ok(size) => {
                                            send_message(
                                                socket,
                                                &ServerMessage::FileWriteResult {
                                                    project: project.clone(),
                                                    workspace: workspace.clone(),
                                                    path: path.clone(),
                                                    success: true,
                                                    size,
                                                },
                                            )
                                            .await?;
                                        }
                                        Err(e) => {
                                            let (code, message) = file_error_to_response(&e);
                                            send_message(
                                                socket,
                                                &ServerMessage::Error { code, message },
                                            )
                                            .await?;
                                        }
                                    }
                                }
                                Err(_) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "invalid_utf8".to_string(),
                                            message: "Content is not valid UTF-8".to_string(),
                                        },
                                    )
                                    .await?;
                                }
                            }
                        }
                        None => {
                            send_message(
                                socket,
                                &ServerMessage::Error {
                                    code: "workspace_not_found".to_string(),
                                    message: format!("Workspace '{}' not found", workspace),
                                },
                            )
                            .await?;
                        }
                    }
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.4: File index for Quick Open
        ClientMessage::FileIndex { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => {
                    match get_workspace_root(p, workspace) {
                        Some(root) => {
                            drop(state);

                            // Run indexing in blocking task to avoid blocking async runtime
                            let result =
                                tokio::task::spawn_blocking(move || file_index::index_files(&root))
                                    .await;

                            match result {
                                Ok(Ok(index_result)) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::FileIndexResult {
                                            project: project.clone(),
                                            workspace: workspace.clone(),
                                            items: index_result.items,
                                            truncated: index_result.truncated,
                                        },
                                    )
                                    .await?;
                                }
                                Ok(Err(e)) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "io_error".to_string(),
                                            message: format!("Failed to index files: {}", e),
                                        },
                                    )
                                    .await?;
                                }
                                Err(e) => {
                                    send_message(
                                        socket,
                                        &ServerMessage::Error {
                                            code: "internal_error".to_string(),
                                            message: format!("Index task failed: {}", e),
                                        },
                                    )
                                    .await?;
                                }
                            }
                        }
                        None => {
                            send_message(
                                socket,
                                &ServerMessage::Error {
                                    code: "workspace_not_found".to_string(),
                                    message: format!("Workspace '{}' not found", workspace),
                                },
                            )
                            .await?;
                        }
                    }
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.23: File rename
        ClientMessage::FileRename {
            project,
            workspace,
            old_path,
            new_name,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);
                        match file_api::rename_file(&root, old_path, new_name) {
                            Ok(new_path) => {
                                send_message(
                                    socket,
                                    &ServerMessage::FileRenameResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        old_path: old_path.clone(),
                                        new_path,
                                        success: true,
                                        message: None,
                                    },
                                )
                                .await?;
                            }
                            Err(e) => {
                                let (_, message) = file_error_to_response(&e);
                                send_message(
                                    socket,
                                    &ServerMessage::FileRenameResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        old_path: old_path.clone(),
                                        new_path: String::new(),
                                        success: false,
                                        message: Some(message),
                                    },
                                )
                                .await?;
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::FileRenameResult {
                                project: project.clone(),
                                workspace: workspace.clone(),
                                old_path: old_path.clone(),
                                new_path: String::new(),
                                success: false,
                                message: Some("Workspace not found".to_string()),
                            },
                        )
                        .await?;
                    }
                },
                None => {
                    send_message(
                        socket,
                        &ServerMessage::FileRenameResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            old_path: old_path.clone(),
                            new_path: String::new(),
                            success: false,
                            message: Some("Project not found".to_string()),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.23: File delete
        ClientMessage::FileDelete {
            project,
            workspace,
            path,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);
                        match file_api::delete_file(&root, path) {
                            Ok(()) => {
                                send_message(
                                    socket,
                                    &ServerMessage::FileDeleteResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        path: path.clone(),
                                        success: true,
                                        message: None,
                                    },
                                )
                                .await?;
                            }
                            Err(e) => {
                                let (_, message) = file_error_to_response(&e);
                                send_message(
                                    socket,
                                    &ServerMessage::FileDeleteResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        path: path.clone(),
                                        success: false,
                                        message: Some(message),
                                    },
                                )
                                .await?;
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::FileDeleteResult {
                                project: project.clone(),
                                workspace: workspace.clone(),
                                path: path.clone(),
                                success: false,
                                message: Some("Workspace not found".to_string()),
                            },
                        )
                        .await?;
                    }
                },
                None => {
                    send_message(
                        socket,
                        &ServerMessage::FileDeleteResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            path: path.clone(),
                            success: false,
                            message: Some("Project not found".to_string()),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.24: File copy (使用绝对路径)
        ClientMessage::FileCopy {
            dest_project,
            dest_workspace,
            source_absolute_path,
            dest_dir,
        } => {
            let state = app_state.lock().await;
            match state.get_project(dest_project) {
                Some(p) => match get_workspace_root(p, dest_workspace) {
                    Some(root) => {
                        drop(state);
                        match file_api::copy_file_from_absolute(&root, source_absolute_path, dest_dir) {
                            Ok(dest_path) => {
                                send_message(
                                    socket,
                                    &ServerMessage::FileCopyResult {
                                        project: dest_project.clone(),
                                        workspace: dest_workspace.clone(),
                                        source_absolute_path: source_absolute_path.clone(),
                                        dest_path,
                                        success: true,
                                        message: None,
                                    },
                                )
                                .await?;
                            }
                            Err(e) => {
                                let (_, message) = file_error_to_response(&e);
                                send_message(
                                    socket,
                                    &ServerMessage::FileCopyResult {
                                        project: dest_project.clone(),
                                        workspace: dest_workspace.clone(),
                                        source_absolute_path: source_absolute_path.clone(),
                                        dest_path: String::new(),
                                        success: false,
                                        message: Some(message),
                                    },
                                )
                                .await?;
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::FileCopyResult {
                                project: dest_project.clone(),
                                workspace: dest_workspace.clone(),
                                source_absolute_path: source_absolute_path.clone(),
                                dest_path: String::new(),
                                success: false,
                                message: Some("Workspace not found".to_string()),
                            },
                        )
                        .await?;
                    }
                },
                None => {
                    send_message(
                        socket,
                        &ServerMessage::FileCopyResult {
                            project: dest_project.clone(),
                            workspace: dest_workspace.clone(),
                            source_absolute_path: source_absolute_path.clone(),
                            dest_path: String::new(),
                            success: false,
                            message: Some("Project not found".to_string()),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.25: File move (拖拽移动)
        ClientMessage::FileMove {
            project,
            workspace,
            old_path,
            new_dir,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);
                        match file_api::move_file(&root, old_path, new_dir) {
                            Ok(new_path) => {
                                send_message(
                                    socket,
                                    &ServerMessage::FileMoveResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        old_path: old_path.clone(),
                                        new_path,
                                        success: true,
                                        message: None,
                                    },
                                )
                                .await?;
                            }
                            Err(e) => {
                                let (_, message) = file_error_to_response(&e);
                                send_message(
                                    socket,
                                    &ServerMessage::FileMoveResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        old_path: old_path.clone(),
                                        new_path: String::new(),
                                        success: false,
                                        message: Some(message),
                                    },
                                )
                                .await?;
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::FileMoveResult {
                                project: project.clone(),
                                workspace: workspace.clone(),
                                old_path: old_path.clone(),
                                new_path: String::new(),
                                success: false,
                                message: Some("Workspace not found".to_string()),
                            },
                        )
                        .await?;
                    }
                },
                None => {
                    send_message(
                        socket,
                        &ServerMessage::FileMoveResult {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            old_path: old_path.clone(),
                            new_path: String::new(),
                            success: false,
                            message: Some("Project not found".to_string()),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // Not a file message
        _ => Ok(false),
    }
}
