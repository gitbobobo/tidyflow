pub mod adapter;
pub mod auth;
pub mod cache;
pub mod client;
pub mod metadata_parser;
pub mod metadata_state;
pub mod permissions;
pub mod plan;
pub mod prompt_builder;
pub mod prompt_parts;
pub mod stream_mapping;
pub mod tool_call;
pub mod transport;

pub use adapter::{AcpAgent, AcpBackendProfile};
pub use client::{
    AcpClient, AcpConfigOptionChoice, AcpConfigOptionGroup, AcpConfigOptionInfo, AcpModeInfo,
    AcpModelInfo, AcpSessionMetadata, AcpSessionSummary,
};
