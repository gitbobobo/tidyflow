use axum::extract::ws::WebSocket;
use tracing::{trace, warn};

use crate::server::context::HandlerContext;
use crate::server::protocol::domain_table::parse_domain_route;
use crate::server::protocol::{ClientEnvelopeV6, ClientMessage, ServerMessage};
use crate::server::ws::send_message;

mod audit;
mod envelope;
mod router;
mod shared_types;

pub(super) fn probe_client_message_type(data: &[u8]) -> String {
    envelope::probe_client_message_type(data)
}

struct DispatchInput {
    envelope: ClientEnvelopeV6,
    route: crate::server::protocol::domain_table::DomainRoute,
    client_msg: ClientMessage,
}

fn build_dispatch_input(data: &[u8]) -> Result<DispatchInput, String> {
    let envelope = envelope::decode_and_validate_envelope(data)?;
    let route = parse_domain_route(&envelope.domain)
        .ok_or_else(|| format!("Unknown domain: {}", envelope.domain))?;
    if !envelope::action_matches_domain(&envelope.domain, &envelope.action) {
        return Err(format!(
            "Action/domain mismatch: action={} domain={}",
            envelope.action, envelope.domain
        ));
    }
    let client_msg = envelope::envelope_payload_to_client_message(&envelope)?;
    Ok(DispatchInput {
        envelope,
        route,
        client_msg,
    })
}

async fn dispatch_parsed_message(
    route: crate::server::protocol::domain_table::DomainRoute,
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
    watcher: &shared_types::DispatchWatcher,
) -> Result<bool, String> {
    router::dispatch_domain_handler(route, client_msg, socket, ctx, watcher).await
}

async fn send_unhandled_message(socket: &mut WebSocket) -> Result<(), String> {
    send_message(
        socket,
        &ServerMessage::Error {
            code: "unhandled_message".to_string(),
            message: "Message type not recognized".to_string(),
        },
    )
    .await
}

/// Handle a client message — 统一调度层
///
/// v6：客户端消息统一使用 `ClientEnvelopeV6`
pub(super) async fn handle_client_message(
    data: &[u8],
    socket: &mut WebSocket,
    ctx: &HandlerContext,
    watcher: &shared_types::DispatchWatcher,
) -> Result<(), String> {
    trace!(
        "handle_client_message called with data length: {}",
        data.len()
    );

    let input = build_dispatch_input(data)?;
    let request_id = input.envelope.request_id.clone();

    crate::server::ws::with_request_id(Some(request_id), async {
        trace!(
            "Parsed client message: domain={}, action={}, discriminant={:?}",
            input.envelope.domain,
            input.envelope.action,
            std::mem::discriminant(&input.client_msg)
        );

        audit::log_ai_control_message(&input.client_msg, ctx);

        if !dispatch_parsed_message(input.route, &input.client_msg, socket, ctx, watcher).await? {
            warn!(
                "Unhandled message type: domain={}, action={}, discriminant={:?}",
                input.envelope.domain,
                input.envelope.action,
                std::mem::discriminant(&input.client_msg)
            );
            send_unhandled_message(socket).await?;
        }

        Ok(())
    })
    .await
}
