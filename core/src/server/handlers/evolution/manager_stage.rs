use chrono::Utc;
use futures::StreamExt;
use image::imageops::FilterType;
use tokio::time::{timeout, Duration};
use tracing::warn;
use uuid::Uuid;

use crate::ai::{AiModelSelection, AiQuestionRequest};
use crate::server::context::HandlerContext;
use crate::server::handlers::ai::{
    ensure_agent, infer_selection_hint_from_messages, merge_session_selection_hint,
    normalize_part_for_wire, resolve_directory,
};
use crate::server::handlers::git::branch_commit::run_ai_commit_internal;
use crate::server::protocol::ServerMessage;

use super::profile::profile_for_stage;
use super::utils::cycle_dir_path;
use super::{EvolutionManager, MAX_STAGE_RUNTIME_SECS, STAGES};

fn parse_judge_result_text(value: &str) -> Option<bool> {
    let normalized = value.trim().to_ascii_lowercase();
    if normalized == "pass" {
        return Some(true);
    }
    if normalized == "fail" {
        return Some(false);
    }
    None
}

fn parse_judge_result_from_json(value: &serde_json::Value) -> Option<bool> {
    let overall = value
        .pointer("/overall_result/result")
        .and_then(|v| v.as_str())
        .and_then(parse_judge_result_text);
    if overall.is_some() {
        return overall;
    }

    value
        .pointer("/decision/result")
        .and_then(|v| v.as_str())
        .and_then(parse_judge_result_text)
}

impl EvolutionManager {
    fn json_contains_token(value: &serde_json::Value, token: &str) -> bool {
        let target = token.to_ascii_lowercase();
        match value {
            serde_json::Value::String(text) => text.to_ascii_lowercase().contains(&target),
            serde_json::Value::Array(arr) => arr
                .iter()
                .any(|item| Self::json_contains_token(item, token)),
            serde_json::Value::Object(map) => map
                .values()
                .any(|item| Self::json_contains_token(item, token)),
            _ => false,
        }
    }

    fn hamming_distance_u64(a: u64, b: u64) -> u32 {
        (a ^ b).count_ones()
    }

    fn screenshot_content_fingerprint(path: &std::path::Path) -> Result<u64, String> {
        let image =
            image::open(path).map_err(|e| format!("读取截图失败({}): {}", path.display(), e))?;
        let width = image.width();
        let height = image.height();
        if width < 200 || height < 200 {
            return Err(format!(
                "截图分辨率过低({}): {}x{}，至少需要 200x200",
                path.display(),
                width,
                height
            ));
        }

        let rgb = image.to_rgb8();
        let raw = rgb.as_raw();
        let mut unique = std::collections::HashSet::new();
        let step = std::cmp::max(1usize, raw.len() / (3 * 8192));
        let mut sample_count = 0f64;
        let mut luminance_sum = 0f64;
        let mut luminance_sq_sum = 0f64;
        let mut i = 0usize;
        while i + 2 < raw.len() {
            let r = raw[i] as f64;
            let g = raw[i + 1] as f64;
            let b = raw[i + 2] as f64;
            let key = ((raw[i] as u32) << 16) | ((raw[i + 1] as u32) << 8) | (raw[i + 2] as u32);
            if unique.len() < 2048 {
                unique.insert(key);
            }
            let y = 0.299 * r + 0.587 * g + 0.114 * b;
            sample_count += 1.0;
            luminance_sum += y;
            luminance_sq_sum += y * y;
            i += step * 3;
        }
        if sample_count < 10.0 {
            return Err(format!("截图样本不足({})", path.display()));
        }
        let mean = luminance_sum / sample_count;
        let variance = (luminance_sq_sum / sample_count) - mean * mean;
        let stddev = variance.max(0.0).sqrt();
        if unique.len() < 24 {
            return Err(format!(
                "截图内容颜色过于单一({})，疑似占位图",
                path.display()
            ));
        }
        if stddev < 6.0 {
            return Err(format!(
                "截图亮度变化过低({})，疑似空白或占位图",
                path.display()
            ));
        }

        let gray = image.to_luma8();
        let tiny = image::imageops::resize(&gray, 9, 8, FilterType::Triangle);
        let mut hash = 0u64;
        let mut bit = 0u32;
        for y in 0..8u32 {
            for x in 0..8u32 {
                let left = tiny.get_pixel(x, y)[0];
                let right = tiny.get_pixel(x + 1, y)[0];
                if left > right {
                    hash |= 1u64 << bit;
                }
                bit += 1;
            }
        }
        Ok(hash)
    }

    async fn validate_evidence_hygiene_for_cycle(
        &self,
        key: &str,
        cycle_id: &str,
    ) -> Result<(), String> {
        let workspace_root = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            entry.workspace_root.clone()
        };
        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        let evidence_dir = cycle_dir.join("evidence");
        if !evidence_dir.exists() {
            return Ok(());
        }

        for entry in walkdir::WalkDir::new(&evidence_dir)
            .into_iter()
            .filter_map(Result::ok)
        {
            if !entry.file_type().is_file() {
                continue;
            }
            let rel = entry
                .path()
                .strip_prefix(&evidence_dir)
                .map_err(|e| e.to_string())?;
            let rel_text = rel.to_string_lossy().replace('\\', "/");
            let ext = entry
                .path()
                .extension()
                .and_then(|v| v.to_str())
                .map(|v| v.to_ascii_lowercase())
                .unwrap_or_default();
            let is_log = ext == "log";
            let is_png = ext == "png";
            if !is_log && !is_png {
                return Err(format!(
                    "证据目录仅允许 .log/.png，发现不合规文件: evidence/{}",
                    rel_text
                ));
            }
            if is_log && !rel_text.starts_with("logs/") {
                return Err(format!(
                    "日志证据必须位于 evidence/logs/ 下，发现: evidence/{}",
                    rel_text
                ));
            }
            if is_png && !rel_text.starts_with("screenshots/") {
                return Err(format!(
                    "截图证据必须位于 evidence/screenshots/ 下，发现: evidence/{}",
                    rel_text
                ));
            }
        }

        let evidence_index_path = cycle_dir.join("evidence.index.json");
        if !evidence_index_path.exists() {
            return Ok(());
        }
        let content = std::fs::read_to_string(&evidence_index_path)
            .map_err(|e| format!("读取 evidence.index.json 失败: {}", e))?;
        let index_json: serde_json::Value = serde_json::from_str(&content)
            .map_err(|e| format!("解析 evidence.index.json 失败: {}", e))?;
        let items = index_json
            .get("items")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "evidence.index.json 缺少 items 数组".to_string())?;

        let lifecycle_scan_path = cycle_dir.join("direction.lifecycle_scan.json");
        let ui_capability = if lifecycle_scan_path.exists() {
            match std::fs::read_to_string(&lifecycle_scan_path) {
                Ok(text) => serde_json::from_str::<serde_json::Value>(&text)
                    .ok()
                    .and_then(|v| {
                        v.get("ui_capability")
                            .and_then(|x| x.as_str())
                            .map(|s| s.to_ascii_lowercase())
                    })
                    .unwrap_or_else(|| "none".to_string()),
                Err(_) => "none".to_string(),
            }
        } else {
            "none".to_string()
        };

        let cycle_path = cycle_dir.join("cycle.json");
        let screenshot_required = if cycle_path.exists() {
            match std::fs::read_to_string(&cycle_path) {
                Ok(text) => serde_json::from_str::<serde_json::Value>(&text)
                    .ok()
                    .map(|v| {
                        v.pointer("/llm_defined_acceptance/minimum_evidence_policy")
                            .map(|policy| Self::json_contains_token(policy, "screenshot"))
                            .unwrap_or(false)
                    })
                    .unwrap_or(false),
                Err(_) => false,
            }
        } else {
            false
        };

        let mut screenshot_hashes: Vec<(String, u64)> = Vec::new();
        let mut screenshot_count = 0usize;
        for item in items {
            let Some(path_text) = item.get("path").and_then(|v| v.as_str()) else {
                continue;
            };
            if path_text.contains("..") {
                return Err(format!(
                    "evidence.index.json 包含非法路径(含 ..): {}",
                    path_text
                ));
            }
            let normalized = path_text.replace('\\', "/");
            let is_log_path =
                normalized.starts_with("evidence/logs/") && normalized.ends_with(".log");
            let is_png_path =
                normalized.starts_with("evidence/screenshots/") && normalized.ends_with(".png");
            if !is_log_path && !is_png_path {
                return Err(format!(
                    "evidence.index.json 路径必须位于 evidence/logs/*.log 或 evidence/screenshots/*.png: {}",
                    normalized
                ));
            }

            let item_type = item
                .get("type")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if item_type == "screenshot" && !is_png_path {
                return Err(format!(
                    "截图证据必须写入 evidence/screenshots/*.png: {}",
                    normalized
                ));
            }
            if item_type != "screenshot" && !is_log_path {
                return Err(format!(
                    "非截图证据必须写入 evidence/logs/*.log: {} (type={})",
                    normalized, item_type
                ));
            }

            if item_type == "screenshot" {
                screenshot_count += 1;
                let file_path = cycle_dir.join(&normalized);
                if !file_path.exists() {
                    return Err(format!("截图证据文件不存在: {}", file_path.display()));
                }
                let hash = Self::screenshot_content_fingerprint(&file_path)?;
                screenshot_hashes.push((normalized.clone(), hash));
            }
        }

        for i in 0..screenshot_hashes.len() {
            for j in (i + 1)..screenshot_hashes.len() {
                let distance =
                    Self::hamming_distance_u64(screenshot_hashes[i].1, screenshot_hashes[j].1);
                if distance <= 3 {
                    return Err(format!(
                        "截图内容高度相似，疑似重复/占位图: {} vs {} (dhash distance={})",
                        screenshot_hashes[i].0, screenshot_hashes[j].0, distance
                    ));
                }
            }
        }

        if ui_capability != "none" && screenshot_required && screenshot_count == 0 {
            return Err(
                "当前项目存在 UI 且策略要求 screenshot，但 evidence.index.json 中无截图证据"
                    .to_string(),
            );
        }
        Ok(())
    }

    fn extract_acceptance_mapping_criteria(
        value: &serde_json::Value,
    ) -> Result<Vec<serde_json::Value>, String> {
        let mapping = value
            .pointer("/verification_plan/acceptance_mapping")
            .and_then(|v| v.as_array())
            .ok_or_else(|| {
                "plan.execution.json 缺少 verification_plan.acceptance_mapping".to_string()
            })?;

        let mut out = Vec::new();
        for item in mapping {
            let Some(obj) = item.as_object() else {
                return Err("acceptance_mapping 条目必须是对象".to_string());
            };
            let criteria_id = obj
                .get("criteria_id")
                .and_then(|v| v.as_str())
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
                .ok_or_else(|| "acceptance_mapping 条目缺少 criteria_id".to_string())?;
            let check_ids = obj
                .get("check_ids")
                .and_then(|v| v.as_array())
                .ok_or_else(|| format!("{} 缺少 check_ids", criteria_id))?;
            if check_ids.is_empty() {
                return Err(format!("{} 的 check_ids 不能为空", criteria_id));
            }
            out.push(serde_json::json!({
                "criteria_id": criteria_id,
                "description": obj.get("description").and_then(|v| v.as_str()).unwrap_or(""),
                "check_ids": check_ids,
            }));
        }
        Ok(out)
    }

    async fn sync_acceptance_criteria_from_plan(
        &self,
        key: &str,
        cycle_id: &str,
    ) -> Result<(), String> {
        let workspace_root = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            entry.workspace_root.clone()
        };
        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        let plan_path = cycle_dir.join("plan.execution.json");
        let content = std::fs::read_to_string(&plan_path)
            .map_err(|e| format!("读取 plan.execution.json 失败: {}", e))?;
        let parsed: serde_json::Value = serde_json::from_str(&content)
            .map_err(|e| format!("解析 plan.execution.json 失败: {}", e))?;
        let criteria = Self::extract_acceptance_mapping_criteria(&parsed)?;
        if criteria.is_empty() {
            return Err("acceptance_mapping 为空".to_string());
        }
        let mut state = self.state.lock().await;
        let Some(entry) = state.workspaces.get_mut(key) else {
            return Err("workspace state missing".to_string());
        };
        entry.llm_defined_acceptance_criteria = criteria;
        Ok(())
    }

    async fn ensure_acceptance_consistency(&self, key: &str, cycle_id: &str) -> Result<(), String> {
        let workspace_root = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            if entry.llm_defined_acceptance_criteria.is_empty() {
                return Err("cycle llm_defined_acceptance.criteria 为空".to_string());
            }
            entry.workspace_root.clone()
        };
        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        let plan_path = cycle_dir.join("plan.execution.json");
        let content = std::fs::read_to_string(&plan_path)
            .map_err(|e| format!("读取 plan.execution.json 失败: {}", e))?;
        let parsed: serde_json::Value = serde_json::from_str(&content)
            .map_err(|e| format!("解析 plan.execution.json 失败: {}", e))?;
        let criteria_from_plan = Self::extract_acceptance_mapping_criteria(&parsed)?;
        let expected_ids: std::collections::HashSet<String> = criteria_from_plan
            .iter()
            .filter_map(|v| {
                v.get("criteria_id")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string())
            })
            .collect();
        let actual_ids: std::collections::HashSet<String> = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            entry
                .llm_defined_acceptance_criteria
                .iter()
                .filter_map(|v| {
                    v.get("criteria_id")
                        .and_then(|x| x.as_str())
                        .map(|s| s.to_string())
                })
                .collect()
        };
        if expected_ids != actual_ids {
            return Err(format!(
                "criteria_id 集不一致: plan={:?}, cycle={:?}",
                expected_ids, actual_ids
            ));
        }
        Ok(())
    }

    pub(super) async fn interrupt_for_blockers(
        &self,
        key: &str,
        cycle_id: &str,
        reason: &str,
        ctx: &HandlerContext,
    ) {
        let maybe = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return;
            };
            entry.status = "interrupted".to_string();
            entry.stop_requested = false;
            entry.terminal_reason_code = Some(reason.to_string());
            Some((entry.project.clone(), entry.workspace.clone()))
        };
        let Some((project, workspace)) = maybe else {
            return;
        };
        self.persist_cycle_file(key).await.ok();
        self.broadcast(
            ctx,
            ServerMessage::EvoWorkspaceStopped {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(key).await,
                project: project.clone(),
                workspace: workspace.clone(),
                cycle_id: cycle_id.to_string(),
                ts: Utc::now().to_rfc3339(),
                source: "system".to_string(),
                status: "interrupted".to_string(),
                reason: Some(reason.to_string()),
            },
        )
        .await;
        self.broadcast_cycle_update(key, ctx, "system").await;
        self.broadcast_scheduler(ctx).await;
        if let Some(root) = {
            let state = self.state.lock().await;
            state
                .workspaces
                .get(key)
                .map(|item| item.workspace_root.clone())
        } {
            if let Err(err) = self
                .emit_blocking_required_if_any(
                    &project,
                    &workspace,
                    &root,
                    "stage_interrupt",
                    Some(cycle_id),
                    None,
                    ctx,
                )
                .await
            {
                warn!("emit blocking required failed: {}", err);
            }
        }
    }

    async fn block_current_stage_by_question(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        request: &AiQuestionRequest,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let workspace_root = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            entry.workspace_root.clone()
        };
        self.add_blocker_from_question(
            project,
            workspace,
            &workspace_root,
            cycle_id,
            stage,
            request,
        )
        .await?;
        self.set_stage_status(key, stage, "blocked").await;
        self.persist_stage_file(
            key,
            stage,
            "blocked",
            None,
            Some("human blocker created from AI question"),
            None,
        )
        .await
        .ok();
        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "agent").await;
        Ok(())
    }

    async fn run_auto_commit_before_next_round(
        &self,
        workspace_root: &str,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let ai_agent = {
            let state = ctx.app_state.read().await;
            state
                .client_settings
                .commit_ai_agent
                .clone()
                .unwrap_or_else(|| "cursor".to_string())
        };
        let root = std::path::PathBuf::from(workspace_root);
        let agent = ai_agent.clone();

        let result = timeout(
            Duration::from_secs(600),
            tokio::task::spawn_blocking(move || run_ai_commit_internal(&root, &agent, None)),
        )
        .await;

        match result {
            Ok(Ok(Ok(_output))) => Ok(()),
            Ok(Ok(Err(err))) => Err(err),
            Ok(Err(err)) => Err(format!("AI commit task failed: {}", err)),
            Err(_) => Err("AI agent timed out after 600 seconds".to_string()),
        }
    }

    pub(super) async fn run_stage(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        round: u32,
        ctx: &HandlerContext,
    ) -> Result<bool, String> {
        let profile = {
            let state = self.state.lock().await;
            let entry = state
                .workspaces
                .get(key)
                .ok_or_else(|| "workspace state missing".to_string())?;
            profile_for_stage(&entry.stage_profiles, stage)
        };
        let ai_tool = profile.ai_tool.clone();

        self.set_stage_status(key, stage, "running").await;
        self.reset_stage_tool_call_tracking(key, stage).await;
        self.persist_cycle_file(key).await.ok();
        self.persist_stage_file(key, stage, "running", None, None, None)
            .await
            .ok();
        self.broadcast_cycle_update(key, ctx, "orchestrator").await;

        let directory = resolve_directory(&ctx.app_state, project, workspace).await?;
        let agent = ensure_agent(&ctx.ai_state, &ai_tool).await?;

        let title = format!("Evolution {} {}", stage, cycle_id);
        let session = agent.create_session(&directory, &title).await?;
        self.set_stage_session(key, stage, &ai_tool, &session.id)
            .await;
        self.persist_chat_map(key).await.ok();

        let prompt = self
            .build_stage_prompt(key, project, workspace, cycle_id, stage, round)
            .await?;

        let model = profile.model.as_ref().map(|m| AiModelSelection {
            provider_id: m.provider_id.clone(),
            model_id: m.model_id.clone(),
        });
        let mode = profile.mode.clone();

        let mut stream = agent
            .send_message(&directory, &session.id, &prompt, None, None, model, mode)
            .await?;

        let mut judge_pass = true;
        loop {
            let next = timeout(Duration::from_secs(MAX_STAGE_RUNTIME_SECS), stream.next()).await;
            match next {
                Ok(Some(Ok(event))) => match event {
                    crate::ai::AiEvent::Done => {
                        let adapter_hint =
                            match agent.session_selection_hint(&directory, &session.id).await {
                                Ok(Some(adapter_hint)) => adapter_hint,
                                Ok(None) => crate::ai::AiSessionSelectionHint::default(),
                                Err(_) => crate::ai::AiSessionSelectionHint::default(),
                            };
                        let inferred_hint = match agent
                            .list_messages(&directory, &session.id, Some(200))
                            .await
                        {
                            Ok(messages) => {
                                let wire_messages: Vec<crate::server::protocol::ai::MessageInfo> =
                                    messages
                                        .into_iter()
                                        .map(|m| crate::server::protocol::ai::MessageInfo {
                                            id: m.id,
                                            role: m.role,
                                            created_at: m.created_at,
                                            agent: m.agent,
                                            model_provider_id: m.model_provider_id,
                                            model_id: m.model_id,
                                            parts: m
                                                .parts
                                                .into_iter()
                                                .map(normalize_part_for_wire)
                                                .collect(),
                                        })
                                        .collect();
                                infer_selection_hint_from_messages(&wire_messages)
                            }
                            Err(_) => crate::ai::AiSessionSelectionHint::default(),
                        };
                        let selection_hint =
                            merge_session_selection_hint(adapter_hint, inferred_hint);
                        self.broadcast(
                            ctx,
                            ServerMessage::AIChatDone {
                                project_name: project.to_string(),
                                workspace_name: workspace.to_string(),
                                ai_tool: ai_tool.clone(),
                                session_id: session.id.clone(),
                                selection_hint,
                            },
                        )
                        .await;
                        break;
                    }
                    crate::ai::AiEvent::Error { message } => {
                        self.broadcast(
                            ctx,
                            ServerMessage::AIChatErrorV2 {
                                project_name: project.to_string(),
                                workspace_name: workspace.to_string(),
                                ai_tool: ai_tool.clone(),
                                session_id: session.id.clone(),
                                error: message.clone(),
                            },
                        )
                        .await;
                        return Err(format!("stage stream error: {}", message));
                    }
                    crate::ai::AiEvent::MessageUpdated {
                        message_id,
                        role,
                        selection_hint,
                    } => {
                        self.broadcast(
                            ctx,
                            ServerMessage::AIChatMessageUpdated {
                                project_name: project.to_string(),
                                workspace_name: workspace.to_string(),
                                ai_tool: ai_tool.clone(),
                                session_id: session.id.clone(),
                                message_id,
                                role,
                                selection_hint: selection_hint.map(|hint| {
                                    crate::server::protocol::ai::SessionSelectionHint {
                                        agent: hint.agent,
                                        model_provider_id: hint.model_provider_id,
                                        model_id: hint.model_id,
                                    }
                                }),
                            },
                        )
                        .await;
                    }
                    crate::ai::AiEvent::PartUpdated { message_id, part } => {
                        let mut tool_call_count_changed = false;
                        if part.part_type == "tool" {
                            let call_key = part
                                .tool_call_id
                                .as_deref()
                                .filter(|v| !v.trim().is_empty())
                                .unwrap_or(part.id.as_str());
                            tool_call_count_changed =
                                self.record_stage_tool_call(key, stage, call_key).await;
                        }
                        self.broadcast(
                            ctx,
                            ServerMessage::AIChatPartUpdated {
                                project_name: project.to_string(),
                                workspace_name: workspace.to_string(),
                                ai_tool: ai_tool.clone(),
                                session_id: session.id.clone(),
                                message_id,
                                part: normalize_part_for_wire(part),
                            },
                        )
                        .await;
                        if tool_call_count_changed {
                            self.broadcast_cycle_update(key, ctx, "agent").await;
                        }
                    }
                    crate::ai::AiEvent::PartDelta {
                        message_id,
                        part_id,
                        part_type,
                        field,
                        delta,
                    } => {
                        let tool_call_count_changed = if part_type == "tool" {
                            self.record_stage_tool_call(key, stage, &part_id).await
                        } else {
                            false
                        };
                        self.broadcast(
                            ctx,
                            ServerMessage::AIChatPartDelta {
                                project_name: project.to_string(),
                                workspace_name: workspace.to_string(),
                                ai_tool: ai_tool.clone(),
                                session_id: session.id.clone(),
                                message_id,
                                part_id,
                                part_type,
                                field,
                                delta,
                            },
                        )
                        .await;
                        if tool_call_count_changed {
                            self.broadcast_cycle_update(key, ctx, "agent").await;
                        }
                    }
                    crate::ai::AiEvent::QuestionAsked { request } => {
                        self.block_current_stage_by_question(
                            key, project, workspace, cycle_id, stage, &request, ctx,
                        )
                        .await?;
                        return Err("evo_human_blocking_required:ai_question".to_string());
                    }
                    crate::ai::AiEvent::QuestionCleared { .. } => {}
                },
                Ok(Some(Err(err))) => return Err(err),
                Ok(None) => break,
                Err(_) => return Err("stage stream timeout".to_string()),
            }
        }

        if stage == "judge" {
            let maybe_workspace_root = {
                let state = self.state.lock().await;
                state
                    .workspaces
                    .get(key)
                    .map(|entry| entry.workspace_root.clone())
            };

            if let Some(workspace_root) = maybe_workspace_root {
                if let Ok(cycle_dir) = cycle_dir_path(&workspace_root, cycle_id) {
                    let mut file_judge_result: Option<bool> = None;
                    let judge_result_path = cycle_dir.join("judge.result.json");
                    if let Ok(content) = std::fs::read_to_string(&judge_result_path) {
                        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&content) {
                            if let Some(parsed) = parse_judge_result_from_json(&json) {
                                file_judge_result = Some(parsed);
                            }
                        }
                    }

                    if file_judge_result.is_none() {
                        let stage_judge_path = cycle_dir.join("stage.judge.json");
                        if let Ok(content) = std::fs::read_to_string(&stage_judge_path) {
                            if let Ok(json) = serde_json::from_str::<serde_json::Value>(&content) {
                                if let Some(parsed) = parse_judge_result_from_json(&json) {
                                    file_judge_result = Some(parsed);
                                }
                            }
                        }
                    }

                    if let Some(parsed) = file_judge_result {
                        judge_pass = parsed;
                    } else {
                        return Err(
                            "judge structured result missing: require judge.result.json or stage.judge.json with pass/fail"
                                .to_string(),
                        );
                    }
                }
            } else {
                warn!(
                    "judge result resolve skipped: workspace missing, key={}",
                    key
                );
            }
        }

        let blocker_check_ctx = {
            let state = self.state.lock().await;
            state.workspaces.get(key).map(|entry| {
                (
                    entry.workspace_root.clone(),
                    entry.project.clone(),
                    entry.workspace.clone(),
                )
            })
        };
        let has_stage_blocker =
            if let Some((workspace_root, project_name, workspace_name)) = blocker_check_ctx {
                self.has_stage_blocker(
                    &workspace_root,
                    &project_name,
                    &workspace_name,
                    cycle_id,
                    stage,
                )
                .await
            } else {
                false
            };
        if has_stage_blocker {
            self.set_stage_status(key, stage, "blocked").await;
            self.persist_stage_file(
                key,
                stage,
                "blocked",
                Some(&session.id),
                Some("stage blocked by unresolved human blocker"),
                None,
            )
            .await
            .ok();
            self.persist_cycle_file(key).await.ok();
            self.broadcast_cycle_update(key, ctx, "agent").await;
            return Err("evo_human_blocking_required:stage_blocker_file".to_string());
        }

        self.set_stage_status(key, stage, "done").await;
        self.persist_stage_file(
            key,
            stage,
            "done",
            Some(&session.id),
            None,
            if stage == "judge" {
                Some(judge_pass)
            } else {
                None
            },
        )
        .await
        .ok();
        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "agent").await;

        Ok(judge_pass)
    }

    pub(super) async fn after_stage_success(
        &self,
        key: &str,
        stage: &str,
        judge_pass: bool,
        ctx: &HandlerContext,
    ) -> bool {
        let cycle_for_validation = {
            let state = self.state.lock().await;
            state.workspaces.get(key).map(|e| e.cycle_id.clone())
        };
        if stage == "plan" {
            let Some(cycle_id) = cycle_for_validation.clone() else {
                return false;
            };
            if let Err(err) = self
                .sync_acceptance_criteria_from_plan(key, &cycle_id)
                .await
            {
                self.mark_failed_with_code(key, "evo_acceptance_source_missing", &err, ctx)
                    .await;
                return false;
            }
        }
        if stage == "judge" {
            let Some(cycle_id) = cycle_for_validation.clone() else {
                return false;
            };
            if let Err(err) = self.ensure_acceptance_consistency(key, &cycle_id).await {
                self.mark_failed_with_code(key, "evo_acceptance_mapping_inconsistent", &err, ctx)
                    .await;
                return false;
            }
        }
        if matches!(stage, "implement" | "verify" | "judge" | "report") {
            let Some(cycle_id) = cycle_for_validation.clone() else {
                return false;
            };
            if let Err(err) = self
                .validate_evidence_hygiene_for_cycle(key, &cycle_id)
                .await
            {
                self.mark_failed_with_code(key, "evo_evidence_index_invalid", &err, ctx)
                    .await;
                return false;
            }
        }

        let mut emit_judge: Option<(String, String, String, String)> = None;
        let mut stage_changed: Option<(String, String, String, String)> = None;
        let mut auto_next_cycle = false;
        let mut auto_commit_workspace_root: Option<String> = None;
        let mut auto_loop_gate: Option<(String, String, String, String)> = None;

        {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return false;
            };

            let previous = entry.current_stage.clone();
            let mut next_stage = previous.clone();

            match stage {
                "bootstrap" => next_stage = "direction".to_string(),
                "direction" => next_stage = "plan".to_string(),
                "plan" => next_stage = "implement".to_string(),
                "implement" => next_stage = "verify".to_string(),
                "verify" => next_stage = "judge".to_string(),
                "judge" => {
                    entry.last_judge_result = Some(judge_pass);
                    if judge_pass {
                        entry.terminal_reason_code = None;
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "pass".to_string(),
                        ));
                        next_stage = "report".to_string();
                    } else if entry.verify_iteration + 1 < entry.verify_iteration_limit {
                        entry.terminal_reason_code = None;
                        entry.verify_iteration += 1;
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "fail".to_string(),
                        ));
                        next_stage = "implement".to_string();
                    } else {
                        entry.status = "failed_exhausted".to_string();
                        entry.terminal_reason_code =
                            Some("evo_verify_iteration_exhausted".to_string());
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "fail".to_string(),
                        ));
                        next_stage = "report".to_string();
                    }
                }
                "report" => {
                    if entry.status != "failed_system" {
                        entry.status = if entry.last_judge_result.unwrap_or(false) {
                            entry.terminal_reason_code = None;
                            "completed".to_string()
                        } else {
                            if entry.terminal_reason_code.is_none() {
                                entry.terminal_reason_code = Some("evo_judge_failed".to_string());
                            }
                            "failed_exhausted".to_string()
                        };
                    }
                    let should_start_next_round = entry.status == "completed"
                        && entry.global_loop_round < entry.loop_round_limit;
                    if should_start_next_round {
                        auto_commit_workspace_root = Some(entry.workspace_root.clone());
                        auto_loop_gate = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.workspace_root.clone(),
                            entry.cycle_id.clone(),
                        ));
                    }
                }
                _ => {}
            }

            if stage != "report" {
                entry.current_stage = next_stage.clone();
                stage_changed = Some((
                    entry.project.clone(),
                    entry.workspace.clone(),
                    entry.cycle_id.clone(),
                    next_stage,
                ));
            }
        }

        if let Some((project, workspace, workspace_root, cycle_id)) = auto_loop_gate {
            match self
                .emit_blocking_required_if_any(
                    &project,
                    &workspace,
                    &workspace_root,
                    "auto_loop",
                    Some(&cycle_id),
                    Some("report"),
                    ctx,
                )
                .await
            {
                Ok(true) => {
                    self.interrupt_for_blockers(key, &cycle_id, "workspace_blockers_pending", ctx)
                        .await;
                    return false;
                }
                Ok(false) => {}
                Err(err) => {
                    self.mark_failed_with_code(
                        key,
                        "evo_internal_error",
                        &format!("blocker gate check failed: {}", err),
                        ctx,
                    )
                    .await;
                    return false;
                }
            }
        }

        if let Some(workspace_root) = auto_commit_workspace_root {
            if let Err(err) = self
                .run_auto_commit_before_next_round(&workspace_root, ctx)
                .await
            {
                self.mark_failed_with_code(
                    key,
                    "evo_auto_commit_failed",
                    &format!("auto commit before next round failed: {}", err),
                    ctx,
                )
                .await;
                return false;
            }

            {
                let mut state = self.state.lock().await;
                let Some(entry) = state.workspaces.get_mut(key) else {
                    return false;
                };
                entry.global_loop_round += 1;
                entry.verify_iteration = 0;
                entry.cycle_id = Utc::now().format("%Y-%m-%dT%H-%M-%S-%3fZ").to_string();
                entry.created_at = Utc::now().to_rfc3339();
                entry.current_stage = "direction".to_string();
                entry.status = "queued".to_string();
                entry.last_judge_result = None;
                entry.terminal_reason_code = None;
                entry.llm_defined_acceptance_criteria.clear();
                entry.stage_sessions.clear();
                entry.stage_statuses.clear();
                for s in STAGES {
                    entry
                        .stage_statuses
                        .insert(s.to_string(), "pending".to_string());
                }
                auto_next_cycle = true;
                stage_changed = Some((
                    entry.project.clone(),
                    entry.workspace.clone(),
                    entry.cycle_id.clone(),
                    entry.current_stage.clone(),
                ));
            }
        }

        if let Some((project, workspace, cycle_id, result)) = emit_judge {
            self.broadcast(
                ctx,
                ServerMessage::EvoJudgeResult {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "agent".to_string(),
                    result: result.clone(),
                    reason: if result == "pass" {
                        "judge pass".to_string()
                    } else {
                        "judge fail".to_string()
                    },
                    next_action: if result == "pass" {
                        "goto_stage:report".to_string()
                    } else {
                        "goto_stage:implement".to_string()
                    },
                },
            )
            .await;
        }

        if let Some((project, workspace, cycle_id, to_stage)) = stage_changed {
            self.broadcast(
                ctx,
                ServerMessage::EvoStageChanged {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "orchestrator".to_string(),
                    from_stage: stage.to_string(),
                    to_stage,
                    verify_iteration: self
                        .state
                        .lock()
                        .await
                        .workspaces
                        .get(key)
                        .map(|v| v.verify_iteration)
                        .unwrap_or(0),
                },
            )
            .await;
        }

        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "orchestrator").await;
        self.broadcast_scheduler(ctx).await;
        auto_next_cycle
    }

    pub(super) async fn mark_interrupted(&self, key: &str, ctx: &HandlerContext) {
        let maybe = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return;
            };
            entry.status = "interrupted".to_string();
            entry.stop_requested = true;
            entry.terminal_reason_code = Some("evo_stop_requested".to_string());
            Some((
                entry.project.clone(),
                entry.workspace.clone(),
                entry.cycle_id.clone(),
            ))
        };

        if let Some((project, workspace, cycle_id)) = maybe {
            self.persist_cycle_file(key).await.ok();
            self.broadcast(
                ctx,
                ServerMessage::EvoWorkspaceStopped {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "system".to_string(),
                    status: "interrupted".to_string(),
                    reason: Some("stop_requested".to_string()),
                },
            )
            .await;
            self.broadcast_scheduler(ctx).await;
            self.broadcast_cycle_update(key, ctx, "system").await;
        }
    }

    pub(super) async fn mark_failed_system(&self, key: &str, err: &str, ctx: &HandlerContext) {
        self.mark_failed_with_code(key, "evo_internal_error", err, ctx)
            .await;
    }

    pub(super) async fn mark_failed_with_code(
        &self,
        key: &str,
        code: &str,
        err: &str,
        ctx: &HandlerContext,
    ) {
        let maybe = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return;
            };
            entry.status = "failed_system".to_string();
            entry.terminal_reason_code = Some(code.to_string());
            Some((
                entry.project.clone(),
                entry.workspace.clone(),
                entry.cycle_id.clone(),
            ))
        };

        if let Some((project, workspace, cycle_id)) = maybe {
            self.persist_cycle_file(key).await.ok();
            self.broadcast(
                ctx,
                ServerMessage::EvoError {
                    event_id: Some(Uuid::new_v4().to_string()),
                    event_seq: Some(self.next_seq(key).await),
                    project: Some(project),
                    workspace: Some(workspace),
                    cycle_id: Some(cycle_id),
                    ts: Utc::now().to_rfc3339(),
                    source: "system".to_string(),
                    code: code.to_string(),
                    message: err.to_string(),
                    context: None,
                },
            )
            .await;
            self.broadcast_cycle_update(key, ctx, "system").await;
            self.broadcast_scheduler(ctx).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::{stage::next_stage, STAGES};
    use super::{parse_judge_result_from_json, EvolutionManager};

    #[test]
    fn parse_judge_result_json_schema() {
        let value = serde_json::json!({
            "overall_result": {
                "result": "fail"
            }
        });
        assert_eq!(parse_judge_result_from_json(&value), Some(false));
    }

    #[test]
    fn parse_stage_judge_json_schema() {
        let value = serde_json::json!({
            "decision": {
                "result": "pass"
            }
        });
        assert_eq!(parse_judge_result_from_json(&value), Some(true));
    }

    // ── 六阶段新约束回归测试 ──────────────────────────────────────────────

    #[test]
    fn stages_should_not_contain_bootstrap() {
        // bootstrap 已从 STAGES 集合移除，manager_stage 层回归确认
        assert!(!STAGES.contains(&"bootstrap"), "STAGES 不应包含 bootstrap");
    }

    #[test]
    fn stages_initial_stage_should_be_direction() {
        // 循环起始阶段为 direction（取代旧 bootstrap）
        assert_eq!(STAGES[0], "direction", "初始 stage 应为 direction");
    }

    #[test]
    fn next_stage_report_should_loop_back_to_direction() {
        // report 之后循环回 direction，确保六阶段闭环
        assert_eq!(next_stage("report"), Some("direction"));
    }

    #[test]
    fn next_stage_unknown_should_return_none() {
        // 未知 stage 必须安全返回 None，不可 panic
        assert_eq!(next_stage("bootstrap"), None, "bootstrap 应返回 None");
        assert_eq!(next_stage("unknown"), None, "unknown 应返回 None");
        assert_eq!(next_stage(""), None, "空字符串应返回 None");
    }

    #[test]
    fn extract_acceptance_mapping_criteria_should_work() {
        let input = serde_json::json!({
            "verification_plan": {
                "acceptance_mapping": [
                    {
                        "criteria_id": "ac-1",
                        "description": "desc",
                        "check_ids": ["v-1", "v-5"]
                    }
                ]
            }
        });
        let result = EvolutionManager::extract_acceptance_mapping_criteria(&input)
            .expect("extract criteria should succeed");
        assert_eq!(result.len(), 1);
        assert_eq!(result[0]["criteria_id"], "ac-1");
    }

    #[test]
    fn extract_acceptance_mapping_criteria_should_reject_empty_check_ids() {
        let input = serde_json::json!({
            "verification_plan": {
                "acceptance_mapping": [
                    {
                        "criteria_id": "ac-1",
                        "check_ids": []
                    }
                ]
            }
        });
        let err = EvolutionManager::extract_acceptance_mapping_criteria(&input)
            .expect_err("empty check_ids should fail");
        assert!(
            err.contains("check_ids"),
            "error should mention check_ids, got: {}",
            err
        );
    }
}
