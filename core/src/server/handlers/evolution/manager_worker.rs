use chrono::{DateTime, Local, NaiveDateTime, TimeZone, Utc};
use tokio::time::{sleep, Duration};
use tracing::{error, warn};

use super::EvolutionManager;
use crate::ai::AiMessage;
use crate::server::context::HandlerContext;
use crate::server::handlers::ai::{ensure_agent, resolve_directory};

const RATE_LIMIT_WAIT_SLICE_MS: i64 = 3_000;
const RATE_LIMIT_WAIT_MIN_MS: i64 = 200;
const RATE_LIMIT_FALLBACK_WAIT_SECS: i64 = 60;
const SESSION_RECOVERY_FALLBACK_WAIT_SECS: i64 = 15;

fn is_terminal_status(status: &str) -> bool {
    matches!(status, "completed" | "failed_exhausted" | "failed_system")
}

fn is_round_limit_exceeded(global_loop_round: u32, loop_round_limit: u32) -> bool {
    let normalized_limit = loop_round_limit.max(1);
    global_loop_round > normalized_limit
}

fn is_rate_limit_error_text(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    (lower.contains("429")
        && (lower.contains("rate limit")
            || lower.contains("too many requests")
            || lower.contains("quota")
            || lower.contains("reset")
            || lower.contains("retry")))
        || text.contains("限额")
        || text.contains("频率限制")
        || text.contains("请求过多")
        || text.contains("速率限制")
}

fn is_retryable_session_error_text(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();

    // 明确排除：这类属于确定性失败，不应该进入自动重试
    if lower.contains("context window")
        || lower.contains("evo_stage_output_invalid")
        || lower.contains("evo_llm_output_unparseable")
    {
        return false;
    }

    lower.contains("stage stream error: unknown error")
        || lower.contains("stage stream timeout")
        || lower.contains("stdout closed")
        || lower.contains("request timeout")
        || lower.contains("connection reset")
        || lower.contains("connection aborted")
        || lower.contains("broken pipe")
        || lower.contains("transport error")
        || lower.contains("network error")
        || lower.contains("service unavailable")
        || text.contains("连接超时")
        || text.contains("连接重置")
        || text.contains("连接中断")
        || text.contains("网络错误")
        || text.contains("服务不可用")
}

fn looks_like_datetime_head(bytes: &[u8], start: usize) -> bool {
    if start + 19 > bytes.len() {
        return false;
    }
    let checks = [
        bytes[start].is_ascii_digit(),
        bytes[start + 1].is_ascii_digit(),
        bytes[start + 2].is_ascii_digit(),
        bytes[start + 3].is_ascii_digit(),
        bytes[start + 4] == b'-',
        bytes[start + 5].is_ascii_digit(),
        bytes[start + 6].is_ascii_digit(),
        bytes[start + 7] == b'-',
        bytes[start + 8].is_ascii_digit(),
        bytes[start + 9].is_ascii_digit(),
        matches!(bytes[start + 10], b'T' | b't' | b' '),
        bytes[start + 11].is_ascii_digit(),
        bytes[start + 12].is_ascii_digit(),
        bytes[start + 13] == b':',
        bytes[start + 14].is_ascii_digit(),
        bytes[start + 15].is_ascii_digit(),
        bytes[start + 16] == b':',
        bytes[start + 17].is_ascii_digit(),
        bytes[start + 18].is_ascii_digit(),
    ];
    checks.into_iter().all(|ok| ok)
}

fn local_naive_to_utc(naive: NaiveDateTime) -> Option<DateTime<Utc>> {
    Local
        .from_local_datetime(&naive)
        .single()
        .or_else(|| Local.from_local_datetime(&naive).earliest())
        .or_else(|| Local.from_local_datetime(&naive).latest())
        .map(|dt| dt.with_timezone(&Utc))
}

fn parse_datetime_at(bytes: &[u8], start: usize) -> Option<DateTime<Utc>> {
    if !looks_like_datetime_head(bytes, start) {
        return None;
    }

    let sep = bytes[start + 10];
    let base = std::str::from_utf8(&bytes[start..start + 19]).ok()?;

    if let Some(marker) = bytes.get(start + 19).copied() {
        if marker == b'Z' || marker == b'z' {
            let mut token = std::str::from_utf8(&bytes[start..start + 20])
                .ok()?
                .to_string();
            if sep == b' ' {
                token.replace_range(10..11, "T");
            }
            if let Ok(dt) = DateTime::parse_from_rfc3339(&token) {
                return Some(dt.with_timezone(&Utc));
            }
        }

        if (marker == b'+' || marker == b'-') && start + 25 <= bytes.len() {
            let tz = &bytes[start + 20..start + 25];
            if tz[0].is_ascii_digit()
                && tz[1].is_ascii_digit()
                && tz[2] == b':'
                && tz[3].is_ascii_digit()
                && tz[4].is_ascii_digit()
            {
                let token = std::str::from_utf8(&bytes[start..start + 25]).ok()?;
                let parsed = if matches!(sep, b'T' | b't') {
                    DateTime::parse_from_str(token, "%Y-%m-%dT%H:%M:%S%:z")
                } else {
                    DateTime::parse_from_str(token, "%Y-%m-%d %H:%M:%S%:z")
                };
                if let Ok(dt) = parsed {
                    return Some(dt.with_timezone(&Utc));
                }
            }
        }

        if (marker == b'+' || marker == b'-') && start + 24 <= bytes.len() {
            let tz = &bytes[start + 20..start + 24];
            if tz.iter().all(|b| b.is_ascii_digit()) {
                let token = std::str::from_utf8(&bytes[start..start + 24]).ok()?;
                let parsed = if matches!(sep, b'T' | b't') {
                    DateTime::parse_from_str(token, "%Y-%m-%dT%H:%M:%S%z")
                } else {
                    DateTime::parse_from_str(token, "%Y-%m-%d %H:%M:%S%z")
                };
                if let Ok(dt) = parsed {
                    return Some(dt.with_timezone(&Utc));
                }
            }
        }
    }

    let fmt = if matches!(sep, b'T' | b't') {
        "%Y-%m-%dT%H:%M:%S"
    } else {
        "%Y-%m-%d %H:%M:%S"
    };
    let naive = NaiveDateTime::parse_from_str(base, fmt).ok()?;
    local_naive_to_utc(naive)
}

fn collect_datetime_candidates(text: &str) -> Vec<(usize, DateTime<Utc>)> {
    let bytes = text.as_bytes();
    if bytes.len() < 19 {
        return Vec::new();
    }
    let mut candidates = Vec::new();
    for idx in 0..=bytes.len() - 19 {
        if let Some(parsed) = parse_datetime_at(bytes, idx) {
            candidates.push((idx, parsed));
        }
    }
    candidates
}

fn collect_rate_limit_keyword_positions(text: &str) -> Vec<usize> {
    let mut positions = Vec::new();
    let lower = text.to_ascii_lowercase();
    for keyword in [
        "429",
        "rate limit",
        "too many requests",
        "quota",
        "reset",
        "retry after",
    ] {
        for (idx, _) in lower.match_indices(keyword) {
            positions.push(idx);
        }
    }
    for keyword in ["429", "限额", "频率限制", "请求过多", "重置", "恢复时间"] {
        for (idx, _) in text.match_indices(keyword) {
            positions.push(idx);
        }
    }
    positions.sort_unstable();
    positions.dedup();
    positions
}

fn select_resume_time(candidates: Vec<DateTime<Utc>>) -> Option<DateTime<Utc>> {
    if candidates.is_empty() {
        return None;
    }
    let now = Utc::now();
    let mut future = candidates
        .iter()
        .filter(|dt| **dt > now)
        .cloned()
        .collect::<Vec<_>>();
    if !future.is_empty() {
        future.sort();
        return future.first().cloned();
    }
    candidates.into_iter().max()
}

fn extract_rate_limit_resume_at_from_text(text: &str) -> Option<DateTime<Utc>> {
    let all = collect_datetime_candidates(text);
    if all.is_empty() {
        return None;
    }

    let keyword_positions = collect_rate_limit_keyword_positions(text);
    let focus_radius: usize = 160;
    let focused = if keyword_positions.is_empty() {
        Vec::new()
    } else {
        all.iter()
            .filter_map(|(idx, dt)| {
                let near_keyword = keyword_positions
                    .iter()
                    .any(|kw| *idx >= kw.saturating_sub(focus_radius) && *idx <= kw + focus_radius);
                if near_keyword {
                    Some(dt.clone())
                } else {
                    None
                }
            })
            .collect::<Vec<_>>()
    };

    if !focused.is_empty() {
        return select_resume_time(focused);
    }
    select_resume_time(all.into_iter().map(|(_, dt)| dt).collect())
}

fn extract_rate_limit_resume_at_from_messages(messages: &[AiMessage]) -> Option<DateTime<Utc>> {
    let mut merged = String::new();
    for message in messages {
        for part in &message.parts {
            if let Some(text) = part.text.as_deref() {
                merged.push_str(text);
                merged.push('\n');
            }
            if let Some(raw) = part.tool_raw_output.as_ref() {
                merged.push_str(&raw.to_string());
                merged.push('\n');
            }
            if let Some(state) = part.tool_state.as_ref() {
                merged.push_str(&state.to_string());
                merged.push('\n');
            }
        }
    }
    extract_rate_limit_resume_at_from_text(&merged)
}

fn truncate_error_message(err: &str, max_chars: usize) -> String {
    if err.chars().count() <= max_chars {
        return err.to_string();
    }
    let mut out = String::with_capacity(max_chars + 3);
    for c in err.chars().take(max_chars) {
        out.push(c);
    }
    out.push_str("...");
    out
}

impl EvolutionManager {
    pub(super) async fn spawn_worker(
        &self,
        key: String,
        preferred_round: u32,
        ctx: HandlerContext,
    ) {
        let mut workers = self.workers.lock().await;
        if workers.contains_key(&key) {
            return;
        }

        let manager = self.clone();
        let worker_key = key.clone();
        let handle = tokio::spawn(async move {
            manager
                .run_workspace(worker_key.clone(), preferred_round, ctx)
                .await;
            let mut workers = manager.workers.lock().await;
            workers.remove(&worker_key);
        });
        workers.insert(key, handle);
    }

    async fn try_extract_rate_limit_resume_at_from_stage_messages(
        &self,
        key: &str,
        stage: &str,
        project: &str,
        workspace: &str,
        ctx: &HandlerContext,
    ) -> Option<DateTime<Utc>> {
        let (ai_tool, session_id) = {
            let state = self.state.lock().await;
            let entry = state.workspaces.get(key)?;
            let session = entry.stage_sessions.get(stage)?;
            (session.ai_tool.clone(), session.session_id.clone())
        };

        let directory = resolve_directory(&ctx.app_state, project, workspace)
            .await
            .ok()?;
        let agent = ensure_agent(&ctx.ai_state, &ai_tool).await.ok()?;
        let messages = agent
            .list_messages(&directory, &session_id, Some(200))
            .await
            .ok()?;
        extract_rate_limit_resume_at_from_messages(&messages)
    }

    async fn handle_rate_limit_error(
        &self,
        key: &str,
        stage: &str,
        project: &str,
        workspace: &str,
        err: &str,
        ctx: &HandlerContext,
    ) -> bool {
        if !is_rate_limit_error_text(err) {
            return false;
        }

        let mut resume_at = extract_rate_limit_resume_at_from_text(err);
        if resume_at.is_none() {
            resume_at = self
                .try_extract_rate_limit_resume_at_from_stage_messages(
                    key, stage, project, workspace, ctx,
                )
                .await;
        }
        let resume_at = resume_at.unwrap_or_else(|| {
            Utc::now() + chrono::Duration::seconds(RATE_LIMIT_FALLBACK_WAIT_SECS)
        });
        let resume_at_rfc3339 = resume_at.to_rfc3339();

        {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return true;
            };
            entry.status = "queued".to_string();
            entry
                .stage_statuses
                .insert(stage.to_string(), "pending".to_string());
            entry.rate_limit_resume_at = Some(resume_at_rfc3339.clone());
            entry.rate_limit_error_message = Some(truncate_error_message(err, 800));
        }

        self.persist_stage_file(key, stage, "rate_limited", Some(err), None)
            .await
            .ok();
        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "system").await;
        self.broadcast_scheduler(ctx).await;

        warn!(
            "evolution stage rate limited: key={}, stage={}, resume_at={}, error={}",
            key, stage, resume_at_rfc3339, err
        );
        true
    }

    async fn handle_retryable_session_error(
        &self,
        key: &str,
        stage: &str,
        err: &str,
        ctx: &HandlerContext,
    ) -> bool {
        if !is_retryable_session_error_text(err) {
            return false;
        }

        let resume_at = Utc::now() + chrono::Duration::seconds(SESSION_RECOVERY_FALLBACK_WAIT_SECS);
        let resume_at_rfc3339 = resume_at.to_rfc3339();

        {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return true;
            };
            entry.status = "queued".to_string();
            entry
                .stage_statuses
                .insert(stage.to_string(), "pending".to_string());
            entry.rate_limit_resume_at = Some(resume_at_rfc3339.clone());
            entry.rate_limit_error_message = Some(truncate_error_message(err, 800));
        }

        self.persist_stage_file(key, stage, "retrying", Some(err), None)
            .await
            .ok();
        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "system").await;
        self.broadcast_scheduler(ctx).await;

        warn!(
            "evolution stage session error scheduled for retry: key={}, stage={}, resume_at={}, error={}",
            key, stage, resume_at_rfc3339, err
        );
        true
    }

    pub(super) async fn run_workspace(
        &self,
        key: String,
        preferred_round: u32,
        ctx: HandlerContext,
    ) {
        loop {
            let mut should_interrupt = false;
            let mut wait_duration: Option<Duration> = None;
            let mut should_emit_recovered = false;
            {
                let mut state = self.state.lock().await;
                let Some(entry) = state.workspaces.get_mut(&key) else {
                    return;
                };
                if entry.stop_requested {
                    should_interrupt = true;
                } else if let Some(resume_at_raw) = entry.rate_limit_resume_at.clone() {
                    match DateTime::parse_from_rfc3339(&resume_at_raw) {
                        Ok(parsed) => {
                            let resume_at = parsed.with_timezone(&Utc);
                            let now = Utc::now();
                            if now < resume_at {
                                entry.status = "queued".to_string();
                                let remaining_ms = (resume_at - now).num_milliseconds();
                                let sleep_ms = remaining_ms
                                    .clamp(RATE_LIMIT_WAIT_MIN_MS, RATE_LIMIT_WAIT_SLICE_MS);
                                wait_duration = Some(Duration::from_millis(sleep_ms as u64));
                            } else {
                                entry.rate_limit_resume_at = None;
                                entry.rate_limit_error_message = None;
                                entry.status = "queued".to_string();
                                should_emit_recovered = true;
                            }
                        }
                        Err(parse_err) => {
                            warn!(
                                "invalid rate_limit_resume_at detected: key={}, value={}, error={}",
                                key, resume_at_raw, parse_err
                            );
                            entry.rate_limit_resume_at = None;
                            entry.rate_limit_error_message = None;
                            should_emit_recovered = true;
                        }
                    }
                }
            }
            if should_interrupt {
                self.mark_interrupted(&key, &ctx).await;
                return;
            }
            if let Some(wait) = wait_duration {
                sleep(wait).await;
                continue;
            }
            if should_emit_recovered {
                self.persist_cycle_file(&key).await.ok();
                self.broadcast_cycle_update(&key, &ctx, "system").await;
                self.broadcast_scheduler(&ctx).await;
            }

            while !self.can_run_with_priority(&key).await {
                sleep(Duration::from_millis(80)).await;
                let should_stop = {
                    let state = self.state.lock().await;
                    state
                        .workspaces
                        .get(&key)
                        .map(|w| w.stop_requested)
                        .unwrap_or(true)
                };
                if should_stop {
                    self.mark_interrupted(&key, &ctx).await;
                    return;
                }
            }

            let permit = match self.semaphore.acquire().await {
                Ok(permit) => permit,
                Err(_) => return,
            };

            let (project, workspace, stage, cycle_id, round, round_limit, round_exceeded) = {
                let mut state = self.state.lock().await;
                let Some(entry) = state.workspaces.get_mut(&key) else {
                    drop(permit);
                    return;
                };
                if is_round_limit_exceeded(entry.global_loop_round, entry.loop_round_limit) {
                    (
                        entry.project.clone(),
                        entry.workspace.clone(),
                        entry.current_stage.clone(),
                        entry.cycle_id.clone(),
                        entry.global_loop_round,
                        entry.loop_round_limit,
                        true,
                    )
                } else {
                    entry.status = "running".to_string();
                    if preferred_round > 0 && entry.global_loop_round < preferred_round {
                        entry.global_loop_round = preferred_round;
                    }
                    (
                        entry.project.clone(),
                        entry.workspace.clone(),
                        entry.current_stage.clone(),
                        entry.cycle_id.clone(),
                        entry.global_loop_round,
                        entry.loop_round_limit,
                        false,
                    )
                }
            };
            if round_exceeded {
                drop(permit);
                self.mark_failed_with_code(
                    &key,
                    "evo_round_limit_exceeded",
                    &format!(
                        "global_loop_round exceeded loop_round_limit: round={}, limit={}, project={}, workspace={}",
                        round, round_limit, project, workspace
                    ),
                    &ctx,
                )
                .await;
                return;
            }

            self.broadcast_scheduler(&ctx).await;
            self.broadcast_cycle_update(&key, &ctx, "orchestrator")
                .await;

            let stage_result = self
                .run_stage(&key, &project, &workspace, &cycle_id, &stage, round, &ctx)
                .await;

            drop(permit);

            match stage_result {
                Ok(judge_pass) => {
                    if self
                        .after_stage_success(&key, &stage, judge_pass, &ctx)
                        .await
                    {
                        continue;
                    }
                }
                Err(err) => {
                    if err.starts_with("evo_human_blocking_required") {
                        let cycle_id = {
                            let state = self.state.lock().await;
                            state
                                .workspaces
                                .get(&key)
                                .map(|w| w.cycle_id.clone())
                                .unwrap_or_default()
                        };
                        self.interrupt_for_blockers(
                            &key,
                            &cycle_id,
                            "workspace_blockers_pending",
                            &ctx,
                        )
                        .await;
                        return;
                    }
                    if self
                        .handle_rate_limit_error(&key, &stage, &project, &workspace, &err, &ctx)
                        .await
                    {
                        continue;
                    }
                    if self
                        .handle_retryable_session_error(&key, &stage, &err, &ctx)
                        .await
                    {
                        continue;
                    }
                    error!(
                        "evolution stage failed: key={}, stage={}, error={}",
                        key, stage, err
                    );
                    self.mark_failed_system(&key, &err, &ctx).await;
                    return;
                }
            }

            let (stop_now, terminal_reached) = {
                let state = self.state.lock().await;
                let stop_now = state
                    .workspaces
                    .get(&key)
                    .map(|w| w.stop_requested)
                    .unwrap_or(true);
                let terminal_reached = state
                    .workspaces
                    .get(&key)
                    .map(|w| is_terminal_status(&w.status))
                    .unwrap_or(true);
                (stop_now, terminal_reached)
            };
            if terminal_reached {
                return;
            }
            if stop_now {
                self.mark_interrupted(&key, &ctx).await;
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use chrono::{Local, TimeZone, Utc};

    use crate::ai::{AiMessage, AiPart};

    use super::{
        extract_rate_limit_resume_at_from_messages, extract_rate_limit_resume_at_from_text,
        is_rate_limit_error_text, is_retryable_session_error_text, is_round_limit_exceeded,
        is_terminal_status,
    };

    #[test]
    fn terminal_status_should_include_failed_exhausted_and_failed_system() {
        assert!(is_terminal_status("completed"));
        assert!(is_terminal_status("failed_exhausted"));
        assert!(is_terminal_status("failed_system"));
        assert!(!is_terminal_status("running"));
        assert!(!is_terminal_status("queued"));
    }

    #[test]
    fn round_limit_guard_should_reject_exceeded_round() {
        assert!(!is_round_limit_exceeded(1, 1));
        assert!(!is_round_limit_exceeded(1, 3));
        assert!(is_round_limit_exceeded(2, 1));
    }

    #[test]
    fn rate_limit_error_detection_should_match_common_text() {
        assert!(is_rate_limit_error_text(
            "Claude exited with status: 1. stderr: API Error: 429 Too Many Requests"
        ));
        assert!(is_rate_limit_error_text(
            "API Error: 429 限额将在 2026-03-01 02:49:41 重置"
        ));
        assert!(!is_rate_limit_error_text("stage stream timeout"));
    }

    #[test]
    fn retryable_session_error_detection_should_match_stream_and_transport_errors() {
        assert!(is_retryable_session_error_text(
            "stage stream error: Unknown error"
        ));
        assert!(is_retryable_session_error_text(
            "Kimi ACP server stdout closed"
        ));
        assert!(is_retryable_session_error_text(
            "stage stream timeout (idle 180s, tool_call_count=60)"
        ));
        assert!(!is_retryable_session_error_text(
            "stage stream error: Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying."
        ));
        assert!(!is_retryable_session_error_text(
            "evo_stage_output_invalid: backlog_coverage 未完整覆盖 failure_backlog"
        ));
    }

    #[test]
    fn extract_rate_limit_resume_at_should_parse_rfc3339() {
        let text = "API Error: 429 Too Many Requests, reset at 2099-01-01T00:00:00Z";
        let parsed = extract_rate_limit_resume_at_from_text(text).expect("should parse timestamp");
        let expected = Utc
            .with_ymd_and_hms(2099, 1, 1, 0, 0, 0)
            .single()
            .expect("valid timestamp");
        assert_eq!(parsed, expected);
    }

    #[test]
    fn extract_rate_limit_resume_at_should_parse_local_datetime_text() {
        let text = "API Error: 429 限额将在 2026-03-01 02:49:41 重置";
        let parsed = extract_rate_limit_resume_at_from_text(text).expect("should parse timestamp");
        let local_text = parsed
            .with_timezone(&Local)
            .format("%Y-%m-%d %H:%M:%S")
            .to_string();
        assert_eq!(local_text, "2026-03-01 02:49:41");
    }

    #[test]
    fn extract_rate_limit_resume_at_should_read_from_messages() {
        let messages = vec![AiMessage {
            id: "m1".to_string(),
            role: "assistant".to_string(),
            created_at: None,
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts: vec![AiPart {
                id: "p1".to_string(),
                part_type: "text".to_string(),
                text: Some("429 reset at 2099-05-06T07:08:09Z".to_string()),
                ..Default::default()
            }],
        }];

        let parsed =
            extract_rate_limit_resume_at_from_messages(&messages).expect("should parse timestamp");
        let expected = Utc
            .with_ymd_and_hms(2099, 5, 6, 7, 8, 9)
            .single()
            .expect("valid timestamp");
        assert_eq!(parsed, expected);
    }
}
