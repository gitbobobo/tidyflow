mod ai;
mod auth;
mod common;
mod evidence;
mod evolution;
mod system;

pub(in crate::server::ws) use ai::{
    ai_agent_list_handler, ai_cross_context_snapshots_handler, ai_provider_list_handler,
    ai_session_config_options_handler, ai_session_context_snapshot_handler,
    ai_session_messages_handler, ai_session_slash_commands_handler, ai_session_status_handler,
    ai_sessions_handler,
};
pub(in crate::server::ws) use evidence::{
    evidence_item_chunk_handler, evidence_rebuild_prompt_handler, evidence_snapshot_handler,
};
pub(in crate::server::ws) use evolution::{
    evolution_agent_profile_handler, evolution_cycle_history_handler, evolution_snapshot_handler,
};
pub(in crate::server::ws) use system::{
    system_health_snapshot_handler, system_repair_handler, system_snapshot_handler,
};
