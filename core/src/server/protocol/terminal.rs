//! 终端领域协议类型

use serde::{Deserialize, Serialize};

/// 终端相关的客户端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TerminalRequest {
    Input {
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    Resize {
        cols: u16,
        rows: u16,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    SpawnTerminal {
        cwd: String,
    },
    KillTerminal,
    TermCreate {
        project: String,
        workspace: String,
    },
    TermList,
    TermClose {
        term_id: String,
    },
    TermFocus {
        term_id: String,
    },
    TermAttach {
        term_id: String,
    },
    TermOutputAck {
        term_id: String,
        bytes: u64,
    },
}

/// 终端相关的服务端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TerminalResponse {
    TerminalSpawned {
        session_id: String,
        shell: String,
        cwd: String,
    },
    TerminalKilled {
        session_id: String,
    },
    TermCreated {
        term_id: String,
        project: String,
        workspace: String,
        cwd: String,
        shell: String,
    },
    TermList {
        items: Vec<super::TerminalInfo>,
    },
    TermClosed {
        term_id: String,
    },
    TermAttached {
        term_id: String,
        project: String,
        workspace: String,
        cwd: String,
        shell: String,
        #[serde(with = "serde_bytes")]
        scrollback: Vec<u8>,
    },
    Output {
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    Exit {
        code: i32,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
}
