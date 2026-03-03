use super::process::KimiWireProcess;
use super::protocol::{
    is_unsupported_protocol_version, parse_initialize_result, KimiWireEvent, KimiWireRequest,
    WireRequestError,
};
use crate::ai::AiSlashCommand;
use async_trait::async_trait;
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::{broadcast, Mutex};

const NEGOTIATION_PROTOCOL_VERSIONS: [&str; 4] = ["1.4", "1.3", "1.2", "1"];

#[async_trait]
pub trait KimiWireTransport: Send + Sync {
    async fn ensure_running(&self) -> Result<(), String>;
    async fn stop(&self) -> Result<(), String>;
    async fn send_request_with_error(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, WireRequestError>;
    async fn send_notification(&self, method: &str, params: Option<Value>) -> Result<(), String>;
    async fn send_response(&self, id: Value, result: Value) -> Result<(), String>;
    fn subscribe_events(&self) -> broadcast::Receiver<KimiWireEvent>;
    fn subscribe_requests(&self) -> broadcast::Receiver<KimiWireRequest>;
}

#[async_trait]
impl KimiWireTransport for KimiWireProcess {
    async fn ensure_running(&self) -> Result<(), String> {
        KimiWireProcess::ensure_running(self).await
    }

    async fn stop(&self) -> Result<(), String> {
        KimiWireProcess::stop(self).await
    }

    async fn send_request_with_error(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, WireRequestError> {
        KimiWireProcess::send_request_with_error(self, method, params).await
    }

    async fn send_notification(&self, method: &str, params: Option<Value>) -> Result<(), String> {
        KimiWireProcess::send_notification(self, method, params).await
    }

    async fn send_response(&self, id: Value, result: Value) -> Result<(), String> {
        KimiWireProcess::send_response(self, id, result).await
    }

    fn subscribe_events(&self) -> broadcast::Receiver<KimiWireEvent> {
        KimiWireProcess::subscribe_events(self)
    }

    fn subscribe_requests(&self) -> broadcast::Receiver<KimiWireRequest> {
        KimiWireProcess::subscribe_requests(self)
    }
}

#[derive(Debug, Clone, Default)]
pub struct KimiWireClientStateSnapshot {
    pub initialized: bool,
    pub initialize_optional: bool,
    pub protocol_version: Option<String>,
    pub supports_question: bool,
    pub slash_commands: Vec<AiSlashCommand>,
}

#[derive(Debug, Clone, Default)]
struct KimiWireClientState {
    initialized: bool,
    initialize_optional: bool,
    protocol_version: Option<String>,
    supports_question: bool,
    slash_commands: Vec<AiSlashCommand>,
}

#[derive(Clone)]
pub struct KimiWireClient {
    transport: Arc<dyn KimiWireTransport>,
    state: Arc<Mutex<KimiWireClientState>>,
    init_lock: Arc<Mutex<()>>,
}

impl KimiWireClient {
    pub fn new(process: Arc<KimiWireProcess>) -> Self {
        Self::new_with_transport(process)
    }

    pub fn new_with_transport(transport: Arc<dyn KimiWireTransport>) -> Self {
        Self {
            transport,
            state: Arc::new(Mutex::new(KimiWireClientState::default())),
            init_lock: Arc::new(Mutex::new(())),
        }
    }

    pub async fn ensure_started(&self) -> Result<(), String> {
        self.transport.ensure_running().await
    }

    pub async fn stop(&self) -> Result<(), String> {
        self.transport.stop().await
    }

    pub async fn ensure_initialized(&self) -> Result<(), String> {
        {
            let state = self.state.lock().await;
            if state.initialized {
                return Ok(());
            }
        }

        let _guard = self.init_lock.lock().await;
        {
            let state = self.state.lock().await;
            if state.initialized {
                return Ok(());
            }
        }

        self.transport.ensure_running().await?;

        let mut last_error: Option<String> = None;
        for protocol_version in NEGOTIATION_PROTOCOL_VERSIONS {
            let params = serde_json::json!({
                "protocol_version": protocol_version,
                "client_capabilities": {
                    "supports_question": true
                }
            });
            match self
                .transport
                .send_request_with_error("initialize", Some(params))
                .await
            {
                Ok(result) => {
                    let mut parsed = parse_initialize_result(&result);
                    if parsed.protocol_version.is_none() {
                        parsed.protocol_version = Some(protocol_version.to_string());
                    }
                    let mut state = self.state.lock().await;
                    state.initialized = true;
                    state.initialize_optional = false;
                    state.protocol_version = parsed.protocol_version;
                    state.supports_question = parsed.supports_question;
                    state.slash_commands = parsed.slash_commands;
                    return Ok(());
                }
                Err(WireRequestError::Rpc(err)) if err.code == -32601 => {
                    let mut state = self.state.lock().await;
                    state.initialized = true;
                    state.initialize_optional = true;
                    state.protocol_version = None;
                    state.supports_question = false;
                    state.slash_commands.clear();
                    return Ok(());
                }
                Err(WireRequestError::Rpc(err)) if is_unsupported_protocol_version(&err) => {
                    last_error = Some(format!(
                        "protocol_version={} unsupported by server",
                        protocol_version
                    ));
                    continue;
                }
                Err(err) => {
                    return Err(err.to_user_string());
                }
            }
        }

        Err(last_error.unwrap_or_else(|| {
            "Kimi Wire initialize failed: no compatible protocol version".to_string()
        }))
    }

    pub async fn state_snapshot(&self) -> KimiWireClientStateSnapshot {
        let state = self.state.lock().await;
        KimiWireClientStateSnapshot {
            initialized: state.initialized,
            initialize_optional: state.initialize_optional,
            protocol_version: state.protocol_version.clone(),
            supports_question: state.supports_question,
            slash_commands: state.slash_commands.clone(),
        }
    }

    pub async fn slash_commands(&self) -> Vec<AiSlashCommand> {
        self.state_snapshot().await.slash_commands
    }

    pub async fn supports_question(&self) -> bool {
        self.state_snapshot().await.supports_question
    }

    pub async fn prompt(&self, user_input: String) -> Result<Value, String> {
        self.ensure_initialized().await?;
        self.transport
            .send_request_with_error(
                "prompt",
                Some(serde_json::json!({
                    "user_input": user_input
                })),
            )
            .await
            .map_err(|e| e.to_user_string())
    }

    pub async fn replay(&self, max_events: Option<u32>) -> Result<Value, String> {
        self.ensure_initialized().await?;
        let params = max_events.map(|value| serde_json::json!({ "max_events": value }));
        self.transport
            .send_request_with_error("replay", params)
            .await
            .map_err(|e| e.to_user_string())
    }

    pub async fn steer(&self, user_input: String) -> Result<Value, String> {
        self.ensure_initialized().await?;
        self.transport
            .send_request_with_error(
                "steer",
                Some(serde_json::json!({
                    "user_input": user_input
                })),
            )
            .await
            .map_err(|e| e.to_user_string())
    }

    pub async fn cancel(&self) -> Result<(), String> {
        self.ensure_initialized().await?;
        self.transport
            .send_request_with_error("cancel", None)
            .await
            .map(|_| ())
            .map_err(|e| e.to_user_string())
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<KimiWireEvent> {
        self.transport.subscribe_events()
    }

    pub fn subscribe_requests(&self) -> broadcast::Receiver<KimiWireRequest> {
        self.transport.subscribe_requests()
    }

    pub async fn respond_approval(
        &self,
        jsonrpc_id: Value,
        approved: bool,
        request_id: String,
    ) -> Result<(), String> {
        self.transport
            .send_response(
                jsonrpc_id,
                serde_json::json!({
                    "request_id": request_id,
                    "response": if approved { "approve" } else { "reject" }
                }),
            )
            .await
    }

    pub async fn send_notification(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<(), String> {
        self.ensure_started().await?;
        self.transport.send_notification(method, params).await
    }
}
