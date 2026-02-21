use axum::extract::ws::WebSocket;

use crate::server::context::HandlerContext;
use crate::server::protocol::domain_table::DomainRoute;
use crate::server::protocol::ClientMessage;
use crate::server::ws::dispatch::shared_types::DispatchWatcher;

mod core_domains;
mod file_domain;

pub(super) async fn dispatch_domain_handler(
    route: DomainRoute,
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
    watcher: &DispatchWatcher,
) -> Result<bool, String> {
    let handled = match route {
        DomainRoute::System => core_domains::handle_system_domain(client_msg, socket).await?,
        DomainRoute::Terminal => {
            core_domains::handle_terminal_domain(client_msg, socket, ctx).await?
        }
        DomainRoute::File => file_domain::handle_file_domain(client_msg, socket, ctx, watcher).await?,
        DomainRoute::Git => core_domains::handle_git_domain(client_msg, socket, ctx).await?,
        DomainRoute::Project => core_domains::handle_project_domain(client_msg, socket, ctx).await?,
        DomainRoute::Lsp => core_domains::handle_lsp_domain(client_msg, socket, ctx).await?,
        DomainRoute::Settings => core_domains::handle_settings_domain(client_msg, socket, ctx).await?,
        DomainRoute::Log => core_domains::handle_log_domain(client_msg)?,
        DomainRoute::Ai => core_domains::handle_ai_domain(client_msg, socket, ctx).await?,
        DomainRoute::Evolution => {
            core_domains::handle_evolution_domain(client_msg, socket, ctx).await?
        }
    };
    Ok(handled)
}
