//! Where the server's loop meets [`crate::session_expiry`]. It lives here, in a file the
//! fork owns, so the loop itself carries one call and `remove_client` another.

use super::*;

impl HeadlessServer {
    /// Runs the session check once it is due. On every other loop wake this is one time
    /// comparison.
    ///
    /// It goes just before the loop's own shutdown test, which picks up a shutdown started
    /// here in the same pass.
    pub(super) fn check_session_expiry(&mut self) {
        if !crate::session_expiry::check_is_due(Instant::now()) {
            return;
        }
        let state = &self.app.state;
        let in_use = crate::session_expiry::is_in_use(
            self.clients.len(),
            state
                .workspaces
                .iter()
                .flat_map(|workspace| workspace.pane_details(&state.terminals))
                .map(|pane| pane.state),
        );
        if crate::session_expiry::check(in_use, SystemTime::now()) {
            self.initiate_shutdown();
        }
    }

    /// A look shorter than a check interval still counts as use: the moment the last client
    /// leaves is recorded, not only what the next check sees.
    pub(super) fn touch_in_use_if_last_client_left(&self) {
        if self.clients.is_empty() {
            crate::session_expiry::touch_in_use();
        }
    }
}
