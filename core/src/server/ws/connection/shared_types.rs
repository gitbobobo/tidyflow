pub(in crate::server::ws) type TaskBroadcastRx =
    tokio::sync::broadcast::Receiver<crate::server::context::TaskBroadcastEvent>;

pub(in crate::server::ws) type RemoteTermRx =
    tokio::sync::broadcast::Receiver<crate::server::remote_sub_registry::RemoteTermEvent>;

pub(in crate::server::ws) type TaskBroadcastRecvResult =
    Result<crate::server::context::TaskBroadcastEvent, tokio::sync::broadcast::error::RecvError>;

pub(in crate::server::ws) type RemoteTermRecvResult = Result<
    crate::server::remote_sub_registry::RemoteTermEvent,
    tokio::sync::broadcast::error::RecvError,
>;
