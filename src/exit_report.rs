//! What herdr says when a pane's program quits.
//!
//! The server sends one string: a status line, then the program's last screen lines, each
//! behind a two-space indent. It travels in string fields of frozen messages, so that shape
//! and the status line's wording are the whole contract. A terminal-attach client that
//! recognises them prints the program's lines as written, a blank line, then herdr's line.
//!
//! [`message`] writes the string and [`layout`] reads it. They share this file so a change
//! to the wording lands in one place, and the tests run one through the other.

/// What a terminal-attach client prints between `herdr: ` and a shutdown's reason.
pub(crate) const SHUTDOWN_PREFIX: &str = "server shut down: ";

/// The fewest screen rows read for an exit message. A taller pane reads every row it has,
/// so a full-screen program's text at the top of its view is never out of reach.
pub(crate) const MIN_SCREEN_ROWS: usize = 50;

/// How many of the program's last non-blank lines an exit message carries.
const KEPT_LINES: usize = 10;

/// What each program line sits behind, under the status line.
const LINE_INDENT: &str = "  ";

/// The message for a pane whose program quit: a status line, then its last lines on screen.
///
/// `exit_status` is `None` when herdr never learned it: a signal, or a pane that a live
/// install handed to this server. `screen_text` is the pane's recent screen as plain text.
pub(crate) fn message(name: &str, exit_status: Option<u32>, screen_text: &str) -> String {
    let name = printable(name);
    let mut message = match exit_status {
        Some(code) => format!("{name} exited with status {code}"),
        None => format!("{name} exited"),
    };
    let lines: Vec<String> = screen_text
        .lines()
        .map(|line| printable(line).trim_end().to_string())
        .filter(|line| !line.is_empty())
        .collect();
    for line in &lines[lines.len().saturating_sub(KEPT_LINES)..] {
        message.push('\n');
        message.push_str(LINE_INDENT);
        message.push_str(line);
    }
    message
}

/// `text` without its control characters, so nothing in it can steer the terminal that
/// prints it. A tab label is as much a program's to set as its screen is.
pub(crate) fn printable(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).collect()
}

/// Text to print for a pane-exit message that carries program lines, or `None` for any
/// other message, which the call site prints as it always has.
///
/// `prefix` goes between `herdr: ` and the status line: [`SHUTDOWN_PREFIX`] after a
/// shutdown, empty after an error reply.
pub(crate) fn layout(prefix: &str, message: &str) -> Option<String> {
    let mut lines = message.split('\n');
    let status_line = lines.next().filter(|line| is_status_line(line))?;
    let program_lines = lines
        .map(|line| line.strip_prefix(LINE_INDENT))
        .collect::<Option<Vec<_>>>()?;
    // A server older than this file sends its lines and its name as it read them
    let program_lines: Vec<String> = program_lines
        .into_iter()
        .map(printable)
        .filter(|line| !line.trim().is_empty())
        .collect();
    if program_lines.is_empty() {
        return None;
    }
    Some(format!(
        "{}\n\nherdr: {prefix}{}",
        program_lines.join("\n"),
        printable(status_line)
    ))
}

/// The wording [`message`] gives a status line.
fn is_status_line(line: &str) -> bool {
    if line.ends_with(" exited") {
        return true;
    }
    line.rsplit_once(" exited with status ")
        .is_some_and(|(_, code)| !code.is_empty() && code.bytes().all(|b| b.is_ascii_digit()))
}

/// The last thing a terminal-attach client prints for `error`: `report` when the server
/// sent a pane's exit, else `herdr: {error}`. Whichever server wrote that text, no control
/// character in it reaches the terminal but its line breaks.
pub(crate) fn attach_ending(report: Option<String>, error: &impl std::fmt::Display) -> String {
    report.unwrap_or_else(|| {
        format!("herdr: {error}")
            .split('\n')
            .map(printable)
            .collect::<Vec<_>>()
            .join("\n")
    })
}

/// Text to print for a refused or ended terminal attach, when a pane's exit is the reason.
#[cfg(unix)]
pub(crate) fn attach_error_layout(err: &crate::client::TerminalAttachError) -> Option<String> {
    use crate::client::TerminalAttachError;
    match err {
        TerminalAttachError::ErrorReply(message) => layout("", message),
        TerminalAttachError::ServerShutdown(Some(reason)) => layout(SHUTDOWN_PREFIX, reason),
        TerminalAttachError::ServerShutdown(None) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{attach_ending, layout, message, SHUTDOWN_PREFIX};
    use crate::client::{ClientError, TerminalAttachError};

    #[test]
    fn message_is_the_status_line_then_the_screen_lines_indented() {
        assert_eq!(
            message("claude", Some(0), "line 1\nline 2\n"),
            "claude exited with status 0\n  line 1\n  line 2"
        );
        assert_eq!(
            message("pi", Some(3), "boom\n"),
            "pi exited with status 3\n  boom"
        );
    }

    #[test]
    fn message_for_an_unknown_status_names_no_status() {
        assert_eq!(
            message("agy", None, "last frame line\n"),
            "agy exited\n  last frame line"
        );
    }

    #[test]
    fn message_keeps_the_last_ten_lines_and_no_blank_ones() {
        let screen: String = (1..=12).map(|n| format!("line {n}\n\n")).collect();
        let expected: String = (3..=12).map(|n| format!("\n  line {n}")).collect();
        assert_eq!(
            message("sh", Some(1), &screen),
            format!("sh exited with status 1{expected}")
        );
    }

    #[test]
    fn message_keeps_a_lines_own_indent_and_drops_its_trailing_spaces() {
        assert_eq!(
            message("sh", Some(0), "    four spaces in   \n"),
            "sh exited with status 0\n      four spaces in"
        );
    }

    #[test]
    fn message_for_a_blank_screen_is_the_status_line_alone() {
        for screen in ["", "\n", "   \n\n \n"] {
            assert_eq!(message("sh", Some(0), screen), "sh exited with status 0");
        }
    }

    #[test]
    fn message_holds_no_control_character_from_the_screen_or_the_name() {
        let message = message(
            "ev\x1b[31mil\x07\nname",
            Some(0),
            "d\x7fe\x1b]0;title\x07l\u{9b}2J\n\x7f\n",
        );
        assert_eq!(
            message,
            "ev[31milname exited with status 0\n  de]0;titlel2J"
        );
    }

    #[test]
    fn layout_puts_program_lines_first_then_a_blank_line_then_herdrs_line() {
        assert_eq!(
            layout(
                SHUTDOWN_PREFIX,
                "claude exited with status 0\n  Resume this session with:\n  claude --resume x"
            )
            .as_deref(),
            Some(
                "Resume this session with:\nclaude --resume x\n\nherdr: server shut down: claude exited with status 0"
            )
        );
    }

    #[test]
    fn layout_of_an_error_reply_takes_no_prefix() {
        assert_eq!(
            layout("", "pi exited with status 1\n  Error: no key").as_deref(),
            Some("Error: no key\n\nherdr: pi exited with status 1")
        );
    }

    #[test]
    fn layout_keeps_a_program_lines_own_indent() {
        assert_eq!(
            layout(
                SHUTDOWN_PREFIX,
                "sh exited with status 3\n      four spaces in"
            )
            .as_deref(),
            Some("    four spaces in\n\nherdr: server shut down: sh exited with status 3")
        );
    }

    #[test]
    fn layout_takes_an_unknown_status() {
        assert_eq!(
            layout(SHUTDOWN_PREFIX, "agy exited\n  last frame line").as_deref(),
            Some("last frame line\n\nherdr: server shut down: agy exited")
        );
    }

    #[test]
    fn layout_removes_control_characters_an_older_server_let_through() {
        assert_eq!(
            layout(
                SHUTDOWN_PREFIX,
                "ev\x1b[31mil\x07 exited with status 3\n  del d\x7fe"
            )
            .as_deref(),
            Some("del de\n\nherdr: server shut down: ev[31mil exited with status 3")
        );
    }

    #[test]
    fn layout_drops_a_line_that_held_only_control_characters() {
        assert_eq!(
            layout("", "pi exited with status 3\n  \x7f\n  after").as_deref(),
            Some("after\n\nherdr: pi exited with status 3")
        );
        assert_eq!(layout("", "pi exited with status 3\n  \x7f\n   \x07"), None);
    }

    #[test]
    fn attach_ending_is_the_report_when_there_is_one() {
        let report = "bye\n\nherdr: agy exited".to_string();
        assert_eq!(attach_ending(Some(report.clone()), &"unused"), report);
    }

    #[test]
    fn attach_ending_without_a_report_keeps_line_breaks_and_no_other_control_character() {
        assert_eq!(
            attach_ending(
                None,
                &"server shut down: ev\x1b[31mil\nx exited with status 3\n  del d\x7fe"
            ),
            "herdr: server shut down: ev[31mil\nx exited with status 3\n  del de"
        );
        assert_eq!(
            attach_ending(None, &"server shut down: live update in progress"),
            "herdr: server shut down: live update in progress"
        );
    }

    #[test]
    fn layout_leaves_every_other_message_to_the_call_site() {
        for message in [
            // one line: a live update, a detach, a status line with no screen lines
            "live update in progress; reconnect after handoff completes",
            "detached",
            "claude exited with status 0",
            "agy exited",
            "terminal term_1 exited",
            // a later line without the two-space indent
            "first\nsecond",
            "pi exited with status 1\n one space",
            "pi exited with status 1\n  indented\nnot indented",
            "pi exited with status 1\n  indented\n",
            // the shape without the status wording
            "live update notes\n  step one",
            "pi exited with status\n  no number",
            "pi exited with status \n  no number after the space",
            "pi exited with status one\n  not a number",
            "pi exited with status 1 \n  trailing space",
            "exited\n  no name",
            "",
        ] {
            for prefix in [SHUTDOWN_PREFIX, ""] {
                assert_eq!(layout(prefix, message), None, "{message:?}");
            }
        }
    }

    #[test]
    fn layout_reads_back_what_message_writes() {
        let screen = "reply line\n\nResume this session with:\n  claude --resume x  \n";
        assert_eq!(
            layout(SHUTDOWN_PREFIX, &message("claude", Some(0), screen)).as_deref(),
            Some(
                "reply line\nResume this session with:\n  claude --resume x\n\nherdr: server shut down: claude exited with status 0"
            )
        );
        assert_eq!(
            layout("", &message("agy", None, "bye\n")).as_deref(),
            Some("bye\n\nherdr: agy exited")
        );
        assert_eq!(layout("", &message("sh", Some(0), "\n")), None);
    }

    #[test]
    fn a_name_cannot_pass_itself_off_as_program_lines() {
        let spoofed = message("claude exited\n  FAKE LINE", Some(0), "real line\n");
        assert_eq!(
            layout("", &spoofed).as_deref(),
            Some("real line\n\nherdr: claude exited  FAKE LINE exited with status 0")
        );
    }

    #[test]
    fn the_shutdown_prefix_is_the_wording_both_shutdown_errors_print() {
        let reason = "claude exited with status 0";
        let expected = format!("{SHUTDOWN_PREFIX}{reason}");
        assert_eq!(
            ClientError::ServerShutdown {
                reason: Some(reason.to_string())
            }
            .to_string(),
            expected
        );
        assert_eq!(
            TerminalAttachError::ServerShutdown(Some(reason.to_string())).to_string(),
            expected
        );
    }

    #[cfg(unix)]
    #[test]
    fn attach_error_layout_covers_an_exit_before_and_while_the_attach_connects() {
        use super::attach_error_layout;

        let exit = "pi exited with status 1\n  Error: no key";
        assert_eq!(
            attach_error_layout(&TerminalAttachError::ErrorReply(exit.to_string())).as_deref(),
            Some("Error: no key\n\nherdr: pi exited with status 1")
        );
        assert_eq!(
            attach_error_layout(&TerminalAttachError::ServerShutdown(Some(exit.to_string())))
                .as_deref(),
            Some("Error: no key\n\nherdr: server shut down: pi exited with status 1")
        );
        for other in [
            TerminalAttachError::ErrorReply("terminal attach failed: terminal t not found".into()),
            TerminalAttachError::ServerShutdown(Some("terminal attach taken over".into())),
            TerminalAttachError::ServerShutdown(None),
        ] {
            assert_eq!(attach_error_layout(&other), None, "{other}");
        }
    }
}
