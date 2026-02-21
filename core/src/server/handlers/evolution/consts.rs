pub(super) const STAGES: [&str; 7] = [
    "bootstrap",
    "direction",
    "plan",
    "implement",
    "verify",
    "judge",
    "report",
];

pub(super) const MAX_STAGE_RUNTIME_SECS: u64 = 600;
pub(super) const DEFAULT_VERIFY_LIMIT: u32 = 3;
pub(super) const DEFAULT_MAX_PARALLEL: u32 = 4;
