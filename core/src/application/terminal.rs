use crate::server::context::ConnectionMeta;
use crate::server::protocol::{RemoteSubscriberDetail, ServerMessage, TerminalInfo};
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;
use crate::server::terminal_registry::SharedTerminalRegistry;

pub async fn term_list_message(
    terminal_registry: &SharedTerminalRegistry,
    remote_sub_registry: &SharedRemoteSubRegistry,
    conn_meta: &ConnectionMeta,
) -> (ServerMessage, usize, usize) {
    let mut items = {
        let reg = terminal_registry.lock().await;
        reg.list()
    };

    {
        let rsub = remote_sub_registry.lock().await;
        for item in &mut items {
            let subs = rsub.get_subscribers(&item.term_id);
            item.remote_subscribers = subs
                .into_iter()
                .map(|s| RemoteSubscriberDetail {
                    device_name: s.device_name,
                    conn_id: s.conn_id,
                })
                .collect();
        }
    }

    if conn_meta.is_remote {
        let my_subscriber_id = conn_meta.remote_subscriber_id();
        items.retain(|item| {
            item.remote_subscribers
                .iter()
                .any(|s| s.conn_id == my_subscriber_id)
        });
    }

    items.sort_by(|a, b| {
        let left = terminal_sort_key(a);
        let right = terminal_sort_key(b);
        left.cmp(&right)
    });

    let remote_count: usize = items.iter().map(|i| i.remote_subscribers.len()).sum();
    let terminal_count = items.len();

    (
        ServerMessage::TermList { items },
        terminal_count,
        remote_count,
    )
}

fn terminal_sort_key(item: &TerminalInfo) -> (String, String, String) {
    (
        item.project.to_lowercase(),
        item.workspace.to_lowercase(),
        item.term_id.clone(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_sort_key_is_case_insensitive_by_project_workspace() {
        let a = TerminalInfo {
            term_id: "2".to_string(),
            project: "zeta".to_string(),
            workspace: "b".to_string(),
            cwd: "/tmp".to_string(),
            status: "running".to_string(),
            shell: "zsh".to_string(),
            lifecycle_phase: "active".to_string(),
            name: None,
            icon: None,
            recovery_phase: None,
            recovery_failed_reason: None,
            remote_subscribers: vec![],
        };
        let b = TerminalInfo {
            term_id: "1".to_string(),
            project: "Alpha".to_string(),
            workspace: "a".to_string(),
            cwd: "/tmp".to_string(),
            status: "running".to_string(),
            shell: "zsh".to_string(),
            lifecycle_phase: "active".to_string(),
            name: None,
            icon: None,
            recovery_phase: None,
            recovery_failed_reason: None,
            remote_subscribers: vec![],
        };

        assert!(terminal_sort_key(&b) < terminal_sort_key(&a));
    }
}
