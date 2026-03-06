use crate::ai::codex::client::{CodexAppServerClient, CodexModelInfo};
use crate::ai::codex::manager::CodexAppServerManager;
use crate::ai::codex::{question, selection_hint, stream, tool_mapping};
use crate::ai::context_usage::{extract_context_remaining_percent, AiSessionContextUsage};
use crate::ai::session_status::AiSessionStatus;
use crate::ai::shared::audio_fallback::append_audio_fallback_text as shared_append_audio_fallback_text;
use crate::ai::shared::json_search::json_value_to_trimmed_string as shared_json_value_to_trimmed_string;
use crate::ai::shared::request_id::request_id_key as shared_request_id_key;
use crate::ai::{
    AiAgent, AiAgentInfo, AiAudioPart, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiQuestionRequest, AiSession, AiSessionConfigOption,
    AiSessionConfigOptionChoice, AiSessionConfigValue, AiSessionSelectionHint, AiSlashCommand,
};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::{debug, info, warn};
use uuid::Uuid;

#[derive(Debug, Clone)]
struct PendingApproval {
    id: Value,
    method: String,
    question_ids: Vec<String>,
    session_id: String,
    tool_message_id: Option<String>,
}

pub struct CodexAppServerAgent {
    client: CodexAppServerClient,
    pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
    active_turns: Arc<Mutex<HashMap<String, String>>>,
    selection_hints: Arc<Mutex<HashMap<String, AiSessionSelectionHint>>>,
    context_usage_by_session: Arc<Mutex<HashMap<String, AiSessionContextUsage>>>,
}

mod ai_agent_impl;
mod core_ops;

#[cfg(test)]
mod tests;
