//! Which full clients receive a notification about one pane (herdr-rbf `hrdr-30.1`).
//!
//! A tab showing one agent (an attach client) is a full client attached to one
//! terminal. Sending it every pane's notification put other agents' "finished"
//! on its workspace, so a pane's notification goes only to the full client
//! attached to that pane's terminal, plus full clients that aren't attached to a
//! terminal (a full view, or a client that hasn't recorded a presentation yet).
//! A client with no writer isn't a recipient, so the send reports `false` for it
//! as `send_to_client_shells` does.

use super::*;

/// Full clients that should receive a notification about `terminal_id`.
fn pane_notification_recipients(
    clients: &HashMap<u64, ClientConnection>,
    terminal_id: Option<&str>,
) -> Vec<u64> {
    clients
        .iter()
        .filter(|(_, client)| matches!(client.mode, ClientConnectionMode::ClientShell))
        .filter(|(_, client)| client.writer.is_some())
        .filter(|(_, client)| match client.attached_terminal_id() {
            None => true,
            Some(attached) => Some(attached) == terminal_id,
        })
        .map(|(&client_id, _)| client_id)
        .collect()
}

impl HeadlessServer {
    /// Sends a notification about `pane_id` to the clients that show it. Returns
    /// whether any client received it.
    pub(super) fn send_pane_notification(
        &mut self,
        ws_idx: usize,
        pane_id: crate::layout::PaneId,
        msg: ServerMessage,
    ) -> bool {
        let terminal_id = self
            .app
            .state
            .workspaces
            .get(ws_idx)
            .and_then(|workspace| workspace.terminal_id(pane_id))
            .map(ToString::to_string);
        let mut sent = false;
        for client_id in pane_notification_recipients(&self.clients, terminal_id.as_deref()) {
            sent |= self.send_to_client(client_id, msg.clone());
        }
        sent
    }
}
