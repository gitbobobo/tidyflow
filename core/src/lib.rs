// 抑制不影响功能正确性的 Clippy 结构性警告
#![allow(
    clippy::too_many_arguments,
    clippy::type_complexity,
    clippy::large_enum_variant,
    clippy::items_after_test_module,
    clippy::module_inception,
    clippy::enum_variant_names,
    clippy::field_reassign_with_default,
    clippy::collapsible_str_replace,
    clippy::collapsible_if,
    clippy::clone_on_copy,
    clippy::manual_is_multiple_of,
    clippy::manual_contains,
    clippy::manual_range_contains,
    clippy::new_without_default,
    clippy::redundant_closure,
    clippy::needless_lifetimes,
    clippy::question_mark,
    clippy::unnecessary_map_or,
    clippy::absurd_extreme_comparisons,
    clippy::unnecessary_lazy_evaluations,
    clippy::useless_format
)]

pub mod ai;
pub mod application;
pub mod coordinator;
pub mod pty;
pub mod server;
pub mod util;
pub mod workspace;

pub use ai::OpenCodeAgent;
pub use ai::OpenCodeManager;
pub use ai::{CodexAppServerAgent, CodexAppServerManager};
pub use pty::{resize_pty, PtySession};
