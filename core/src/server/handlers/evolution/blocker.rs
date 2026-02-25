use std::path::PathBuf;

use chrono::Utc;
use serde::{Deserialize, Serialize};
use tracing::warn;
use uuid::Uuid;

use crate::ai::AiQuestionRequest;
use crate::server::context::HandlerContext;
use crate::server::protocol::{
    EvolutionBlockerItemInfo, EvolutionBlockerOptionInfo, EvolutionBlockerResolutionInput,
    ServerMessage,
};

use super::utils::workspace_key;
use super::EvolutionManager;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WorkspaceBlockerFile {
    #[serde(rename = "$schema_version")]
    schema_version: String,
    project: String,
    workspace: String,
    workspace_key: String,
    updated_at: String,
    #[serde(default)]
    items: Vec<WorkspaceBlockerItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WorkspaceBlockerItem {
    blocker_id: String,
    status: String,
    cycle_id: String,
    stage: String,
    created_at: String,
    source: String,
    title: String,
    description: String,
    question_type: String,
    #[serde(default)]
    options: Vec<WorkspaceBlockerOption>,
    #[serde(default)]
    allow_custom_input: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    resolution: Option<WorkspaceBlockerResolution>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WorkspaceBlockerOption {
    option_id: String,
    label: String,
    description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WorkspaceBlockerResolution {
    #[serde(default)]
    selected_option_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    answer_text: Option<String>,
    resolved_by: String,
    resolved_at: String,
}

impl WorkspaceBlockerItem {
    fn to_protocol_item(&self) -> EvolutionBlockerItemInfo {
        EvolutionBlockerItemInfo {
            blocker_id: self.blocker_id.clone(),
            status: self.status.clone(),
            cycle_id: self.cycle_id.clone(),
            stage: self.stage.clone(),
            created_at: self.created_at.clone(),
            source: self.source.clone(),
            title: self.title.clone(),
            description: self.description.clone(),
            question_type: self.question_type.clone(),
            options: self
                .options
                .iter()
                .map(|item| EvolutionBlockerOptionInfo {
                    option_id: item.option_id.clone(),
                    label: item.label.clone(),
                    description: item.description.clone(),
                })
                .collect(),
            allow_custom_input: self.allow_custom_input,
        }
    }
}

impl EvolutionManager {
    fn blocker_file_path(workspace_root: &str) -> Result<PathBuf, String> {
        super::utils::evolution_workspace_dir(workspace_root)
            .map(|dir| dir.join("workspace.blockers.json"))
    }

    fn load_blocker_file(
        workspace_root: &str,
        project: &str,
        workspace: &str,
    ) -> Result<WorkspaceBlockerFile, String> {
        let path = Self::blocker_file_path(workspace_root)?;
        if !path.exists() {
            return Ok(WorkspaceBlockerFile {
                schema_version: "1.0".to_string(),
                project: project.to_string(),
                workspace: workspace.to_string(),
                workspace_key: workspace_key(project, workspace),
                updated_at: Utc::now().to_rfc3339(),
                items: vec![],
            });
        }
        let content = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
        let mut parsed: WorkspaceBlockerFile =
            serde_json::from_str(&content).map_err(|e| e.to_string())?;
        if parsed.schema_version.trim().is_empty() {
            parsed.schema_version = "1.0".to_string();
        }
        if parsed.project.trim().is_empty() {
            parsed.project = project.to_string();
        }
        if parsed.workspace.trim().is_empty() {
            parsed.workspace = workspace.to_string();
        }
        if parsed.workspace_key.trim().is_empty() {
            parsed.workspace_key = workspace_key(project, workspace);
        }
        Ok(parsed)
    }

    fn save_blocker_file(workspace_root: &str, file: &WorkspaceBlockerFile) -> Result<(), String> {
        let path = Self::blocker_file_path(workspace_root)?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let data = serde_json::to_string_pretty(file).map_err(|e| e.to_string())?;
        std::fs::write(path, data).map_err(|e| e.to_string())
    }

    pub(super) async fn unresolved_blockers(
        &self,
        workspace_root: &str,
        project: &str,
        workspace: &str,
    ) -> Result<Vec<EvolutionBlockerItemInfo>, String> {
        let file = Self::load_blocker_file(workspace_root, project, workspace)?;
        Ok(file
            .items
            .iter()
            .filter(|item| item.status == "open")
            .map(|item| item.to_protocol_item())
            .collect())
    }

    pub(super) async fn emit_blocking_required_if_any(
        &self,
        project: &str,
        workspace: &str,
        workspace_root: &str,
        trigger: &str,
        cycle_id: Option<&str>,
        stage: Option<&str>,
        ctx: &HandlerContext,
    ) -> Result<bool, String> {
        let unresolved = self
            .unresolved_blockers(workspace_root, project, workspace)
            .await?;
        if unresolved.is_empty() {
            return Ok(false);
        }
        let key = workspace_key(project, workspace);
        let blocker_file_path = Self::blocker_file_path(workspace_root)?
            .to_string_lossy()
            .to_string();

        self.broadcast(
            ctx,
            ServerMessage::EvoBlockingRequired {
                project: project.to_string(),
                workspace: workspace.to_string(),
                trigger: trigger.to_string(),
                cycle_id: cycle_id.map(|v| v.to_string()),
                stage: stage.map(|v| v.to_string()),
                blocker_file_path: blocker_file_path.clone(),
                unresolved_items: unresolved.clone(),
            },
        )
        .await;
        self.broadcast(
            ctx,
            ServerMessage::EvoBlockersUpdated {
                project: project.to_string(),
                workspace: workspace.to_string(),
                unresolved_count: unresolved.len() as u32,
                unresolved_items: unresolved,
            },
        )
        .await;
        warn!(
            "evolution blocked by unresolved blockers: key={}, trigger={}, blocker_file={}",
            key, trigger, blocker_file_path
        );
        Ok(true)
    }

    pub(super) async fn resolve_blockers(
        &self,
        project: &str,
        workspace: &str,
        resolutions: Vec<EvolutionBlockerResolutionInput>,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let workspace_root =
            crate::server::handlers::ai::resolve_directory(&ctx.app_state, project, workspace)
                .await?;
        let mut blocker_file = Self::load_blocker_file(&workspace_root, project, workspace)?;
        let mut changed = false;
        for resolution in resolutions {
            let Some(item) = blocker_file
                .items
                .iter_mut()
                .find(|item| item.blocker_id == resolution.blocker_id && item.status == "open")
            else {
                continue;
            };
            item.status = "resolved".to_string();
            item.resolution = Some(WorkspaceBlockerResolution {
                selected_option_ids: resolution.selected_option_ids,
                answer_text: resolution.answer_text,
                resolved_by: "user".to_string(),
                resolved_at: Utc::now().to_rfc3339(),
            });
            changed = true;
        }
        if changed {
            blocker_file.updated_at = Utc::now().to_rfc3339();
            Self::save_blocker_file(&workspace_root, &blocker_file)?;
        }

        let unresolved = self
            .unresolved_blockers(&workspace_root, project, workspace)
            .await?;
        self.broadcast(
            ctx,
            ServerMessage::EvoBlockersUpdated {
                project: project.to_string(),
                workspace: workspace.to_string(),
                unresolved_count: unresolved.len() as u32,
                unresolved_items: unresolved,
            },
        )
        .await;
        Ok(())
    }

    pub(super) async fn add_blocker_from_question(
        &self,
        project: &str,
        workspace: &str,
        workspace_root: &str,
        cycle_id: &str,
        stage: &str,
        request: &AiQuestionRequest,
    ) -> Result<(), String> {
        let mut blocker_file = Self::load_blocker_file(workspace_root, project, workspace)?;
        let now = Utc::now().to_rfc3339();

        let mut options: Vec<WorkspaceBlockerOption> = Vec::new();
        let mut question_title = "需要人工决策".to_string();
        let mut question_desc = "AI 代理需要人类补充信息或决策".to_string();
        let mut question_type = "text".to_string();
        let mut allow_custom_input = true;

        if let Some(first) = request.questions.first() {
            if !first.header.trim().is_empty() {
                question_title = first.header.trim().to_string();
            }
            if !first.question.trim().is_empty() {
                question_desc = first.question.trim().to_string();
            }
            question_type = if first.multiple {
                "multi_choice".to_string()
            } else if !first.options.is_empty() {
                "single_choice".to_string()
            } else {
                "text".to_string()
            };
            allow_custom_input = first.custom || first.options.is_empty();
            options = first
                .options
                .iter()
                .enumerate()
                .map(|(idx, item)| WorkspaceBlockerOption {
                    option_id: format!("opt-{}", idx + 1),
                    label: item.label.clone(),
                    description: item.description.clone(),
                })
                .collect();
        }

        blocker_file.items.push(WorkspaceBlockerItem {
            blocker_id: format!("blk-{}", Uuid::new_v4().simple()),
            status: "open".to_string(),
            cycle_id: cycle_id.to_string(),
            stage: stage.to_string(),
            created_at: now.clone(),
            source: "ai_question_event".to_string(),
            title: question_title,
            description: question_desc,
            question_type,
            options,
            allow_custom_input,
            resolution: None,
        });
        blocker_file.updated_at = now;
        Self::save_blocker_file(workspace_root, &blocker_file)
    }

    pub(super) async fn has_stage_blocker(
        &self,
        workspace_root: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
    ) -> bool {
        match Self::load_blocker_file(workspace_root, project, workspace) {
            Ok(file) => file.items.iter().any(|item| {
                item.status == "open" && item.cycle_id == cycle_id && item.stage == stage
            }),
            Err(_) => false,
        }
    }
}
