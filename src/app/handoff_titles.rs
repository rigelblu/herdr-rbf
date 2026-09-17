use super::App;

impl App {
    pub(super) fn restore_terminal_titles_after_handoff(&mut self) {
        for (terminal_id, runtime) in self.terminal_runtimes.iter() {
            if let Some(terminal) = self.state.terminals.get_mut(terminal_id) {
                terminal.set_terminal_title(runtime.terminal_title());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::workspace::Workspace;

    #[tokio::test]
    async fn restore_copies_runtime_titles_without_events() {
        let event_hub = crate::api::EventHub::default();
        let (_api_tx, api_rx) = tokio::sync::mpsc::unbounded_channel();
        let mut app = App::new(
            &Config::default(),
            crate::app::AppPolicy::TEST,
            None,
            api_rx,
            event_hub.clone(),
        );
        app.state.workspaces = vec![Workspace::test_new("one")];
        app.state.active = Some(0);
        app.state.ensure_test_terminals();

        let pane_id = app.state.workspaces[0].tabs[0].root_pane;
        let terminal_id = app.state.workspaces[0].tabs[0].panes[&pane_id]
            .attached_terminal_id
            .clone();

        let runtime = crate::terminal::TerminalRuntime::test_with_screen_bytes(80, 24, b"");
        runtime.test_process_pty_bytes(b"\x1b]0;\xe2\x9c\xb3 probe title\x07");
        app.terminal_runtimes.insert(terminal_id.clone(), runtime);

        assert_eq!(
            app.state
                .terminals
                .get(&terminal_id)
                .unwrap()
                .terminal_title,
            None
        );

        let seq_before = event_hub.current_sequence();
        app.restore_terminal_titles_after_handoff();

        assert_eq!(
            app.state
                .terminals
                .get(&terminal_id)
                .unwrap()
                .terminal_title
                .as_deref(),
            Some("✳ probe title")
        );
        assert_eq!(event_hub.current_sequence(), seq_before);
    }
}
