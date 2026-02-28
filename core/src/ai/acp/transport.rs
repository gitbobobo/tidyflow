use crate::ai::codex::manager::{
    AcpInitializationState, AppServerRequestError, CodexAppServerManager, CodexNotification,
    CodexServerRequest,
};
use async_trait::async_trait;
use serde_json::Value;
use tokio::sync::broadcast;

#[async_trait]
pub(crate) trait AcpTransport: Send + Sync {
    async fn ensure_server_running(&self) -> Result<(), String>;
    async fn send_request_with_error(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, AppServerRequestError>;
    async fn send_notification(&self, method: &str, params: Option<Value>) -> Result<(), String>;
    async fn send_response(&self, id: Value, result: Value) -> Result<(), String>;
    fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification>;
    fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest>;
    async fn acp_initialization_state(&self) -> Option<AcpInitializationState>;
    async fn set_acp_authenticated(&self, authenticated: bool);
}

#[async_trait]
impl AcpTransport for CodexAppServerManager {
    async fn ensure_server_running(&self) -> Result<(), String> {
        CodexAppServerManager::ensure_server_running(self).await
    }

    async fn send_request_with_error(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, AppServerRequestError> {
        CodexAppServerManager::send_request_with_error(self, method, params).await
    }

    async fn send_notification(&self, method: &str, params: Option<Value>) -> Result<(), String> {
        CodexAppServerManager::send_notification(self, method, params).await
    }

    async fn send_response(&self, id: Value, result: Value) -> Result<(), String> {
        CodexAppServerManager::send_response(self, id, result).await
    }

    fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification> {
        CodexAppServerManager::subscribe_notifications(self)
    }

    fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest> {
        CodexAppServerManager::subscribe_requests(self)
    }

    async fn acp_initialization_state(&self) -> Option<AcpInitializationState> {
        CodexAppServerManager::acp_initialization_state(self).await
    }

    async fn set_acp_authenticated(&self, authenticated: bool) {
        CodexAppServerManager::set_acp_authenticated(self, authenticated).await;
    }
}
