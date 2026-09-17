use super::HeadlessServer;
use crate::protocol::ServerMessage;

impl HeadlessServer {
    pub(super) fn sync_terminal_attach_titles(&mut self) {
        if !self.app.window_title_configured() || self.terminal_attach_owners.is_empty() {
            return;
        }

        let mut sends = Vec::new();
        for (terminal_id, terminal_state) in &self.app.state.terminals {
            let Some(&client_id) = self.terminal_attach_owners.get(terminal_id.as_str()) else {
                continue;
            };
            let Some(title) = terminal_state.terminal_title.as_deref() else {
                continue;
            };
            let Some(client) = self.clients.get(&client_id) else {
                continue;
            };
            if client.writer.is_none() {
                continue;
            }
            if client.terminal_attach_title_sent.as_deref() == Some(title) {
                continue;
            }
            sends.push((client_id, title.to_owned()));
        }

        for (client_id, title) in sends {
            let msg = ServerMessage::WindowTitle {
                title: Some(title.clone()),
            };
            if self.send_to_client(client_id, msg) {
                if let Some(client) = self.clients.get_mut(&client_id) {
                    client.terminal_attach_title_sent = Some(title);
                }
            }
        }
    }
}
