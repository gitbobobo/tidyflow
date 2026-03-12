mod auth;
mod handlers;
mod model;
mod store;

pub(in crate::server::ws) use auth::{authorize_token, is_ws_token_authorized};
pub(in crate::server::ws) use handlers::{
    create_api_key_handler, delete_api_key_handler, list_api_keys_handler,
};
pub(in crate::server::ws) use model::{SharedRemoteAPIKeyRegistry, WsAuthQuery};
pub(in crate::server::ws) use store::{
    new_api_key_registry, touch_api_key_last_used,
};
