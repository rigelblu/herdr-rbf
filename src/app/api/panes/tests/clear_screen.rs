//! herdr-rbf `hrdr-4`: `pane.clear_screen` (⌘K) on the server.

use super::*;
use crate::api::schema::{Method, Request};

const SCROLLBACK_BYTES: usize = 1024 * 1024;

fn numbered_lines(count: usize) -> Vec<u8> {
    (1..=count)
        .map(|n| format!("line-{n:03}\r\n"))
        .collect::<String>()
        .into_bytes()
}

fn app_with_output(bytes: &[u8]) -> (App, String, tokio::sync::mpsc::Receiver<Bytes>) {
    let (mut app, pane_id) = app_with_test_workspace();
    let internal_pane_id = app.state.workspaces[0].tabs[0].root_pane;
    let (runtime, rx) = crate::terminal::TerminalRuntime::test_with_channel_and_scrollback_bytes(
        80,
        24,
        SCROLLBACK_BYTES,
        bytes,
        4,
    );
    app.state.insert_test_runtime(internal_pane_id, runtime);
    (app, pane_id, rx)
}

fn runtime(app: &App) -> &crate::terminal::TerminalRuntime {
    let internal_pane_id = app.state.workspaces[0].tabs[0].root_pane;
    app.lookup_runtime_sender(0, internal_pane_id)
        .expect("test runtime")
}

fn clear_request(pane_id: &str) -> Request {
    Request {
        id: "req".into(),
        method: Method::PaneClearScreen(PaneTarget {
            pane_id: pane_id.into(),
        }),
    }
}

fn assert_ok(response: &str) {
    let success: SuccessResponse = serde_json::from_str(response).unwrap();
    assert_eq!(success.result, ResponseResult::Ok {});
}

#[tokio::test]
async fn clear_screen_erases_history_and_sends_one_form_feed() {
    let (mut app, pane_id, mut rx) = app_with_output(&numbered_lines(200));
    let before = runtime(&app).scroll_metrics().expect("metrics");
    assert!(
        before.max_offset_from_bottom > 0,
        "fixture must have scrollback"
    );
    let content_seq = runtime(&app).content_seq();
    let detection_seq = runtime(&app).test_detection_content_seq();

    assert_ok(&app.handle_api_request(clear_request(&pane_id)));

    let pane = runtime(&app);
    assert_eq!(
        pane.scroll_metrics()
            .expect("metrics")
            .max_offset_from_bottom,
        0
    );
    assert!(
        !pane.visible_text().contains("line-"),
        "{}",
        pane.visible_text()
    );
    assert_eq!(pane.content_seq(), content_seq + 2);
    assert!(pane.content_seq().is_multiple_of(2));
    assert!(pane.test_detection_content_seq() > detection_seq);
    assert_eq!(rx.try_recv().unwrap(), Bytes::from_static(b"\x0c"));
    assert!(rx.try_recv().is_err());
}

#[tokio::test]
async fn clear_screen_below_a_marked_prompt_leaves_no_history() {
    let mut bytes = numbered_lines(200);
    bytes.extend_from_slice(b"\x1b]133;A\x07$ ");
    let (mut app, pane_id, _rx) = app_with_output(&bytes);

    assert_ok(&app.handle_api_request(clear_request(&pane_id)));

    let pane = runtime(&app);
    assert_eq!(
        pane.scroll_metrics()
            .expect("metrics")
            .max_offset_from_bottom,
        0
    );
    assert!(
        !pane.visible_text().contains("line-"),
        "{}",
        pane.visible_text()
    );
}

#[tokio::test]
async fn clear_screen_sends_only_ctrl_l_on_the_alternate_screen() {
    let (mut app, pane_id, mut rx) = app_with_output(b"\x1b[?1049hfull-screen-marker");
    let content_seq = runtime(&app).content_seq();

    assert_ok(&app.handle_api_request(clear_request(&pane_id)));

    let pane = runtime(&app);
    assert!(pane.visible_text().contains("full-screen-marker"));
    assert_eq!(
        pane.content_seq(),
        content_seq,
        "the alternate screen must not be erased"
    );
    assert_eq!(rx.try_recv().unwrap(), Bytes::from_static(b"\x0c"));
    assert!(rx.try_recv().is_err());
}

#[tokio::test]
async fn clear_screen_returns_to_the_live_bottom() {
    let (mut app, pane_id, _rx) = app_with_output(&numbered_lines(200));
    runtime(&app).scroll_up(50);
    assert!(
        runtime(&app)
            .scroll_metrics()
            .expect("metrics")
            .offset_from_bottom
            > 0
    );

    assert_ok(&app.handle_api_request(clear_request(&pane_id)));

    assert_eq!(
        runtime(&app)
            .scroll_metrics()
            .expect("metrics")
            .offset_from_bottom,
        0
    );
}

#[tokio::test]
async fn clear_screen_rejects_an_unknown_pane_and_repaints_clients() {
    let (mut app, _pane_id, _rx) = app_with_output(b"");

    let response = app.handle_api_request(clear_request("missing-pane"));
    let error: ErrorResponse = serde_json::from_str(&response).unwrap();
    assert_eq!(error.error.code, "pane_not_found");

    assert!(crate::api::request_changes_ui(&clear_request(
        "missing-pane"
    )));
}

// Terminal modes are only readable on Unix; elsewhere Ctrl+L is always sent.
#[cfg(unix)]
#[tokio::test]
async fn clear_screen_in_cooked_input_mode_erases_but_sends_no_ctrl_l() {
    let (mut app, pane_id, mut rx) = app_with_output(&numbered_lines(40));
    runtime(&app).test_set_input_canonical(Some(true));

    assert_ok(&app.handle_api_request(clear_request(&pane_id)));

    assert!(!runtime(&app).visible_text().contains("line-"));
    assert!(rx.try_recv().is_err());
}

#[tokio::test]
async fn clear_screen_mid_escape_sequence_prints_no_leftover_bytes() {
    let (mut app, pane_id, _rx) = app_with_output(b"before\r\n");
    runtime(&app).test_process_pty_bytes(b"\x1b[3");

    assert_ok(&app.handle_api_request(clear_request(&pane_id)));
    runtime(&app).test_process_pty_bytes(b"1mcoloured\x1b[0m");

    let visible = runtime(&app).visible_text();
    assert!(!visible.contains("before"), "{visible}");
    assert!(!visible.contains("1m"), "{visible}");
}
