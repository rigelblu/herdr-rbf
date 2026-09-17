use super::*;

fn setup_two_terminal_server() -> (
    HeadlessServer,
    (crate::layout::PaneId, String),
    (crate::layout::PaneId, String),
) {
    let mut server = test_headless_server();
    let ws1 = crate::workspace::Workspace::test_new("ws1");
    let p1 = ws1.tabs[0].root_pane;
    let t1 = ws1.terminal_id(p1).expect("t1").clone();

    let ws2 = crate::workspace::Workspace::test_new("ws2");
    let p2 = ws2.tabs[0].root_pane;
    let t2 = ws2.terminal_id(p2).expect("t2").clone();

    server.app.state.workspaces = vec![ws1, ws2];
    server.app.state.active = Some(0);
    server.app.state.ensure_test_terminals();

    server.app.terminal_runtimes.insert(
        t1.clone(),
        crate::terminal::TerminalRuntime::test_with_screen_bytes(80, 24, b""),
    );
    server.app.terminal_runtimes.insert(
        t2.clone(),
        crate::terminal::TerminalRuntime::test_with_screen_bytes(80, 24, b""),
    );

    let t1_str = t1.to_string();
    let t2_str = t2.to_string();
    (server, (p1, t1_str), (p2, t2_str))
}

#[tokio::test]
async fn title_change_reaches_the_attached_client() {
    let (mut server, (p1, t1_str), (_p2, t2_str)) = setup_two_terminal_server();
    let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
    let control_rx2 = connect_pending_terminal_client_with_control_rx(&mut server, 2);

    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 1,
            terminal_id: t1_str.clone(),
            takeover: false,
        })
    );
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 2,
            terminal_id: t2_str.clone(),
            takeover: false,
        })
    );
    drain_window_titles(&control_rx1);
    drain_window_titles(&control_rx2);

    let t1_id = server.terminal_id_by_string(&t1_str).unwrap();
    server
        .app
        .terminal_runtimes
        .get(&t1_id)
        .unwrap()
        .test_process_pty_bytes(b"\x1b]0;\xe2\x9c\xb3 my session\x07");
    server.app.render_dirty.request_terminal_title(p1);

    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);

    assert_eq!(
        next_window_title(&control_rx1),
        Some(Some("✳ my session".to_string()))
    );
    assert!(no_window_title(&control_rx1));
    assert!(no_window_title(&control_rx2));

    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn long_title_arrives_unchanged() {
    let (mut server, (p1, t1_str), _) = setup_two_terminal_server();
    let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 1,
            terminal_id: t1_str.clone(),
            takeover: false,
        })
    );
    drain_window_titles(&control_rx1);

    let long_title = format!("{:a<229} ", "title-");
    assert_eq!(long_title.len(), 230);
    assert!(long_title.ends_with(' '));

    let t1_id = server.terminal_id_by_string(&t1_str).unwrap();
    server
        .app
        .terminal_runtimes
        .get(&t1_id)
        .unwrap()
        .test_process_pty_bytes(format!("\x1b]0;{long_title}\x07").as_bytes());
    server.app.render_dirty.request_terminal_title(p1);

    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);

    assert_eq!(next_window_title(&control_rx1), Some(Some(long_title)));
    assert!(no_window_title(&control_rx1));

    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn attach_sends_the_current_title() {
    let (mut server, (_, t1_str), _) = setup_two_terminal_server();
    let t1_id = server.terminal_id_by_string(&t1_str).unwrap();
    server
        .app
        .state
        .terminals
        .get_mut(&t1_id)
        .unwrap()
        .set_terminal_title(Some("✳ current title".to_string()));

    let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 1,
            terminal_id: t1_str,
            takeover: false,
        })
    );

    assert_eq!(
        next_window_title(&control_rx1),
        Some(Some("✳ current title".to_string()))
    );
    assert!(no_window_title(&control_rx1));

    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn takeover_sends_the_title_to_the_new_client() {
    let (mut server, (_, t1_str), _) = setup_two_terminal_server();
    let t1_id = server.terminal_id_by_string(&t1_str).unwrap();
    server
        .app
        .state
        .terminals
        .get_mut(&t1_id)
        .unwrap()
        .set_terminal_title(Some("✳ session 1".to_string()));

    let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 1,
            terminal_id: t1_str.clone(),
            takeover: false,
        })
    );
    drain_window_titles(&control_rx1);

    let control_rx2 = connect_pending_terminal_client_with_control_rx(&mut server, 2);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 2,
            terminal_id: t1_str,
            takeover: true,
        })
    );

    assert_eq!(
        next_window_title(&control_rx2),
        Some(Some("✳ session 1".to_string()))
    );
    assert!(no_window_title(&control_rx2));

    let shutdown_bytes = control_rx1
        .recv_timeout(Duration::from_secs(2))
        .expect("shutdown message");
    let reason = read_server_shutdown_reason(shutdown_bytes);
    assert_eq!(reason, Some("terminal attach taken over".to_owned()));
    assert!(no_window_title(&control_rx1));

    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn untitled_terminal_sends_nothing() {
    let (mut server, (p1, t1_str), _) = setup_two_terminal_server();
    let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 1,
            terminal_id: t1_str,
            takeover: false,
        })
    );
    assert!(no_window_title(&control_rx1));

    server.app.render_dirty.request_terminal_title(p1);
    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);
    assert!(no_window_title(&control_rx1));

    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn cleared_title_sends_nothing() {
    let (mut server, (p1, t1_str), _) = setup_two_terminal_server();
    let t1_id = server.terminal_id_by_string(&t1_str).unwrap();
    server
        .app
        .terminal_runtimes
        .get(&t1_id)
        .unwrap()
        .test_process_pty_bytes(b"\x1b]0;\xe2\x9c\xb3 a\x07");
    server.app.render_dirty.request_terminal_title(p1);
    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);

    let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 1,
            terminal_id: t1_str,
            takeover: false,
        })
    );
    assert_eq!(
        next_window_title(&control_rx1),
        Some(Some("✳ a".to_string()))
    );

    server
        .app
        .terminal_runtimes
        .get(&t1_id)
        .unwrap()
        .test_process_pty_bytes(b"\x1b]0;\x07");
    server.app.render_dirty.request_terminal_title(p1);

    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);

    assert!(no_window_title(&control_rx1));
    assert_eq!(
        server
            .clients
            .get(&1)
            .unwrap()
            .terminal_attach_title_sent
            .as_deref(),
        Some("✳ a")
    );
    assert_eq!(server.app.state.terminals[&t1_id].terminal_title, None);

    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn unchanged_title_is_not_resent() {
    let (mut server, (p1, t1_str), _) = setup_two_terminal_server();
    let t1_id = server.terminal_id_by_string(&t1_str).unwrap();
    server
        .app
        .terminal_runtimes
        .get(&t1_id)
        .unwrap()
        .test_process_pty_bytes(b"\x1b]0;\xe2\x9c\xb3 a\x07");
    server.app.render_dirty.request_terminal_title(p1);
    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);

    let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 1,
            terminal_id: t1_str,
            takeover: false,
        })
    );
    assert_eq!(
        next_window_title(&control_rx1),
        Some(Some("✳ a".to_string()))
    );

    server.app.render_dirty.request_terminal_title(p1);
    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);
    assert!(no_window_title(&control_rx1));
    assert_eq!(
        server.app.state.terminals[&t1_id].terminal_title.as_deref(),
        Some("✳ a")
    );

    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn client_without_writer_is_skipped() {
    let (mut server, (p1, t1_str), _) = setup_two_terminal_server();
    let t1_id = server.terminal_id_by_string(&t1_str).unwrap();
    server
        .app
        .state
        .terminals
        .get_mut(&t1_id)
        .unwrap()
        .set_terminal_title(Some("✳ a".to_string()));

    let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 1,
            terminal_id: t1_str,
            takeover: false,
        })
    );
    drain_window_titles(&control_rx1);

    server.clients.get_mut(&1).unwrap().writer = None;
    server
        .clients
        .get_mut(&1)
        .unwrap()
        .terminal_attach_title_sent = None;

    server
        .app
        .terminal_runtimes
        .get(&t1_id)
        .unwrap()
        .test_process_pty_bytes(b"\x1b]0;new title\x07");
    server.app.render_dirty.request_terminal_title(p1);
    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);

    assert_eq!(
        server.clients.get(&1).unwrap().terminal_attach_title_sent,
        None
    );

    shutdown_test_runtimes(&mut server);
}

/// The writer thread notices a dropped receiver only when it forwards the next
/// message, and closes the queue after that. Probe until a send fails.
fn wait_for_closed_writer(server: &HeadlessServer, client_id: u64) {
    let writer = server.clients[&client_id]
        .writer
        .as_ref()
        .expect("client writer");
    let deadline = Instant::now() + Duration::from_secs(2);
    while writer.control.send(Vec::new()).is_ok() {
        assert!(Instant::now() < deadline, "client writer never closed");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[tokio::test]
async fn failed_send_does_not_stop_the_other_clients() {
    // The step visits terminals in HashMap order, so fail each client in turn:
    // one of the two runs reaches the failing client before the healthy one.
    for failing_client in [1_u64, 2] {
        let (mut server, (p1, t1_str), (p2, t2_str)) = setup_two_terminal_server();
        let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
        let control_rx2 = connect_pending_terminal_client_with_control_rx(&mut server, 2);
        for (client_id, terminal_id) in [(1, &t1_str), (2, &t2_str)] {
            assert!(
                server.handle_server_event(ServerEvent::ClientAttachTerminal {
                    client_id,
                    terminal_id: terminal_id.clone(),
                    takeover: false,
                })
            );
        }
        drain_window_titles(&control_rx1);
        drain_window_titles(&control_rx2);

        let (healthy_rx, healthy_title) = if failing_client == 1 {
            drop(control_rx1);
            (control_rx2, "title two")
        } else {
            drop(control_rx2);
            (control_rx1, "title one")
        };
        wait_for_closed_writer(&server, failing_client);

        for (terminal, bytes) in [
            (&t1_str, &b"\x1b]0;title one\x07"[..]),
            (&t2_str, &b"\x1b]0;title two\x07"[..]),
        ] {
            let terminal_id = server.terminal_id_by_string(terminal).unwrap();
            server
                .app
                .terminal_runtimes
                .get(&terminal_id)
                .unwrap()
                .test_process_pty_bytes(bytes);
        }
        server.app.render_dirty.request_terminal_title(p1);
        server.app.render_dirty.request_terminal_title(p2);
        let sources = server.app.render_dirty.take().terminal_title_sources;
        server.sync_terminal_title_sources(&sources);

        assert_eq!(
            next_window_title(&healthy_rx),
            Some(Some(healthy_title.to_string()))
        );
        assert!(!server.clients.contains_key(&failing_client));

        shutdown_test_runtimes(&mut server);
    }
}

#[tokio::test]
async fn title_synced_by_an_api_request_still_arrives() {
    let (mut server, (p1, t1_str), _) = setup_two_terminal_server();
    let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 1,
            terminal_id: t1_str.clone(),
            takeover: false,
        })
    );
    drain_window_titles(&control_rx1);

    let t1_id = server.terminal_id_by_string(&t1_str).unwrap();
    server
        .app
        .terminal_runtimes
        .get(&t1_id)
        .unwrap()
        .test_process_pty_bytes(b"\x1b]0;api title\x07");
    server.app.render_dirty.request_terminal_title(p1);

    let changes = server.app.sync_pending_terminal_titles();
    assert!(changes.raw_changed);

    let dirty = server.app.render_dirty.take();
    assert!(dirty.terminal_title_sources.contains(&p1));

    server.sync_terminal_title_sources(&dirty.terminal_title_sources);

    assert_eq!(
        next_window_title(&control_rx1),
        Some(Some("api title".to_string()))
    );
    assert!(no_window_title(&control_rx1));

    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn background_workspace_title_reaches_its_client() {
    let (mut server, _, (p2, t2_str)) = setup_two_terminal_server();
    assert_eq!(server.app.state.active, Some(0));

    let control_rx2 = connect_pending_terminal_client_with_control_rx(&mut server, 2);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 2,
            terminal_id: t2_str.clone(),
            takeover: false,
        })
    );
    drain_window_titles(&control_rx2);

    let t2_id = server.terminal_id_by_string(&t2_str).unwrap();
    server
        .app
        .terminal_runtimes
        .get(&t2_id)
        .unwrap()
        .test_process_pty_bytes(b"\x1b]0;bg title\x07");
    server.app.render_dirty.request_terminal_title(p2);

    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);

    assert_eq!(
        next_window_title(&control_rx2),
        Some(Some("bg title".to_string()))
    );
    assert!(no_window_title(&control_rx2));

    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn empty_window_title_setting_turns_it_off() {
    let (mut server, (p1, t1_str), _) = setup_two_terminal_server();
    server.app.configure_window_title("");

    let t1_id = server.terminal_id_by_string(&t1_str).unwrap();
    server
        .app
        .state
        .terminals
        .get_mut(&t1_id)
        .unwrap()
        .set_terminal_title(Some("some title".to_string()));

    let control_rx1 = connect_pending_terminal_client_with_control_rx(&mut server, 1);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 1,
            terminal_id: t1_str.clone(),
            takeover: false,
        })
    );
    assert!(no_window_title(&control_rx1));

    server
        .app
        .terminal_runtimes
        .get(&t1_id)
        .unwrap()
        .test_process_pty_bytes(b"\x1b]0;new title\x07");
    server.app.render_dirty.request_terminal_title(p1);

    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);
    assert!(no_window_title(&control_rx1));

    shutdown_test_runtimes(&mut server);
}

#[tokio::test]
async fn full_view_title_is_untouched() {
    let (mut server, (p1, t1_str), _) = setup_two_terminal_server();

    let (client1_tx, control_rx1, _render_rx1) = test_client_writer();
    server.clients.insert(
        1,
        ClientConnection::new(
            (80, 24),
            crate::kitty_graphics::HostCellSize::default(),
            1,
            RenderEncoding::SemanticFrame,
            Some(client1_tx),
        ),
    );
    server.promote_client_to_foreground(1);
    drain_window_titles(&control_rx1);

    let control_rx2 = connect_pending_terminal_client_with_control_rx(&mut server, 2);
    assert!(
        server.handle_server_event(ServerEvent::ClientAttachTerminal {
            client_id: 2,
            terminal_id: t1_str.clone(),
            takeover: false,
        })
    );
    drain_window_titles(&control_rx2);

    let sent_before = server.sent_window_title.clone();

    let t1_id = server.terminal_id_by_string(&t1_str).unwrap();
    server
        .app
        .terminal_runtimes
        .get(&t1_id)
        .unwrap()
        .test_process_pty_bytes(b"\x1b]0;new title\x07");
    server.app.render_dirty.request_terminal_title(p1);

    let sources = server.app.render_dirty.take().terminal_title_sources;
    server.sync_terminal_title_sources(&sources);

    assert!(no_window_title(&control_rx1));
    assert_eq!(server.sent_window_title, sent_before);
    assert_eq!(
        next_window_title(&control_rx2),
        Some(Some("new title".to_string()))
    );
    assert!(no_window_title(&control_rx2));

    shutdown_test_runtimes(&mut server);
}

fn setup_scale_profile_cell(num_terminals: usize, num_clients: usize) -> HeadlessServer {
    let mut server = test_headless_server();
    let mut workspaces = Vec::new();
    let mut terminal_ids = Vec::new();

    for i in 0..num_terminals {
        let ws = crate::workspace::Workspace::test_new(&format!("ws{i}"));
        let pane_id = ws.tabs[0].root_pane;
        let term_id = ws.terminal_id(pane_id).expect("term_id").clone();
        terminal_ids.push(term_id.clone());
        workspaces.push(ws);
        server.app.terminal_runtimes.insert(
            term_id,
            crate::terminal::TerminalRuntime::test_with_screen_bytes(80, 24, b""),
        );
    }
    server.app.state.workspaces = workspaces;
    server.app.state.active = Some(0);
    server.app.state.ensure_test_terminals();

    for (i, tid) in terminal_ids.iter().enumerate() {
        if let Some(t) = server.app.state.terminals.get_mut(tid) {
            t.set_terminal_title(Some(format!("title-{i}")));
        }
    }

    for (i, tid) in terminal_ids.iter().take(num_clients).enumerate() {
        let client_id = (i + 1) as u64;
        let (writer, _control_rx, _render_rx) = test_client_writer();
        server.clients.insert(
            client_id,
            ClientConnection::new_with_mode(
                ClientConnectionMode::TerminalPending,
                (80, 24),
                crate::kitty_graphics::HostCellSize::default(),
                1,
                RenderEncoding::SemanticFrame,
                Some(writer),
            ),
        );
        server.attach_terminal_client(client_id, tid.to_string(), false);
        if let Some(c) = server.clients.get_mut(&client_id) {
            c.terminal_attach_title_sent = Some(format!("title-{i}"));
        }
    }

    server
}

#[tokio::test]
#[ignore]
async fn terminal_attach_title_scale_profile() {
    fn run_cell(num_terminals: usize, num_clients: usize) -> (f64, f64) {
        let mut server = setup_scale_profile_cell(num_terminals, num_clients);
        let num_samples = 1_000;
        let batch_size = 1_000;
        let mut samples = Vec::with_capacity(num_samples);

        for _ in 0..num_samples {
            let start = Instant::now();
            for _ in 0..batch_size {
                server.sync_terminal_attach_titles();
            }
            let elapsed_ns = start.elapsed().as_nanos() as f64;
            let per_call_ns = elapsed_ns / batch_size as f64;
            samples.push(per_call_ns);
        }

        samples.sort_by(f64::total_cmp);
        let median = samples[num_samples / 2];
        let p95 = samples[num_samples * 95 / 100];
        shutdown_test_runtimes(&mut server);
        (median, p95)
    }

    let (m1_0, p1_0) = run_cell(1, 0);
    let (m1_1, p1_1) = run_cell(1, 1);
    let (m15_0, p15_0) = run_cell(15, 0);
    let (m15_1, p15_1) = run_cell(15, 1);
    let (m15_15, p15_15) = run_cell(15, 15);

    let ratio_15_vs_1_at_1_client = m15_1 / m1_1.max(0.001);

    println!("Scale profile results (all titles unchanged):");
    println!(
        "  1 term x 0 clients: median = {:.1} ns, p95 = {:.1} ns",
        m1_0, p1_0
    );
    println!(
        "  1 term x 1 client:  median = {:.1} ns, p95 = {:.1} ns",
        m1_1, p1_1
    );
    println!(
        " 15 term x 0 clients: median = {:.1} ns, p95 = {:.1} ns",
        m15_0, p15_0
    );
    println!(
        " 15 term x 1 client:  median = {:.1} ns, p95 = {:.1} ns",
        m15_1, p15_1
    );
    println!(
        " 15 term x 15 clients: median = {:.1} ns, p95 = {:.1} ns",
        m15_15, p15_15
    );
    println!(
        " Ratio (15 vs 1 at 1 client): {:.2}x",
        ratio_15_vs_1_at_1_client
    );

    assert!(
        m15_15 < 100_000.0,
        "median at 15x15 must be under 100 µs (100,000 ns), got {m15_15:.1} ns"
    );
    assert!(
        m1_0 < 1_000.0,
        "median at 1x0 must be under 1 µs (1,000 ns), got {m1_0:.1} ns"
    );
    assert!(
        m15_0 < 1_000.0,
        "median at 15x0 must be under 1 µs (1,000 ns), got {m15_0:.1} ns"
    );
}
