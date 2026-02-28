use crate::ai::codex::manager::AppServerRequestError;

const AUTH_REQUIRED_CODE: i64 = -32000;

pub(crate) fn is_auth_required_error(error: &AppServerRequestError) -> bool {
    matches!(error, AppServerRequestError::Rpc(rpc_error) if rpc_error.code == AUTH_REQUIRED_CODE)
}
