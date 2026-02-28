use crate::ai::acp::cache::{self, CachedSessionRecord};
use crate::ai::acp::client::{
    AcpClient, AcpConfigOptionInfo, AcpSessionMetadata, AcpSessionSummary,
};
use crate::ai::acp::metadata_state;
use crate::ai::acp::permissions::{self, PendingPermission, PermissionOption};
use crate::ai::acp::plan::{self, AcpPlanEntry, AcpPlanSnapshot};
use crate::ai::acp::prompt_builder;
use crate::ai::acp::stream_mapping;
use crate::ai::acp::tool_call::{self, ParsedToolCallUpdate};
use crate::ai::codex::manager::{AcpContentEncodingMode, CodexAppServerManager};
use crate::ai::context_usage::{extract_context_remaining_percent, AiSessionContextUsage};
use crate::ai::shared::path_norm::normalize_directory_with_file_url as shared_normalize_directory;
use crate::ai::{
    AiAgent, AiAgentInfo, AiAudioPart, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiQuestionRequest, AiSession, AiSessionConfigOption,
    AiSessionConfigOptionChoice, AiSessionConfigOptionChoiceGroup, AiSessionConfigValue,
    AiSessionSelectionHint, AiSlashCommand,
};
use async_trait::async_trait;
use chrono::Utc;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use tokio::time::Duration;
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::{debug, warn};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct AcpBackendProfile {
    pub tool_id: String,
    pub provider_id: String,
    pub provider_name: String,
    pub message_id_prefix: String,
}

impl AcpBackendProfile {
    pub fn copilot() -> Self {
        Self {
            tool_id: "copilot".to_string(),
            provider_id: "copilot".to_string(),
            provider_name: "Copilot".to_string(),
            message_id_prefix: "copilot".to_string(),
        }
    }

    pub fn kimi() -> Self {
        Self {
            tool_id: "kimi".to_string(),
            provider_id: "kimi".to_string(),
            provider_name: "Kimi".to_string(),
            message_id_prefix: "kimi".to_string(),
        }
    }
}

static UNKNOWN_CONTENT_TYPE_COUNT: AtomicU64 = AtomicU64::new(0);
static TOOL_CALL_UPDATE_MISSING_ID_COUNT: AtomicU64 = AtomicU64::new(0);
static FOLLOW_ALONG_CREATE_FAILURE_COUNT: AtomicU64 = AtomicU64::new(0);
static FOLLOW_ALONG_RELEASE_FAILURE_COUNT: AtomicU64 = AtomicU64::new(0);

pub struct AcpAgent {
    client: AcpClient,
    profile: AcpBackendProfile,
    metadata_by_directory: Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
    metadata_by_session: Arc<Mutex<HashMap<String, AcpSessionMetadata>>>,
    slash_commands_by_directory: Arc<Mutex<HashMap<String, Vec<AiSlashCommand>>>>,
    slash_commands_by_session: Arc<Mutex<HashMap<String, Vec<AiSlashCommand>>>>,
    pending_permissions: Arc<Mutex<HashMap<String, PendingPermission>>>,
    cached_sessions: Arc<Mutex<HashMap<String, HashMap<String, CachedSessionRecord>>>>,
    runtime_yolo_sessions: Arc<Mutex<HashSet<String>>>,
}

impl AcpAgent {
    const SESSION_LOAD_TIMEOUT_SECS: u64 = 4;
    const PLAN_HISTORY_LIMIT: usize = 20;
    const EMBED_TEXT_LIMIT_BYTES: usize = 256 * 1024;
    const EMBED_BLOB_LIMIT_BYTES: usize = 1024 * 1024;

    pub fn new(manager: Arc<CodexAppServerManager>, profile: AcpBackendProfile) -> Self {
        Self {
            client: AcpClient::new(manager),
            profile,
            metadata_by_directory: Arc::new(Mutex::new(HashMap::new())),
            metadata_by_session: Arc::new(Mutex::new(HashMap::new())),
            slash_commands_by_directory: Arc::new(Mutex::new(HashMap::new())),
            slash_commands_by_session: Arc::new(Mutex::new(HashMap::new())),
            pending_permissions: Arc::new(Mutex::new(HashMap::new())),
            cached_sessions: Arc::new(Mutex::new(HashMap::new())),
            runtime_yolo_sessions: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    pub fn new_copilot(manager: Arc<CodexAppServerManager>) -> Self {
        Self::new(manager, AcpBackendProfile::copilot())
    }

    pub fn new_kimi(manager: Arc<CodexAppServerManager>) -> Self {
        Self::new(manager, AcpBackendProfile::kimi())
    }

    fn normalize_directory(directory: &str) -> String {
        shared_normalize_directory(directory)
    }

    fn session_cache_key(directory: &str, session_id: &str) -> String {
        format!("{}::{}", Self::normalize_directory(directory), session_id)
    }

    fn should_auto_enable_runtime_yolo(&self) -> bool {
        self.profile.tool_id == "kimi"
    }

    async fn ensure_runtime_yolo_for_session(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<(), String> {
        if !self.should_auto_enable_runtime_yolo() {
            return Ok(());
        }

        let session_key = Self::session_cache_key(directory, session_id);
        {
            let sessions = self.runtime_yolo_sessions.lock().await;
            if sessions.contains(&session_key) {
                return Ok(());
            }
        }

        let yolo_prompt = vec![serde_json::json!({
            "type": "text",
            "text": "/yolo"
        })];
        let supports_load_session = self.client.supports_load_session().await;
        let result = match self
            .client
            .session_prompt(session_id, yolo_prompt.clone(), None, None)
            .await
        {
            Ok(_) => Ok(()),
            Err(err) if Self::is_session_not_found(&err) => {
                if supports_load_session {
                    self.client.session_load(directory, session_id).await?;
                    self.client
                        .session_prompt(session_id, yolo_prompt, None, None)
                        .await
                        .map(|_| ())
                } else {
                    Err(err)
                }
            }
            Err(err) => Err(err),
        };

        match result {
            Ok(()) => {
                self.runtime_yolo_sessions.lock().await.insert(session_key);
                Ok(())
            }
            Err(err) => Err(format!("enable kimi runtime yolo failed: {}", err)),
        }
    }
}

mod ai_agent_impl;
mod core_ops;

#[cfg(test)]
mod tests;
