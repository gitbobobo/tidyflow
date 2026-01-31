use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Input { data_b64: String },
    Resize { cols: u16, rows: u16 },
    Ping,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Hello {
        version: u32,
        session_id: String,
        shell: String,
    },
    Output { data_b64: String },
    Exit { code: i32 },
    Pong,
}
