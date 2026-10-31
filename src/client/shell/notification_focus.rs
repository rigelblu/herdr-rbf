//! The focus a client uses to decide notifications (herdr-rbf `hrdr-30.2`).
//!
//! A tab showing one agent (an attach client) ignores outer focus for that agent. Ghostty starts
//! every terminal focused and answers a focus-report request with that state, so a tab nobody
//! clicked reports "focused" forever. Believing it silenced the agent's own notification and
//! marked the agent seen. An attach tab therefore behaves as if its outer focus were
//! `Some(false)`. Full views keep the real report.
//!
//! The rule applies in every host, not only because of Ghostty's initial "focused": a user
//! looking at an attach tab in any terminal now gets their own agent's print and sound. That is
//! the "Ignore focus" decision (hrdr-30.2).
//!
//! The focus the client reports to the server is unchanged; this value feeds only the quiet
//! check in `tick_notifications` and the seen-marking in `acknowledge_surface`.

use super::*;

impl ClientShellState {
    pub(super) fn focus_for_notifications(&self) -> Option<bool> {
        if self.config.attached_terminal {
            Some(false)
        } else {
            self.outer_focused
        }
    }
}
