//! A plain URL that appears, changes, and disappears in a surface that was
//! never linked must reach the host as complete targets on every wrapped cell.
//! These run the real retained semantic render path, then encode the committed
//! frames with the ANSI writer a host terminal receives.
use super::*;

use crate::protocol::render_ansi::BlitEncoder;

const CLEAR_HOME: &[u8] = b"\x1b[2J\x1b[H";

fn committed_frame(server: &HeadlessServer) -> FrameData {
    server.clients[&1]
        .render_state
        .last_pane_surface()
        .expect("committed surface")
        .frame
        .clone()
}

fn inner_rect(server: &HeadlessServer) -> crate::protocol::SurfaceRect {
    server.clients[&1]
        .render_state
        .last_pane_surface()
        .expect("committed surface")
        .panes[0]
        .inner_rect
}

fn drain(receiver: &std::sync::mpsc::Receiver<Vec<u8>>) {
    while receiver.try_recv().is_ok() {}
}

/// Write `bytes` to the source, try the retained path, and fall back to a
/// complete render when it declines. Returns whether the retained path took it.
fn present(
    server: &mut HeadlessServer,
    render_rx: &std::sync::mpsc::Receiver<Vec<u8>>,
    pane_id: crate::layout::PaneId,
    bytes: &[u8],
) -> bool {
    write_shared_test_pane(server, pane_id, bytes);
    let retained = server.render_retained_pane_surface_and_stream(&HashSet::from([pane_id]));
    if !retained {
        server.render_and_stream();
    }
    drain(render_rx);
    retained
}

/// Cells the host will link, by frame coordinate, with their targets.
fn linked_cells(frame: &FrameData) -> std::collections::BTreeMap<(u16, u16), String> {
    frame
        .cells
        .iter()
        .enumerate()
        .filter_map(|(index, cell)| {
            let target = frame.hyperlinks.get(cell.hyperlink? as usize)?;
            let width = usize::from(frame.width);
            Some((
                ((index % width) as u16, (index / width) as u16),
                target.clone(),
            ))
        })
        .collect()
}

/// The frame cells a URL written from the pane origin occupies.
fn url_cells(
    inner: crate::protocol::SurfaceRect,
    len: usize,
) -> std::collections::BTreeSet<(u16, u16)> {
    let width = usize::from(inner.width);
    (0..len)
        .map(|k| (inner.x + (k % width) as u16, inner.y + (k / width) as u16))
        .collect()
}

#[track_caller]
fn assert_url_linked(server: &HeadlessServer, url: &str) {
    let frame = committed_frame(server);
    let links = linked_cells(&frame);
    assert_eq!(
        links
            .keys()
            .copied()
            .collect::<std::collections::BTreeSet<_>>(),
        url_cells(inner_rect(server), url.len()),
        "linked cells for {url}"
    );
    assert!(links.values().all(|target| target == url), "{links:?}");
    assert_eq!(frame.hyperlinks, vec![url.to_owned()]);
}

#[track_caller]
fn assert_no_links(server: &HeadlessServer) {
    let frame = committed_frame(server);
    assert!(frame.hyperlinks.is_empty(), "{:?}", frame.hyperlinks);
    assert!(frame.cells.iter().all(|cell| cell.hyperlink.is_none()));
}

fn osc8_open(url: &str) -> Vec<u8> {
    format!("\x1b]8;;{url}\x1b\\").into_bytes()
}

const OSC8_CLOSE: &[u8] = b"\x1b]8;;\x1b\\";
/// Every target in these tests is a web URL, so this marks an opened link.
const OSC8_OPEN_PREFIX: &[u8] = b"\x1b]8;;http";

fn count(haystack: &[u8], needle: &[u8]) -> usize {
    haystack
        .windows(needle.len())
        .filter(|window| *window == needle)
        .count()
}

fn long_url(host: &str) -> String {
    format!("https://{host}/{}end", "complete-url-".repeat(14))
}

#[tokio::test]
async fn hrdr25_incremental_unlinked_surface_gains_replaces_and_loses_wrapped_links() {
    let (mut server, render_rx, pane_id) = retained_test_server(b"ordinary text");
    server.render_and_stream();
    drain(&render_rx);
    assert_no_links(&server);
    let first = long_url("first.example");
    let second = long_url("second.example");

    let mut encoder = BlitEncoder::new();
    let baseline = committed_frame(&server);
    let encoded = encoder.encode(&baseline, true);
    assert_eq!(count(&encoded.bytes, OSC8_OPEN_PREFIX), 0);
    encoder.commit(baseline, encoded);

    // Insertion: plain text becomes a complete link on every wrapped row.
    let retained = present(
        &mut server,
        &render_rx,
        pane_id,
        &[CLEAR_HOME, first.as_bytes()].concat(),
    );
    assert!(!retained, "a new link needs the complete renderer");
    assert_url_linked(&server, &first);
    let linked = committed_frame(&server);
    let full = BlitEncoder::new().encode(&linked, true);
    // Rows are positioned independently on the host, so the writer reopens the
    // same target once per row the link occupies and closes each run.
    let rows_with_link = linked_cells(&linked)
        .keys()
        .map(|&(_, y)| y)
        .collect::<std::collections::BTreeSet<_>>();
    assert!(rows_with_link.len() > 1, "the URL must wrap");
    assert_eq!(
        count(&full.bytes, &osc8_open(&first)),
        rows_with_link.len(),
        "one run per wrapped row"
    );
    assert!(count(&full.bytes, OSC8_CLOSE) >= 1, "the run is closed");
    let diff = encoder.encode(&linked, false);
    assert_eq!(count(&diff.bytes, &osc8_open(&first)), 1);
    assert!(count(&diff.bytes, OSC8_CLOSE) >= 1, "the run is closed");
    encoder.commit(linked, diff);

    // Replacement: the old target must not survive on any cell.
    let retained = present(
        &mut server,
        &render_rx,
        pane_id,
        &[CLEAR_HOME, second.as_bytes()].concat(),
    );
    assert!(!retained, "replacing a link needs the complete renderer");
    assert_url_linked(&server, &second);
    let replaced = committed_frame(&server);
    assert!(!replaced.hyperlinks.contains(&first));
    let diff = encoder.encode(&replaced, false);
    assert_eq!(count(&diff.bytes, &osc8_open(&second)), 1);
    assert_eq!(count(&diff.bytes, &osc8_open(&first)), 0);
    encoder.commit(replaced, diff);

    // Removal: ordinary text again, with the link closed in the host.
    let retained = present(
        &mut server,
        &render_rx,
        pane_id,
        &[CLEAR_HOME, b"plain words only"].concat(),
    );
    assert!(!retained, "removing a link needs the complete renderer");
    assert_no_links(&server);
    let removed = committed_frame(&server);
    let full = BlitEncoder::new().encode(&removed, true);
    assert_eq!(count(&full.bytes, OSC8_OPEN_PREFIX), 0);
    let diff = encoder.encode(&removed, false);
    assert_eq!(count(&diff.bytes, OSC8_OPEN_PREFIX), 0);
    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn hrdr25_incremental_text_without_links_keeps_the_retained_path() {
    let (mut server, render_rx, pane_id) = retained_test_server(b"ordinary text");
    server.render_and_stream();
    drain(&render_rx);
    assert!(
        present(
            &mut server,
            &render_rx,
            pane_id,
            b"\r\nmore prose, not a link"
        ),
        "prose that cannot carry a link stays on the patch path"
    );
    assert_no_links(&server);

    // A link elsewhere on the screen does not pin edits to unrelated rows.
    let url = "https://example.com/short";
    let retained = present(
        &mut server,
        &render_rx,
        pane_id,
        &[CLEAR_HOME, url.as_bytes()].concat(),
    );
    assert!(!retained);
    assert_url_linked(&server, url);
    // The cursor leaves the link's row, which Ghostty marks dirty, and the
    // existing guard for linked rows declines that one patch. The next edit,
    // away from any link, patches again.
    present(&mut server, &render_rx, pane_id, b"\x1b[10;1Hunrelated row");
    assert_url_linked(&server, url);
    assert!(
        present(&mut server, &render_rx, pane_id, b"\x1b[12;1Hanother row"),
        "an unrelated row changes through a patch"
    );
    assert_url_linked(&server, url);
    shutdown_test_runtimes(&mut server);
}

/// A token whose scheme is above the viewport becomes inferable when a cell is
/// blanked inside the viewport. No prior cell carries a link, and no visible
/// text holds a scheme, so only the source can say the new prefix is eligible.
#[tokio::test]
async fn hrdr25_incremental_token_starting_above_the_viewport_matches_a_full_render() {
    let filler = format!("https://example.com/{}", "a".repeat(8980));
    let (mut retained, retained_rx, pane_id) = retained_test_server(b"");
    retained.app.state.workspaces[0].insert_test_runtime(
        pane_id,
        crate::terminal::TerminalRuntime::test_with_scrollback_bytes(
            80,
            24,
            1024 * 1024,
            filler.as_bytes(),
        ),
    );
    retained.render_and_stream();
    drain(&retained_rx);
    assert_no_links(&retained);

    let split: &[u8] = b"\x1b[3;1H ";
    present(&mut retained, &retained_rx, pane_id, split);

    // The oracle takes the same steps, then renders the split completely: the
    // first render resizes the runtime, so building it from one write differs.
    let (mut full, full_rx, full_pane) = retained_test_server(b"");
    full.app.state.workspaces[0].insert_test_runtime(
        full_pane,
        crate::terminal::TerminalRuntime::test_with_scrollback_bytes(
            80,
            24,
            1024 * 1024,
            filler.as_bytes(),
        ),
    );
    full.render_and_stream();
    drain(&full_rx);
    write_shared_test_pane(&mut full, full_pane, split);
    full.clients.get_mut(&1).unwrap().request_recompute();
    full.render_and_stream();
    drain(&full_rx);

    let expected = linked_cells(&committed_frame(&full));
    assert!(
        !expected.is_empty(),
        "the split must make the prefix eligible"
    );
    assert_eq!(linked_cells(&committed_frame(&retained)), expected);
    shutdown_test_runtimes(&mut retained);
    shutdown_test_runtimes(&mut full);
}

/// Ordinary prose that wraps across the pane's edges must keep taking patches:
/// a continuing edge only matters when the hidden token holds a scheme or is
/// too long to resolve. This is the small-pane shape of the render-scale
/// retained profile.
#[tokio::test]
async fn hrdr25_incremental_ordinary_wrapped_prose_at_the_edges_keeps_the_retained_path() {
    let prose = "word ".repeat(40);
    let screen = (0..60)
        .map(|line| format!("{line:02} {prose}"))
        .collect::<Vec<_>>()
        .join("\r\n");
    let (mut server, render_rx, pane_id) = retained_test_server(screen.as_bytes());
    server.render_and_stream();
    drain(&render_rx);
    for edit in [&b"\x1b[Hone"[..], b"\x1b[12;40Htwo", b"\x1b[23;1Hthree"] {
        assert!(
            present(&mut server, &render_rx, pane_id, edit),
            "ordinary wrapped prose edit {edit:?} must patch"
        );
    }
    assert_no_links(&server);
    shutdown_test_runtimes(&mut server);
}
