pub(super) const STAGES: [&str; 6] = [
    "direction",
    "plan",
    "implement",
    "verify",
    "judge",
    "report",
];

pub(super) const MAX_STAGE_RUNTIME_SECS: u64 = 3600;
pub(super) const DEFAULT_VERIFY_LIMIT: u32 = 5;
pub(super) const DEFAULT_LOOP_ROUND_LIMIT: u32 = 1;
pub(super) const DEFAULT_MAX_PARALLEL: u32 = 4;
