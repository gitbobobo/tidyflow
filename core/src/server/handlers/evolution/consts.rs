pub(super) const STAGES: [&str; 7] = [
    "direction",
    "plan",
    "implement_general",
    "implement_visual",
    "implement_advanced",
    "verify",
    "auto_commit",
];

pub(super) const MAX_STAGE_RUNTIME_SECS: u64 = 3600;
pub(super) const DEFAULT_VERIFY_LIMIT: u32 = 5;
pub(super) const DEFAULT_LOOP_ROUND_LIMIT: u32 = 1;
pub(super) const DEFAULT_MAX_PARALLEL: u32 = 4;
pub(super) const BACKLOG_CONTRACT_VERSION_V2: u32 = 2;

// 阶段失败重试：最多 3 次，指数退避，上限 30 秒
pub(super) const MAX_SESSION_RETRY_ATTEMPTS: u32 = 3;
pub(super) const SESSION_RETRY_BACKOFF_BASE_SECS: u64 = 2;
pub(super) const SESSION_RETRY_BACKOFF_MAX_SECS: u64 = 30;

// 关键阶段产物要求的 schema 版本
pub(super) const STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION: &str = "2.0";
pub(super) const MANAGED_BACKLOG_FILE: &str = "managed.backlog.jsonc";

pub(super) fn stage_artifact_file(stage: &str) -> Option<&'static str> {
    match stage {
        "direction" => Some("direction.jsonc"),
        "plan" => Some("plan.jsonc"),
        "implement_general" => Some("implement_general.jsonc"),
        "implement_visual" => Some("implement_visual.jsonc"),
        "implement_advanced" => Some("implement_advanced.jsonc"),
        "verify" => Some("verify.jsonc"),
        "auto_commit" => Some("auto_commit.jsonc"),
        _ => None,
    }
}
