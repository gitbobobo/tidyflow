use std::cmp::Ordering;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(super) enum ImplementationStageKind {
    General,
    Visual,
    Advanced,
}

impl ImplementationStageKind {
    pub(super) fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "general" | "implement_general" => Some(Self::General),
            "visual" | "implement_visual" => Some(Self::Visual),
            "advanced" | "implement_advanced" => Some(Self::Advanced),
            _ => None,
        }
    }

    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::General => "general",
            Self::Visual => "visual",
            Self::Advanced => "advanced",
        }
    }

    pub(super) fn profile_stage(self) -> &'static str {
        match self {
            Self::General => "implement_general",
            Self::Visual => "implement_visual",
            Self::Advanced => "implement_advanced",
        }
    }
}

pub(super) const STAGES: [&str; 3] = ["direction", "plan", "auto_commit"];

pub(super) const PROFILE_STAGES: [&str; 7] = [
    "direction",
    "plan",
    "implement_general",
    "implement_visual",
    "implement_advanced",
    "verify",
    "auto_commit",
];

pub(super) const IMPLEMENTATION_STAGE_KINDS: [ImplementationStageKind; 2] = [
    ImplementationStageKind::General,
    ImplementationStageKind::Visual,
];

pub(super) const MAX_STAGE_RUNTIME_SECS: u64 = 10_800;
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

pub(super) fn parse_implement_stage_instance(
    stage: &str,
) -> Option<(ImplementationStageKind, u32)> {
    let mut parts = stage.trim().split('.');
    let prefix = parts.next()?;
    let kind = parts.next()?;
    let index = parts.next()?;
    if prefix != "implement" || parts.next().is_some() {
        return None;
    }
    let kind = ImplementationStageKind::parse(kind)?;
    let index = index.parse::<u32>().ok()?;
    if index == 0 || kind == ImplementationStageKind::Advanced {
        return None;
    }
    Some((kind, index))
}

pub(super) fn parse_reimplement_stage_instance(stage: &str) -> Option<u32> {
    let mut parts = stage.trim().split('.');
    let prefix = parts.next()?;
    let index = parts.next()?;
    if prefix != "reimplement" || parts.next().is_some() {
        return None;
    }
    let index = index.parse::<u32>().ok()?;
    (index > 0).then_some(index)
}

pub(super) fn parse_verify_stage_instance(stage: &str) -> Option<u32> {
    let mut parts = stage.trim().split('.');
    let prefix = parts.next()?;
    let index = parts.next()?;
    if prefix != "verify" || parts.next().is_some() {
        return None;
    }
    let index = index.parse::<u32>().ok()?;
    (index > 0).then_some(index)
}

pub(super) fn implement_stage_name(kind: ImplementationStageKind, index: u32) -> String {
    format!("implement.{}.{}", kind.as_str(), index)
}

pub(super) fn reimplement_stage_name(index: u32) -> String {
    format!("reimplement.{}", index)
}

pub(super) fn verify_stage_name(index: u32) -> String {
    format!("verify.{}", index)
}

fn kind_sort_rank(kind: ImplementationStageKind) -> u8 {
    match kind {
        ImplementationStageKind::General => 0,
        ImplementationStageKind::Visual => 1,
        ImplementationStageKind::Advanced => 2,
    }
}

pub(super) fn compare_runtime_stage_names(left: &str, right: &str) -> Ordering {
    fn stage_key(stage: &str) -> (u8, u32, u8, String) {
        match stage.trim() {
            "direction" => (0, 0, 0, String::new()),
            "plan" => (1, 0, 0, String::new()),
            "auto_commit" => (5, 0, 0, String::new()),
            other => {
                if let Some((kind, index)) = parse_implement_stage_instance(other) {
                    return (2, index, kind_sort_rank(kind), String::new());
                }
                if let Some(index) = parse_reimplement_stage_instance(other) {
                    return (3, index, 0, String::new());
                }
                if let Some(index) = parse_verify_stage_instance(other) {
                    return (4, index, 0, String::new());
                }
                (6, 0, 0, other.to_string())
            }
        }
    }

    stage_key(left).cmp(&stage_key(right))
}

pub(super) fn stage_profile_stage(stage: &str) -> Option<String> {
    let normalized = stage.trim();
    if PROFILE_STAGES.contains(&normalized) {
        return Some(normalized.to_string());
    }
    if let Some((kind, _)) = parse_implement_stage_instance(normalized) {
        return Some(kind.profile_stage().to_string());
    }
    if parse_reimplement_stage_instance(normalized).is_some() {
        return Some(
            ImplementationStageKind::Advanced
                .profile_stage()
                .to_string(),
        );
    }
    if parse_verify_stage_instance(normalized).is_some() {
        return Some("verify".to_string());
    }
    None
}

pub(super) fn stage_artifact_file(stage: &str) -> Option<String> {
    match stage.trim() {
        "direction" => Some("direction.jsonc".to_string()),
        "plan" => Some("plan.jsonc".to_string()),
        "auto_commit" => Some("auto_commit.jsonc".to_string()),
        "implement_general" => Some("implement_general.jsonc".to_string()),
        "implement_visual" => Some("implement_visual.jsonc".to_string()),
        "implement_advanced" => Some("implement_advanced.jsonc".to_string()),
        other => {
            if let Some((kind, index)) = parse_implement_stage_instance(other) {
                return Some(format!("implement.{}.{}.jsonc", kind.as_str(), index));
            }
            if let Some(index) = parse_reimplement_stage_instance(other) {
                return Some(format!("reimplement.{}.jsonc", index));
            }
            if let Some(index) = parse_verify_stage_instance(other) {
                return Some(format!("verify.{}.jsonc", index));
            }
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::stage_profile_stage;

    #[test]
    fn reimplement_stage_should_always_map_to_advanced_profile() {
        assert_eq!(
            stage_profile_stage("reimplement.1").as_deref(),
            Some("implement_advanced")
        );
        assert_eq!(
            stage_profile_stage("reimplement.2").as_deref(),
            Some("implement_advanced")
        );
    }

    #[test]
    fn verify_stage_should_still_map_to_verify_profile() {
        assert_eq!(stage_profile_stage("verify.1").as_deref(), Some("verify"));
    }
}
