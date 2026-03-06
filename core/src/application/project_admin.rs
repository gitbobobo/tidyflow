use std::path::PathBuf;

use crate::application::project::workspace_status_str;
use crate::server::context::SharedAppState;
use crate::server::protocol::{ProjectCommandInfo, ServerMessage, TemplateInfo, WorkspaceInfo};
use crate::workspace::project::ProjectManager;
use crate::workspace::workspace::WorkspaceManager;

pub async fn import_project_message(
    app_state: &SharedAppState,
    name: &str,
    path: &str,
) -> ServerMessage {
    let path_buf = PathBuf::from(path);
    let mut state = app_state.write().await;

    match ProjectManager::import_local(&mut state, name, &path_buf) {
        Ok(project) => ServerMessage::ProjectImported {
            name: name.to_string(),
            root: project.root_path.to_string_lossy().to_string(),
            default_branch: project.default_branch.clone(),
            workspace: None,
        },
        Err(e) => {
            let (code, message) = match &e {
                crate::workspace::project::ProjectError::AlreadyExists(_) => {
                    ("project_exists".to_string(), e.to_string())
                }
                crate::workspace::project::ProjectError::PathNotFound(_) => {
                    ("path_not_found".to_string(), e.to_string())
                }
                crate::workspace::project::ProjectError::NotGitRepo(_) => {
                    ("not_git_repo".to_string(), e.to_string())
                }
                _ => ("import_error".to_string(), e.to_string()),
            };
            ServerMessage::Error { code, message }
        }
    }
}

pub async fn create_workspace_message(
    app_state: &SharedAppState,
    project: &str,
    from_branch: Option<&str>,
    template_id: Option<&str>,
) -> ServerMessage {
    let mut state = app_state.write().await;

    // 如果指定了模板，提取模板命令以备后用
    let template_commands: Option<Vec<crate::workspace::state::ProjectCommand>> =
        template_id.and_then(|tid| {
            state
                .client_settings
                .templates
                .iter()
                .find(|t| t.id == tid)
                .map(|tpl| {
                    tpl.commands
                        .iter()
                        .map(|c| crate::workspace::state::ProjectCommand {
                            id: c.id.clone(),
                            name: c.name.clone(),
                            icon: c.icon.clone(),
                            command: c.command.clone(),
                            blocking: c.blocking,
                            interactive: c.interactive,
                        })
                        .collect()
                })
        });

    match WorkspaceManager::create(&mut state, project, from_branch, false) {
        Ok(ws) => {
            // 如果指定了模板，将模板命令应用到项目
            if let Some(cmds) = template_commands {
                if let Some(p) = state.get_project_mut(project) {
                    if p.commands.is_empty() {
                        p.commands = cmds;
                    }
                }
            }
            ServerMessage::WorkspaceCreated {
                project: project.to_string(),
                workspace: WorkspaceInfo {
                    name: ws.name,
                    root: ws.worktree_path.to_string_lossy().to_string(),
                    branch: ws.branch,
                    status: workspace_status_str(&ws.status),
                    sidebar_status: Default::default(),
                },
            }
        }
        Err(e) => {
            let (code, message) = match &e {
                crate::workspace::workspace::WorkspaceError::AlreadyExists(_) => {
                    ("workspace_exists".to_string(), e.to_string())
                }
                crate::workspace::workspace::WorkspaceError::ProjectNotFound(_) => {
                    ("project_not_found".to_string(), e.to_string())
                }
                crate::workspace::workspace::WorkspaceError::NotGitRepo(_) => {
                    ("not_git_repo".to_string(), e.to_string())
                }
                _ => ("workspace_error".to_string(), e.to_string()),
            };
            ServerMessage::Error { code, message }
        }
    }
}

pub async fn remove_project_message(app_state: &SharedAppState, name: &str) -> ServerMessage {
    let mut state = app_state.write().await;

    match ProjectManager::remove(&mut state, name) {
        Ok(_) => ServerMessage::ProjectRemoved {
            name: name.to_string(),
            ok: true,
            message: Some("项目已移除".to_string()),
        },
        Err(e) => ServerMessage::ProjectRemoved {
            name: name.to_string(),
            ok: false,
            message: Some(e.to_string()),
        },
    }
}

pub async fn remove_workspace_message(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
) -> ServerMessage {
    let mut state = app_state.write().await;

    match WorkspaceManager::remove(&mut state, project, workspace) {
        Ok(_) => ServerMessage::WorkspaceRemoved {
            project: project.to_string(),
            workspace: workspace.to_string(),
            ok: true,
            message: Some("工作空间已删除".to_string()),
        },
        Err(e) => ServerMessage::WorkspaceRemoved {
            project: project.to_string(),
            workspace: workspace.to_string(),
            ok: false,
            message: Some(e.to_string()),
        },
    }
}

pub async fn save_project_commands_message(
    app_state: &SharedAppState,
    project: &str,
    commands: &[ProjectCommandInfo],
) -> ServerMessage {
    let mut state = app_state.write().await;
    match state.get_project_mut(project) {
        Some(p) => {
            p.commands = commands
                .iter()
                .map(|c| crate::workspace::state::ProjectCommand {
                    id: c.id.clone(),
                    name: c.name.clone(),
                    icon: c.icon.clone(),
                    command: c.command.clone(),
                    blocking: c.blocking,
                    interactive: c.interactive,
                })
                .collect();

            ServerMessage::ProjectCommandsSaved {
                project: project.to_string(),
                ok: true,
                message: None,
            }
        }
        None => ServerMessage::ProjectCommandsSaved {
            project: project.to_string(),
            ok: false,
            message: Some(format!("Project '{}' not found", project)),
        },
    }
}

pub fn project_commands_saved_ok(msg: &ServerMessage) -> bool {
    matches!(msg, ServerMessage::ProjectCommandsSaved { ok: true, .. })
}

// MARK: - 工作流模板管理

/// 获取所有内置模板
pub fn builtin_templates() -> Vec<crate::workspace::state::WorkflowTemplate> {
    use crate::workspace::state::{TemplateCommand, WorkflowTemplate};
    vec![
        WorkflowTemplate {
            id: "builtin:node".to_string(),
            name: "Node.js".to_string(),
            description: "Node.js 项目常用命令".to_string(),
            tags: vec!["node".to_string(), "javascript".to_string()],
            commands: vec![
                TemplateCommand { id: "node.install".to_string(), name: "Install".to_string(), icon: "arrow.down.circle".to_string(), command: "npm install".to_string(), blocking: true, interactive: false },
                TemplateCommand { id: "node.dev".to_string(), name: "Dev".to_string(), icon: "play.circle".to_string(), command: "npm run dev".to_string(), blocking: false, interactive: true },
                TemplateCommand { id: "node.build".to_string(), name: "Build".to_string(), icon: "hammer".to_string(), command: "npm run build".to_string(), blocking: true, interactive: false },
                TemplateCommand { id: "node.test".to_string(), name: "Test".to_string(), icon: "checkmark.circle".to_string(), command: "npm test".to_string(), blocking: true, interactive: false },
            ],
            env_vars: vec![],
            builtin: true,
        },
        WorkflowTemplate {
            id: "builtin:rust".to_string(),
            name: "Rust".to_string(),
            description: "Rust 项目常用命令".to_string(),
            tags: vec!["rust".to_string()],
            commands: vec![
                TemplateCommand { id: "rust.build".to_string(), name: "Build".to_string(), icon: "hammer".to_string(), command: "cargo build".to_string(), blocking: true, interactive: false },
                TemplateCommand { id: "rust.test".to_string(), name: "Test".to_string(), icon: "checkmark.circle".to_string(), command: "cargo test".to_string(), blocking: true, interactive: false },
                TemplateCommand { id: "rust.run".to_string(), name: "Run".to_string(), icon: "play.circle".to_string(), command: "cargo run".to_string(), blocking: false, interactive: true },
                TemplateCommand { id: "rust.clippy".to_string(), name: "Clippy".to_string(), icon: "doc.text.magnifyingglass".to_string(), command: "cargo clippy".to_string(), blocking: true, interactive: false },
            ],
            env_vars: vec![],
            builtin: true,
        },
        WorkflowTemplate {
            id: "builtin:go".to_string(),
            name: "Go".to_string(),
            description: "Go 项目常用命令".to_string(),
            tags: vec!["go".to_string()],
            commands: vec![
                TemplateCommand { id: "go.build".to_string(), name: "Build".to_string(), icon: "hammer".to_string(), command: "go build ./...".to_string(), blocking: true, interactive: false },
                TemplateCommand { id: "go.test".to_string(), name: "Test".to_string(), icon: "checkmark.circle".to_string(), command: "go test ./...".to_string(), blocking: true, interactive: false },
                TemplateCommand { id: "go.run".to_string(), name: "Run".to_string(), icon: "play.circle".to_string(), command: "go run .".to_string(), blocking: false, interactive: true },
            ],
            env_vars: vec![],
            builtin: true,
        },
        WorkflowTemplate {
            id: "builtin:python".to_string(),
            name: "Python".to_string(),
            description: "Python 项目常用命令".to_string(),
            tags: vec!["python".to_string()],
            commands: vec![
                TemplateCommand { id: "python.install".to_string(), name: "Install".to_string(), icon: "arrow.down.circle".to_string(), command: "pip install -r requirements.txt".to_string(), blocking: true, interactive: false },
                TemplateCommand { id: "python.run".to_string(), name: "Run".to_string(), icon: "play.circle".to_string(), command: "python main.py".to_string(), blocking: false, interactive: true },
                TemplateCommand { id: "python.test".to_string(), name: "Test".to_string(), icon: "checkmark.circle".to_string(), command: "pytest".to_string(), blocking: true, interactive: false },
            ],
            env_vars: vec![],
            builtin: true,
        },
    ]
}

/// 将内置模板注入 ClientSettings（如不存在则添加）
pub fn ensure_builtin_templates(client_settings: &mut crate::workspace::state::ClientSettings) {
    for tpl in builtin_templates() {
        if !client_settings.templates.iter().any(|t| t.id == tpl.id) {
            client_settings.templates.push(tpl);
        }
    }
}

/// 列出所有工作流模板
pub async fn list_templates_message(app_state: &SharedAppState) -> ServerMessage {
    let state = app_state.read().await;
    let templates = state
        .client_settings
        .templates
        .iter()
        .map(template_to_info)
        .collect();
    ServerMessage::Templates { items: templates }
}

/// 保存（新增或更新）工作流模板
pub async fn save_template_message(
    app_state: &SharedAppState,
    template_info: &TemplateInfo,
) -> ServerMessage {
    let mut state = app_state.write().await;
    let tpl = info_to_template(template_info, false);
    let existing = state
        .client_settings
        .templates
        .iter()
        .position(|t| t.id == tpl.id);
    if let Some(idx) = existing {
        state.client_settings.templates[idx] = tpl;
    } else {
        state.client_settings.templates.push(tpl);
    }
    ServerMessage::TemplateSaved {
        template: template_info.clone(),
        ok: true,
        message: None,
    }
}

/// 删除工作流模板（内置模板不可删除）
pub async fn delete_template_message(
    app_state: &SharedAppState,
    template_id: &str,
) -> ServerMessage {
    let mut state = app_state.write().await;
    if let Some(pos) = state
        .client_settings
        .templates
        .iter()
        .position(|t| t.id == template_id && !t.builtin)
    {
        state.client_settings.templates.remove(pos);
        ServerMessage::TemplateDeleted {
            template_id: template_id.to_string(),
            ok: true,
            message: None,
        }
    } else {
        ServerMessage::TemplateDeleted {
            template_id: template_id.to_string(),
            ok: false,
            message: Some("模板不存在或为内置模板".to_string()),
        }
    }
}

/// 导出工作流模板（直接返回模板数据）
pub async fn export_template_message(
    app_state: &SharedAppState,
    template_id: &str,
) -> ServerMessage {
    let state = app_state.read().await;
    if let Some(tpl) = state
        .client_settings
        .templates
        .iter()
        .find(|t| t.id == template_id)
    {
        ServerMessage::TemplateExported {
            template: template_to_info(tpl),
        }
    } else {
        ServerMessage::Error {
            code: "template_not_found".to_string(),
            message: format!("模板 '{}' 不存在", template_id),
        }
    }
}

/// 导入工作流模板（如有重名则加后缀，如有 ID 冲突则重新生成）
pub async fn import_template_message(
    app_state: &SharedAppState,
    template_info: &TemplateInfo,
) -> ServerMessage {
    let mut state = app_state.write().await;
    let existing_name = state
        .client_settings
        .templates
        .iter()
        .any(|t| t.name == template_info.name && t.id != template_info.id);
    let name = if existing_name {
        format!("{} (导入)", template_info.name)
    } else {
        template_info.name.clone()
    };
    let id = if state
        .client_settings
        .templates
        .iter()
        .any(|t| t.id == template_info.id)
    {
        uuid::Uuid::new_v4().to_string()
    } else {
        template_info.id.clone()
    };
    let tpl = crate::workspace::state::WorkflowTemplate {
        id: id.clone(),
        name: name.clone(),
        description: template_info.description.clone(),
        tags: template_info.tags.clone(),
        commands: template_info
            .commands
            .iter()
            .map(|c| crate::workspace::state::TemplateCommand {
                id: c.id.clone(),
                name: c.name.clone(),
                icon: c.icon.clone(),
                command: c.command.clone(),
                blocking: c.blocking,
                interactive: c.interactive,
            })
            .collect(),
        env_vars: template_info.env_vars.clone(),
        builtin: false,
    };
    let result_info = TemplateInfo {
        id,
        name,
        description: tpl.description.clone(),
        tags: tpl.tags.clone(),
        commands: template_info.commands.clone(),
        env_vars: tpl.env_vars.clone(),
        builtin: false,
    };
    state.client_settings.templates.push(tpl);
    ServerMessage::TemplateImported {
        template: result_info,
        ok: true,
        message: None,
    }
}

// MARK: - 内部辅助函数

fn template_to_info(t: &crate::workspace::state::WorkflowTemplate) -> TemplateInfo {
    TemplateInfo {
        id: t.id.clone(),
        name: t.name.clone(),
        description: t.description.clone(),
        tags: t.tags.clone(),
        commands: t
            .commands
            .iter()
            .map(|c| crate::server::protocol::TemplateCommandInfo {
                id: c.id.clone(),
                name: c.name.clone(),
                icon: c.icon.clone(),
                command: c.command.clone(),
                blocking: c.blocking,
                interactive: c.interactive,
            })
            .collect(),
        env_vars: t.env_vars.clone(),
        builtin: t.builtin,
    }
}

fn info_to_template(
    info: &TemplateInfo,
    builtin: bool,
) -> crate::workspace::state::WorkflowTemplate {
    crate::workspace::state::WorkflowTemplate {
        id: info.id.clone(),
        name: info.name.clone(),
        description: info.description.clone(),
        tags: info.tags.clone(),
        commands: info
            .commands
            .iter()
            .map(|c| crate::workspace::state::TemplateCommand {
                id: c.id.clone(),
                name: c.name.clone(),
                icon: c.icon.clone(),
                command: c.command.clone(),
                blocking: c.blocking,
                interactive: c.interactive,
            })
            .collect(),
        env_vars: info.env_vars.clone(),
        builtin,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_commands_saved_ok_detects_success() {
        let ok_msg = ServerMessage::ProjectCommandsSaved {
            project: "p".to_string(),
            ok: true,
            message: None,
        };
        let fail_msg = ServerMessage::ProjectCommandsSaved {
            project: "p".to_string(),
            ok: false,
            message: Some("x".to_string()),
        };

        assert!(project_commands_saved_ok(&ok_msg));
        assert!(!project_commands_saved_ok(&fail_msg));
    }

    #[test]
    fn builtin_templates_should_have_four_entries() {
        let templates = builtin_templates();
        assert_eq!(templates.len(), 4);
        let ids: Vec<_> = templates.iter().map(|t| t.id.as_str()).collect();
        assert!(ids.contains(&"builtin:node"));
        assert!(ids.contains(&"builtin:rust"));
        assert!(ids.contains(&"builtin:go"));
        assert!(ids.contains(&"builtin:python"));
        // 所有内置模板 builtin 标记为 true
        for tpl in &templates {
            assert!(tpl.builtin, "模板 {} 应标记为内置", tpl.id);
            assert!(!tpl.commands.is_empty(), "模板 {} 应有命令", tpl.id);
        }
    }

    #[test]
    fn ensure_builtin_templates_adds_missing_templates() {
        let mut settings = crate::workspace::state::ClientSettings::default();
        ensure_builtin_templates(&mut settings);
        assert_eq!(settings.templates.len(), 4);
        // 重复调用不应重复添加
        ensure_builtin_templates(&mut settings);
        assert_eq!(settings.templates.len(), 4);
    }

    #[tokio::test]
    async fn template_save_and_delete_roundtrip() {
        use crate::workspace::state::AppState;
        use std::sync::Arc;
        use tokio::sync::RwLock;

        let state = Arc::new(RwLock::new(AppState::default()));
        let info = crate::server::protocol::TemplateInfo {
            id: "test-001".to_string(),
            name: "Test Template".to_string(),
            description: "测试模板".to_string(),
            tags: vec!["test".to_string()],
            commands: vec![],
            env_vars: vec![],
            builtin: false,
        };

        // 保存模板
        let save_msg = save_template_message(&state, &info).await;
        assert!(matches!(save_msg, ServerMessage::TemplateSaved { ok: true, .. }));

        // 列出模板
        let list_msg = list_templates_message(&state).await;
        if let ServerMessage::Templates { items } = list_msg {
            assert!(items.iter().any(|t| t.id == "test-001"));
        } else {
            panic!("应返回 Templates 消息");
        }

        // 删除模板
        let del_msg = delete_template_message(&state, "test-001").await;
        assert!(matches!(del_msg, ServerMessage::TemplateDeleted { ok: true, .. }));

        // 删除不存在的模板应返回 ok: false
        let del_fail = delete_template_message(&state, "test-001").await;
        assert!(matches!(del_fail, ServerMessage::TemplateDeleted { ok: false, .. }));
    }
}
