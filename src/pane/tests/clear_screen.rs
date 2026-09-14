//! herdr-rbf `hrdr-4`: ⌘K clears at the pane runtime — deferred erases and raw-mode Ctrl+L.

use super::*;

const FORM_FEED: &[u8] = b"\x0c";

fn runtime_with(bytes: &[u8]) -> (PaneRuntime, mpsc::Receiver<Bytes>) {
    PaneRuntime::test_with_channel_and_scrollback_bytes(80, 24, 1024 * 1024, bytes, 4)
}

/// Feed program output through the PTY read path and return the terminal responses that read
/// would write back to the program.
fn read(runtime: &PaneRuntime, bytes: &[u8]) -> Vec<Bytes> {
    let (tx, _rx) = mpsc::channel(1);
    runtime
        .terminal
        .process_pty_bytes(runtime.pane_id, 0, bytes, &tx)
        .terminal_responses
}

#[tokio::test]
async fn clear_inside_a_sequence_waits_for_ground_then_erases_and_sends_ctrl_l() {
    let (runtime, mut rx) = runtime_with(b"old output\r\n");
    read(&runtime, b"\x1b[3");

    runtime.clear_screen().expect("clear");
    assert!(
        rx.try_recv().is_err(),
        "Ctrl+L waits with the deferred erase"
    );
    assert!(runtime.visible_text().contains("old output"));

    let responses = read(&runtime, b"1mcoloured\x1b[0m");
    let visible = runtime.visible_text();
    assert!(!visible.contains("old output"), "{visible}");
    assert!(!visible.contains("1m"), "{visible}");
    assert_eq!(responses, vec![Bytes::from_static(FORM_FEED)]);
    assert!(
        read(&runtime, b"next").is_empty(),
        "the pending clear applies once"
    );
}

#[tokio::test]
async fn deferred_clear_stays_pending_across_a_read_that_ends_mid_sequence() {
    let (runtime, _rx) = runtime_with(b"old output\r\n");
    read(&runtime, b"\x1b]0;tit");

    runtime.clear_screen().expect("clear");
    assert!(read(&runtime, b"le still going").is_empty());
    assert!(runtime.visible_text().contains("old output"));

    assert_eq!(
        read(&runtime, b"\x07done"),
        vec![Bytes::from_static(FORM_FEED)]
    );
    assert!(!runtime.visible_text().contains("old output"));
}

#[tokio::test]
async fn second_clear_while_waiting_erases_now_and_leaves_nothing_pending() {
    let (runtime, mut rx) = runtime_with(b"old output\r\n");
    read(&runtime, b"\x1b]0;stuck");

    runtime.clear_screen().expect("first clear waits");
    assert!(runtime.visible_text().contains("old output"));
    assert!(rx.try_recv().is_err());

    runtime.clear_screen().expect("second clear forces");
    assert!(!runtime.visible_text().contains("old output"));
    assert_eq!(rx.try_recv().unwrap(), Bytes::from_static(FORM_FEED));
    assert!(rx.try_recv().is_err());

    assert!(
        read(&runtime, b"\x07after").is_empty(),
        "the forced clear left nothing pending"
    );
    assert!(runtime.visible_text().contains("after"));
}

#[tokio::test]
async fn deferred_clear_never_erases_a_program_that_switched_to_the_alternate_screen() {
    let (runtime, _rx) = runtime_with(b"old output\r\n");
    read(&runtime, b"\x1b[?104");

    runtime.clear_screen().expect("clear");
    let responses = read(&runtime, b"9hfull-screen");

    assert!(runtime.visible_text().contains("full-screen"));
    assert_eq!(responses, vec![Bytes::from_static(FORM_FEED)]);
}

// Terminal modes are only readable on Unix; elsewhere Ctrl+L is always sent.
#[cfg(unix)]
#[tokio::test]
async fn cooked_input_mode_gets_the_erase_and_no_ctrl_l_at_the_key_press() {
    let (runtime, mut rx) = runtime_with(b"old output\r\n");
    runtime.test_set_input_canonical(Some(true));

    runtime.clear_screen().expect("clear");
    assert!(!runtime.visible_text().contains("old output"));
    assert!(rx.try_recv().is_err());

    read(&runtime, b"build line\r\n\x1b[3");
    runtime.clear_screen().expect("clear");
    let (tx, _rx) = mpsc::channel(1);
    let landed = runtime
        .terminal
        .process_pty_bytes(runtime.pane_id, 0, b"1mstill building", &tx);
    assert!(landed.terminal_responses.is_empty());
    assert!(
        landed.ctrl_l_if_raw_mode,
        "the PTY reader re-reads the mode when a cooked-mode clear lands"
    );
    assert!(!runtime.visible_text().contains("build line"));
}

#[tokio::test]
async fn raw_mode_deferred_clear_needs_no_second_mode_read() {
    let (runtime, _rx) = runtime_with(b"old output\r\n");
    read(&runtime, b"\x1b[3");
    runtime.clear_screen().expect("clear");

    let (tx, _rx) = mpsc::channel(1);
    let landed = runtime
        .terminal
        .process_pty_bytes(runtime.pane_id, 0, b"1m", &tx);
    assert_eq!(
        landed.terminal_responses,
        vec![Bytes::from_static(FORM_FEED)]
    );
    assert!(!landed.ctrl_l_if_raw_mode);
}

#[tokio::test]
async fn raw_input_mode_gets_ctrl_l() {
    let (runtime, mut rx) = runtime_with(b"old output\r\n");
    runtime.test_set_input_canonical(Some(false));

    runtime.clear_screen().expect("clear");

    assert_eq!(rx.try_recv().unwrap(), Bytes::from_static(FORM_FEED));
    assert!(rx.try_recv().is_err());
}

/// End to end on a real PTY: the actor-backed mode read at the key press, the reader closure
/// carrying `ctrl_l_if_raw_mode`, and `read_once` sending Ctrl+L once the program turned raw.
#[cfg(unix)]
#[tokio::test]
async fn landed_clear_reaches_a_program_that_turned_raw_through_the_real_pty_reader() {
    let (events, _event_rx) = mpsc::channel(64);
    let runtime = PaneRuntime::spawn_shell_command(
        PaneId::from_raw(7),
        24,
        80,
        std::env::temp_dir(),
        "printf 'READY\\033]0;open'; sleep 1; stty raw -echo; printf '\\007'; \
         dd bs=1 count=1 2>/dev/null | od -An -tx1",
        &PaneLaunchEnv::default(),
        AgentDetection::Disabled,
        0,
        crate::terminal_theme::TerminalTheme::default(),
        None,
        events,
        Arc::new(Notify::new()),
        Arc::new(RenderSignal::new()),
    )
    .expect("spawn");

    let wait_for = |needle: &'static str| {
        let runtime = &runtime;
        async move {
            tokio::time::timeout(std::time::Duration::from_secs(3), async {
                while !runtime.visible_text().contains(needle) {
                    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                }
            })
            .await
            .unwrap_or_else(|_| panic!("never saw {needle:?}: {}", runtime.visible_text()))
        }
    };
    wait_for("READY").await;
    runtime
        .clear_screen()
        .expect("clear while cooked and mid-sequence");
    wait_for("0c").await;
    assert!(!runtime.visible_text().contains("READY"));
    runtime.shutdown();
}

/// End to end on a real PTY: a cooked program gets the erase and never a Ctrl+L, read through
/// the actor-backed mode check (a byte queued while cooked would surface once it turns raw).
#[cfg(unix)]
#[tokio::test]
async fn cooked_program_never_gets_ctrl_l_through_the_real_pty_reader() {
    let (events, _event_rx) = mpsc::channel(64);
    let runtime = PaneRuntime::spawn_shell_command(
        PaneId::from_raw(8),
        24,
        80,
        std::env::temp_dir(),
        "printf 'READY'; sleep 1; stty raw -echo min 0 time 10; \
         dd bs=1 count=1 2>/dev/null | od -An -tx1; printf 'DONE'",
        &PaneLaunchEnv::default(),
        AgentDetection::Disabled,
        0,
        crate::terminal_theme::TerminalTheme::default(),
        None,
        events,
        Arc::new(Notify::new()),
        Arc::new(RenderSignal::new()),
    )
    .expect("spawn");

    let wait_for = |needle: &'static str| {
        let runtime = &runtime;
        async move {
            tokio::time::timeout(std::time::Duration::from_secs(4), async {
                while !runtime.visible_text().contains(needle) {
                    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                }
            })
            .await
            .unwrap_or_else(|_| panic!("never saw {needle:?}: {}", runtime.visible_text()))
        }
    };
    wait_for("READY").await;
    runtime.clear_screen().expect("clear while cooked");
    wait_for("DONE").await;
    let visible = runtime.visible_text();
    assert!(!visible.contains("READY"), "{visible}");
    assert!(!visible.contains("0c"), "{visible}");
    runtime.shutdown();
}
